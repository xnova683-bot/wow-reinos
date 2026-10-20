-- ================================================================
-- APENDICE TABERNA DE AZAR: juegos de apuestas con CUP.
--   - Ajustes: tavern_enabled, tavern_min, tavern_max, tavern_fee,
--     tavern_jackpot_pct, tavern_jackpot_h.
--   - Tablas: wow_tavern_bets (historial), wow_tavern_jackpot (bote),
--     wow_tavern_pool (aportes por reino al bote).
--   - Juegos (apuesta en CUP, se cobra siempre al jugar):
--       wow_tavern_dice   : eliges 1..6; aciertas -> x2 menos comision.
--       wow_tavern_cards  : 2 cartas 1..13; aciertas mayor -> x2 menos
--                           comision; empate devuelve la apuesta.
--       wow_tavern_duel   : tu dado vs dado de la casa (1..6); ganas si
--                           el tuyo es mayor -> x2 menos comision; empate
--                           devuelve la apuesta.
--       wow_tavern_jackpot_bet  : aporta al bote comun (una parte).
--       wow_tavern_draw         : pulsa para llevarte el bote (si toca);
--                                 probabilidad segun tu aporte.
--   - wow_tavern_info: estado, topes, comision, bote, historial.
-- ================================================================

insert into wow_settings(key,val) values
  ('tavern_enabled','1'),
  ('tavern_min','10'),
  ('tavern_max','1000'),
  ('tavern_fee','5'),
  ('tavern_jackpot_pct','10'),
  ('tavern_jackpot_h','6')
on conflict (key) do nothing;

create table if not exists wow_tavern_bets (
  id bigint generated always as identity primary key,
  owner text not null,
  owner_name text,
  game text not null,
  amount numeric not null,
  payout numeric not null default 0,
  detail jsonb not null default '{}'::jsonb,
  created bigint not null
);
create index if not exists wow_tavern_bets_created on wow_tavern_bets(created desc);

create table if not exists wow_tavern_jackpot (
  id integer primary key default 1,
  pot numeric not null default 0,
  last_draw_ms bigint not null default 0,
  last_winner text,
  last_winner_name text,
  check (id = 1)
);
insert into wow_tavern_jackpot(id, pot, last_draw_ms) values (1, 0, 0)
on conflict (id) do nothing;

create table if not exists wow_tavern_pool (
  owner text primary key,
  contributed numeric not null default 0
);

-- ajustes de la taberna
create or replace function public._wow_tv_enabled() returns boolean
language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='tavern_enabled'),1) <> 0;
$$;

create or replace function public._wow_tv_min() returns numeric
language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='tavern_min'),10);
$$;

create or replace function public._wow_tv_max() returns numeric
language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='tavern_max'),1000);
$$;

create or replace function public._wow_tv_fee() returns numeric
language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='tavern_fee'),5);
$$;

create or replace function public._wow_tv_jpct() returns numeric
language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='tavern_jackpot_pct'),10);
$$;

create or replace function public._wow_tv_jh() returns numeric
language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='tavern_jackpot_h'),6);
$$;

-- valida la apuesta (cantidad, topes y saldo) y la cobra. Devuelve la cantidad apostada.
create or replace function public._wow_tv_take(p_uid text, p_amount numeric)
returns numeric language plpgsql security definer set search_path to 'public' as $$
declare amt numeric; cur numeric;
begin
  if not _wow_tv_enabled() then raise exception 'La Taberna está cerrada ahora mismo.'; end if;
  amt := floor(coalesce(p_amount,0));
  if amt <= 0 then raise exception 'Elige cuánto quieres apostar.'; end if;
  if amt < _wow_tv_min() then raise exception 'La apuesta mínima es % CUP.', _wow_tv_min(); end if;
  if amt > _wow_tv_max() then raise exception 'La apuesta máxima es % CUP.', _wow_tv_max(); end if;
  select cup into cur from wow_users where id = p_uid;
  if coalesce(cur,0) < amt then raise exception 'No tienes suficiente CUP.'; end if;
  update wow_users set cup = cup - amt where id = p_uid;
  return amt;
end $$;

-- registra la jugada en el historial
create or replace function public._wow_tv_log(p_uid text, p_name text, p_game text, p_amount numeric, p_payout numeric, p_detail jsonb)
returns void language sql security definer set search_path to 'public' as $$
  insert into wow_tavern_bets(owner, owner_name, game, amount, payout, detail, created)
  values (p_uid, p_name, p_game, p_amount, p_payout, coalesce(p_detail,'{}'::jsonb), (extract(epoch from now())*1000)::bigint);
$$;

-- RULETA / DADOS: eliges un numero 1..6. Aciertas -> ganas x2 menos comision.
create or replace function public.wow_tavern_dice(p_token text, p_amount numeric, p_pick integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; amt numeric; roll integer; won boolean; payout numeric; net numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no juegan.'; end if;
  u := _wow_tick(u.id);
  if p_pick is null or p_pick < 1 or p_pick > 6 then raise exception 'Elige un número del 1 al 6.'; end if;
  amt := _wow_tv_take(u.id, p_amount);
  roll := 1 + floor(random()*6)::int;
  won := (roll = p_pick);
  payout := 0; net := 0;
  if won then
    payout := amt * 2;
    net := round(payout * (1 - _wow_tv_fee()/100.0), 4);
    if net > payout then net := payout; end if;
    update wow_users set cup = cup + net where id = u.id;
  end if;
  perform _wow_tv_log(u.id, u.name, 'dice', amt, net,
    jsonb_build_object('pick', p_pick, 'roll', roll, 'win', won));
  return jsonb_build_object('ok', true, 'game','dice', 'pick', p_pick, 'roll', roll,
    'win', won, 'amount', amt, 'payout', net, 'fee', _wow_tv_fee(), 'cup', (select cup from wow_users where id=u.id));
end $$;
revoke all on function public.wow_tavern_dice(text, numeric, integer) from public;
grant execute on function public.wow_tavern_dice(text, numeric, integer) to anon, authenticated;

-- CARTAS: dos cartas 1..13. Apuestas cual es mayor. Aciertas -> x2 menos comision; empate -> devuelve.
create or replace function public.wow_tavern_cards(p_token text, p_amount numeric, p_mayor boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; amt numeric; c1 integer; c2 integer; tie boolean; won boolean; payout numeric; net numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no juegan.'; end if;
  u := _wow_tick(u.id);
  amt := _wow_tv_take(u.id, p_amount);
  c1 := 1 + floor(random()*13)::int;
  c2 := 1 + floor(random()*13)::int;
  tie := (c1 = c2);
  won := (not tie) and ((p_mayor and c2 > c1) or ((not p_mayor) and c2 < c1));
  payout := 0; net := 0;
  if tie then
    net := amt;
    update wow_users set cup = cup + net where id = u.id;
  elsif won then
    payout := amt * 2;
    net := round(payout * (1 - _wow_tv_fee()/100.0), 4);
    if net > payout then net := payout; end if;
    update wow_users set cup = cup + net where id = u.id;
  end if;
  perform _wow_tv_log(u.id, u.name, 'cards', amt, net,
    jsonb_build_object('c1', c1, 'c2', c2, 'pick_high', p_mayor, 'tie', tie, 'win', won));
  return jsonb_build_object('ok', true, 'game','cards', 'c1', c1, 'c2', c2, 'pick_high', p_mayor,
    'tie', tie, 'win', won, 'amount', amt, 'payout', net, 'fee', _wow_tv_fee(), 'cup', (select cup from wow_users where id=u.id));
end $$;
revoke all on function public.wow_tavern_cards(text, numeric, boolean) from public;
grant execute on function public.wow_tavern_cards(text, numeric, boolean) to anon, authenticated;

-- DUELO: tu dado (1..6) contra el dado de la casa (1..6). Ganas si el tuyo es mayor -> x2 menos comision; empate -> devuelve.
create or replace function public.wow_tavern_duel(p_token text, p_amount numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; amt numeric; mine integer; theirs integer; tie boolean; won boolean; payout numeric; net numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no juegan.'; end if;
  u := _wow_tick(u.id);
  amt := _wow_tv_take(u.id, p_amount);
  mine := 1 + floor(random()*6)::int;
  theirs := 1 + floor(random()*6)::int;
  tie := (mine = theirs);
  won := (mine > theirs);
  payout := 0; net := 0;
  if tie then
    net := amt;
    update wow_users set cup = cup + net where id = u.id;
  elsif won then
    payout := amt * 2;
    net := round(payout * (1 - _wow_tv_fee()/100.0), 4);
    if net > payout then net := payout; end if;
    update wow_users set cup = cup + net where id = u.id;
  end if;
  perform _wow_tv_log(u.id, u.name, 'duel', amt, net,
    jsonb_build_object('mine', mine, 'theirs', theirs, 'tie', tie, 'win', won));
  return jsonb_build_object('ok', true, 'game','duel', 'mine', mine, 'theirs', theirs,
    'tie', tie, 'win', won, 'amount', amt, 'payout', net, 'fee', _wow_tv_fee(), 'cup', (select cup from wow_users where id=u.id));
end $$;
revoke all on function public.wow_tavern_duel(text, numeric) from public;
grant execute on function public.wow_tavern_duel(text, numeric) to anon, authenticated;

-- BOTE: apuesta que aporta al bote comun. Una parte se suma al bote y otra es sumidero.
-- El jugador acumula "aporte" para probabilidad en el sorteo.
create or replace function public.wow_tavern_jackpot_bet(p_token text, p_amount numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; amt numeric; aporte numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no juegan.'; end if;
  u := _wow_tick(u.id);
  amt := _wow_tv_take(u.id, p_amount);
  aporte := round(amt * (1 - _wow_tv_jpct()/100.0), 4);
  if aporte < 0 then aporte := 0; end if;
  update wow_tavern_jackpot set pot = pot + aporte where id = 1;
  insert into wow_tavern_pool(owner, contributed) values (u.id, amt)
    on conflict (owner) do update set contributed = wow_tavern_pool.contributed + amt;
  perform _wow_tv_log(u.id, u.name, 'jackpot_bet', amt, 0,
    jsonb_build_object('pot_add', aporte));
  return jsonb_build_object('ok', true, 'game','jackpot_bet', 'amount', amt, 'pot_add', aporte,
    'pot', (select pot from wow_tavern_jackpot where id=1), 'cup', (select cup from wow_users where id=u.id));
end $$;
revoke all on function public.wow_tavern_jackpot_bet(text, numeric) from public;
grant execute on function public.wow_tavern_jackpot_bet(text, numeric) to anon, authenticated;

-- BOTE: intenta llevarte el bote. Solo si ha pasado el tiempo (tavern_jackpot_h horas).
-- El ganador se sortea entre todos los aportantes, ponderado por su aporte.
create or replace function public.wow_tavern_draw(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; j wow_tavern_jackpot; ms bigint; total numeric; pick numeric; acc numeric;
        rec record; winner text; winner_name text; pot numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no juegan.'; end if;
  u := _wow_tick(u.id);
  select * into j from wow_tavern_jackpot where id = 1 for update;
  ms := (extract(epoch from now())*1000)::bigint;
  if j.last_draw_ms > 0 and ms < j.last_draw_ms + (_wow_tv_jh()*3600000)::bigint then
    raise exception 'El bote aún no toca. Vuelve más tarde.';
  end if;
  pot := coalesce(j.pot,0);
  if pot <= 0 then raise exception 'El bote está vacío.'; end if;
  select coalesce(sum(contributed),0) into total from wow_tavern_pool where contributed > 0;
  if coalesce(total,0) <= 0 then
    select u.id, u.name into winner, winner_name;
  else
    pick := random() * total; acc := 0; winner := null;
    for rec in select owner, contributed from wow_tavern_pool where contributed > 0 loop
      acc := acc + rec.contributed;
      if winner is null and pick <= acc then winner := rec.owner; end if;
    end loop;
    if winner is null then
      select owner into winner from wow_tavern_pool where contributed > 0 order by contributed desc limit 1;
    end if;
    select name into winner_name from wow_users where id = winner;
  end if;
  update wow_users set cup = cup + pot where id = winner;
  update wow_tavern_jackpot set pot = 0, last_draw_ms = ms, last_winner = winner, last_winner_name = winner_name where id = 1;
  delete from wow_tavern_pool;
  perform _wow_tv_log(winner, winner_name, 'jackpot_win', 0, pot,
    jsonb_build_object('pot', pot, 'trigger', u.id));
  perform _wow_tv_log(u.id, u.name, 'jackpot_draw', 0, 0, jsonb_build_object('winner', winner));
  return jsonb_build_object('ok', true, 'pot', pot, 'winner', winner, 'winner_name', winner_name,
    'me', (winner = u.id), 'cup', (select cup from wow_users where id=u.id));
end $$;
revoke all on function public.wow_tavern_draw(text) from public;
grant execute on function public.wow_tavern_draw(text) to anon, authenticated;

-- INFO: estado, topes, comision, bote, aportes y ultimas jugadas.
create or replace function public.wow_tavern_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; j wow_tavern_jackpot; ms bigint; mycontrib numeric; cango boolean; hist jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  select * into j from wow_tavern_jackpot where id = 1;
  ms := (extract(epoch from now())*1000)::bigint;
  select coalesce(contributed,0) into mycontrib from wow_tavern_pool where owner = u.id;
  cango := (j.last_draw_ms <= 0) or (ms >= j.last_draw_ms + (_wow_tv_jh()*3600000)::bigint);
  select coalesce(jsonb_agg(x.j order by x.id desc), '[]'::jsonb) into hist
    from (select id, jsonb_build_object('game',game,'who',owner_name,'amount',amount,
            'payout',payout,'detail',detail,'created',created) j
          from wow_tavern_bets order by id desc limit 15) x;
  return jsonb_build_object('ok', true,
    'enabled', _wow_tv_enabled(), 'min', _wow_tv_min(), 'max', _wow_tv_max(),
    'fee', _wow_tv_fee(), 'jackpot_pct', _wow_tv_jpct(), 'jackpot_h', _wow_tv_jh(),
    'cup', u.cup,
    'pot', coalesce(j.pot,0), 'last_draw', j.last_draw_ms, 'last_winner', j.last_winner_name,
    'wait_ms', greatest(0, case when j.last_draw_ms <= 0 then 0 else (j.last_draw_ms + (_wow_tv_jh()*3600000)::bigint) - ms end),
    'can_draw', cango, 'my_contrib', coalesce(mycontrib,0),
    'history', hist);
end $$;
revoke all on function public.wow_tavern_info(text) from public;
grant execute on function public.wow_tavern_info(text) to anon, authenticated;
