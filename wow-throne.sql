-- ================================================================
-- APENDICE TRONOS: FORTALEZAS CENTRALES CONQUISTABLES
--   - Dos tronos: nodo 0 (Azeroth) y nodo 21 (Kalimdor).
--   - Empiezan LIBRES: el primero que llega con tropas los ocupa.
--   - Otros reinos atacan la guarnicion para quitarlos.
--   - El duenio recibe parte de la comision del mercado (tributo)
--     acumulada en un tesoro que reclama cuando quiere.
--   - El admin no puede poseer tronos.
-- ================================================================

create table if not exists public.wow_thrones(
  node integer primary key,
  name text not null default '',
  holder text,
  holder_name text not null default '',
  since_ms bigint not null default 0,
  garrison jsonb not null default '{}'::jsonb,
  accrue_ms bigint not null default 0
);
alter table public.wow_thrones add column if not exists accrue_ms bigint not null default 0;
create table if not exists public.wow_throne_treasure(
  node integer not null,
  key text not null,
  qty numeric(16,2) not null default 0,
  primary key (node, key)
);
create table if not exists public.wow_throne_history(
  id bigserial primary key,
  node integer not null,
  kind text not null,
  actor text,
  actor_name text not null default '',
  detail jsonb not null default '{}'::jsonb,
  created bigint not null default 0
);
create table if not exists public.wow_events(
  id bigserial primary key,
  kind text not null default '',
  txt text not null default '',
  created bigint not null default 0
);
alter table public.wow_thrones enable row level security;
alter table public.wow_throne_treasure enable row level security;
alter table public.wow_throne_history enable row level security;
alter table public.wow_events enable row level security;

insert into public.wow_thrones(node, name) values (0, 'TRONO DE AZEROTH'), (21, 'TRONO DE KALIMDOR')
  on conflict (node) do nothing;
insert into public.wow_settings(key, val) values ('throne_share', '1')
  on conflict (key) do nothing;
-- produccion de recursos de cada trono con duenio (por hora)
insert into public.wow_settings(key, val) values
  ('throne_gold_h', '100'), ('throne_wood_h', '100'), ('throne_ore_h', '100')
  on conflict (key) do nothing;

-- ---- helpers internos ----
create or replace function public._wow_throne_pct()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = 'throne_share'), 1)
$$;
revoke all on function public._wow_throne_pct() from public, anon, authenticated;

create or replace function public._wow_throne_add(p_node integer, p_key text, p_qty numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(p_qty,0) <= 0 then return; end if;
  insert into wow_throne_treasure(node, key, qty) values (p_node, p_key, p_qty)
    on conflict (node, key) do update set qty = wow_throne_treasure.qty + excluded.qty;
end $$;
revoke all on function public._wow_throne_add(integer, text, numeric) from public, anon, authenticated;

-- ---- produccion de recursos por hora (configurable por el admin) ----
create or replace function public._wow_throne_rate(p_key text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = p_key), 100)
$$;
revoke all on function public._wow_throne_rate(text) from public, anon, authenticated;

-- abona al tesoro los recursos generados por cada trono con duenio desde el ultimo abono
create or replace function public._wow_throne_accrue()
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  ms bigint; t record; hrs numeric; rg numeric; rw numeric; ro numeric;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  rg := _wow_throne_rate('throne_gold_h');
  rw := _wow_throne_rate('throne_wood_h');
  ro := _wow_throne_rate('throne_ore_h');
  for t in select * from wow_thrones where holder is not null for update loop
    if coalesce(t.accrue_ms,0) <= 0 then
      update wow_thrones set accrue_ms = ms where node = t.node;
      continue;
    end if;
    hrs := (ms - t.accrue_ms)::numeric / 3600000.0;
    if hrs <= 0 then continue; end if;
    if rg > 0 then perform _wow_throne_add(t.node, 'gold', round(rg * hrs, 2)); end if;
    if rw > 0 then perform _wow_throne_add(t.node, 'wood', round(rw * hrs, 2)); end if;
    if ro > 0 then perform _wow_throne_add(t.node, 'ore',  round(ro * hrs, 2)); end if;
    update wow_thrones set accrue_ms = ms where node = t.node;
  end loop;
end $$;
revoke all on function public._wow_throne_accrue() from public, anon, authenticated;

create or replace function public._wow_throne_check(p_troops jsonb)
returns jsonb language plpgsql immutable as $$
declare k text; v numeric; res jsonb := '{}'::jsonb;
begin
  if p_troops is null or jsonb_typeof(p_troops) <> 'object' then raise exception 'Sin tropas.'; end if;
  for k, v in select key, value::numeric from jsonb_each_text(p_troops) loop
    if not _wow_mkt_is_troop(k) then raise exception 'Tropa no válida: %', k; end if;
    if v <= 0 or v <> floor(v) then raise exception 'Cantidad inválida para %.', k; end if;
    res := res || jsonb_build_object(k, v::int);
  end loop;
  if res = '{}'::jsonb then raise exception 'Elige al menos una tropa.'; end if;
  return res;
end $$;
revoke all on function public._wow_throne_check(jsonb) from public, anon, authenticated;

create or replace function public._wow_throne_log(p_node integer, p_kind text, p_actor text, p_actor_name text, p_detail jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare ms bigint := (extract(epoch from now())*1000)::bigint;
begin
  insert into wow_throne_history(node, kind, actor, actor_name, detail, created)
    values (p_node, p_kind, p_actor, coalesce(p_actor_name,''), coalesce(p_detail,'{}'::jsonb), ms);
  delete from wow_throne_history where node = p_node
    and id not in (select id from wow_throne_history where node = p_node order by id desc limit 40);
end $$;
revoke all on function public._wow_throne_log(integer, text, text, text, jsonb) from public, anon, authenticated;

create or replace function public._wow_event(p_kind text, p_text text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare ms bigint := (extract(epoch from now())*1000)::bigint;
begin
  insert into wow_events(kind, txt, created) values (p_kind, p_text, ms);
  delete from wow_events where id not in (select id from wow_events order by id desc limit 60);
end $$;
revoke all on function public._wow_event(text, text) from public, anon, authenticated;

-- ---- crónica global de sucesos ----
create or replace function public.wow_events(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'text', txt, 'created', created) order by id desc), '[]'::jsonb)
    into out from (select kind, txt, created, id from wow_events order by id desc limit 30) e;
  return out;
end $$;
grant execute on function public.wow_events(text) to anon, authenticated;

-- ---- estado de los tronos ----
create or replace function public.wow_throne_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; arr jsonb := '[]'::jsonb; g numeric; tr jsonb; fac text; hist jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  perform _wow_throne_accrue();
  for t in select * from wow_thrones order by node loop
    select coalesce(sum((value)::numeric),0) into g from jsonb_each_text(t.garrison);
    select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into tr
      from wow_throne_treasure where node = t.node and qty > 0;
    select coalesce(jsonb_agg(jsonb_build_object(
        'kind', h.kind, 'who', h.actor_name, 'who_id', h.actor,
        'detail', h.detail, 'created', h.created) order by h.id desc), '[]'::jsonb)
      into hist from (select * from wow_throne_history where node = t.node order by id desc limit 8) h;
    fac := null;
    if t.holder is not null then select faction into fac from wow_users where id = t.holder; end if;
    arr := arr || jsonb_build_object(
      'node', t.node, 'name', t.name, 'holder', t.holder, 'holder_name', t.holder_name,
      'faction', fac, 'garrison', coalesce(g,0), 'gdetail', t.garrison, 'since', t.since_ms,
      'mine', (t.holder = u.id), 'treasure', tr, 'history', hist);
  end loop;
  return jsonb_build_object('ok', true, 'share', _wow_throne_pct(), 'thrones', arr,
    'rates', jsonb_build_object('gold', _wow_throne_rate('throne_gold_h'),
                                'wood', _wow_throne_rate('throne_wood_h'),
                                'ore',  _wow_throne_rate('throne_ore_h')));
end $$;
grant execute on function public.wow_throne_info(text) to anon, authenticated;

-- ---- conquistar (atacar guarnicion) ----
create or replace function public.wow_throne_attack(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; t wow_thrones; ms bigint; army jsonb; sim jsonb; surv jsonb;
  z record; a_forge int; a_fort int; d_forge int; d_fort int; d_wall int; prev text;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian ni conquistan.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  -- el ejercito sale del reino
  for z in select key, value::int from jsonb_each_text(army) loop
    perform _wow_mkt_sub(u.id, z.key, z.value);
  end loop;
  -- trono libre/vacio: se ocupa sin lucha
  if coalesce(t.holder,'') = '' or t.garrison = '{}'::jsonb then
    update wow_thrones set holder = u.id, holder_name = u.name, since_ms = ms, garrison = army, accrue_ms = ms where node = t.node;
    perform _wow_throne_log(t.node, 'take', u.id, u.name, jsonb_build_object('garrison', army));
    perform _wow_event('throne', '🏯 ' || u.name || ' ha ocupado ' || t.name || '.');
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',true,'battle',null,'created',ms), ms);
    return jsonb_build_object('ok', true, 'took', true, 'free', true, 'garrison', army);
  end if;
  -- batalla contra la guarnicion (defiende con muralla/herreria/fortaleza del duenio)
  prev := t.holder_name;
  a_forge := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'herreria'), 0);
  a_fort  := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'fortaleza'), 0);
  d_forge := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'herreria'), 0);
  d_fort  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'fortaleza'), 0);
  d_wall  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'muralla'), 0);
  sim := _wow_sim(army, t.garrison, d_wall, (ms/1000) + t.node*131,
                  1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort);
  if (sim->>'winner') = 'attacker' then
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'a_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    update wow_thrones set holder = u.id, holder_name = u.name, since_ms = ms, garrison = surv, accrue_ms = ms where node = t.node;
    perform _wow_throne_log(t.node, 'conquest', u.id, u.name, jsonb_build_object('from', prev));
    perform _wow_event('throne', '👑 ' || u.name || ' ha conquistado ' || t.name || ' (antes de ' || coalesce(prev, 'nadie') || ').');
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',true,'from',u.name,'battle',sim,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',true,'from',u.name,'battle',sim,'created',ms), ms);
    return jsonb_build_object('ok', true, 'win', true, 'battle', sim);
  else
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'d_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    update wow_thrones set garrison = surv where node = t.node;
    perform _wow_throne_log(t.node, 'defended', u.id, u.name, jsonb_build_object('holder', prev));
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms);
    return jsonb_build_object('ok', true, 'win', false, 'battle', sim);
  end if;
end $$;
grant execute on function public.wow_throne_attack(text, integer, jsonb) to anon, authenticated;

-- ---- reforzar guarnicion (solo el duenio) ----
create or replace function public.wow_throne_reinforce(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; army jsonb; newg jsonb; z record;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if t.holder <> u.id then raise exception 'No controlas ese trono.'; end if;
  for z in select key, value::int from jsonb_each_text(army) loop
    perform _wow_mkt_sub(u.id, z.key, z.value);
  end loop;
  newg := t.garrison;
  for z in select key, value::int from jsonb_each_text(army) loop
    newg := jsonb_set(newg, array[z.key], to_jsonb(coalesce((newg->>z.key)::int,0) + z.value), true);
  end loop;
  update wow_thrones set garrison = newg where node = t.node;
  perform _wow_throne_log(t.node, 'reinforce', u.id, u.name, jsonb_build_object('troops', army));
  return jsonb_build_object('ok', true, 'garrison', newg);
end $$;
grant execute on function public.wow_throne_reinforce(text, integer, jsonb) to anon, authenticated;

-- ---- retirar tropas de la guarnicion (solo el duenio) ----
create or replace function public.wow_throne_withdraw(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; army jsonb; newg jsonb; z record; left_g int;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if t.holder <> u.id then raise exception 'No controlas ese trono.'; end if;
  -- comprobar que la guarnicion tiene esas tropas
  for z in select key, value::int from jsonb_each_text(army) loop
    if coalesce((t.garrison->>z.key)::int, 0) < z.value then
      raise exception 'No tienes tantas tropas de ese tipo en la guarnición.'; end if;
  end loop;
  -- retirar de la guarnicion y devolverlas al reino
  newg := t.garrison;
  for z in select key, value::int from jsonb_each_text(army) loop
    left_g := coalesce((newg->>z.key)::int, 0) - z.value;
    if left_g > 0 then
      newg := jsonb_set(newg, array[z.key], to_jsonb(left_g), true);
    else
      newg := newg - z.key;
    end if;
    perform _wow_mkt_add(u.id, z.key, z.value);
  end loop;
  update wow_thrones set garrison = newg where node = t.node;
  perform _wow_throne_log(t.node, 'withdraw', u.id, u.name, jsonb_build_object('troops', army));
  return jsonb_build_object('ok', true, 'garrison', newg, 'empty', (newg = '{}'::jsonb));
end $$;
grant execute on function public.wow_throne_withdraw(text, integer, jsonb) to anon, authenticated;

-- ---- reclamar tesoro (solo el duenio) ----
create or replace function public.wow_throne_claim(p_token text, p_node integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; r record; msg jsonb := '{}'::jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if t.holder <> u.id then raise exception 'No controlas ese trono.'; end if;
  perform _wow_throne_accrue();
  for r in select key, qty from wow_throne_treasure where node = p_node and qty > 0 loop
    perform _wow_mkt_add(u.id, r.key, r.qty);
    msg := msg || jsonb_build_object(r.key, r.qty);
  end loop;
  delete from wow_throne_treasure where node = p_node;
  if msg <> '{}'::jsonb then perform _wow_throne_log(p_node, 'claim', u.id, u.name, msg); end if;
  return jsonb_build_object('ok', true, 'claimed', msg);
end $$;
grant execute on function public.wow_throne_claim(text, integer) to anon, authenticated;

-- ---- ajuste admin del tributo de tronos ----
create or replace function public.wow_admin_setthrone(p_token text, p_pct numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  if p_pct is null or p_pct < 0 or p_pct > 90 then raise exception 'El tributo debe estar entre 0 y 90.'; end if;
  insert into wow_settings(key, val) values ('throne_share', p_pct::text)
    on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'share', p_pct);
end $$;
grant execute on function public.wow_admin_setthrone(text, numeric) to anon, authenticated;

-- ---- ajuste admin de la produccion de recursos de los tronos (por hora) ----
create or replace function public.wow_admin_setthrones(p_token text, p_gold numeric, p_wood numeric, p_ore numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  if p_gold is null or p_wood is null or p_ore is null
     or p_gold < 0 or p_wood < 0 or p_ore < 0
     or p_gold > 100000 or p_wood > 100000 or p_ore > 100000 then
    raise exception 'La producción debe estar entre 0 y 100000 por hora.';
  end if;
  insert into wow_settings(key, val) values ('throne_gold_h', p_gold::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key, val) values ('throne_wood_h', p_wood::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key, val) values ('throne_ore_h',  p_ore::text)  on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'rates', jsonb_build_object('gold', p_gold, 'wood', p_wood, 'ore', p_ore));
end $$;
grant execute on function public.wow_admin_setthrones(text, numeric, numeric, numeric) to anon, authenticated;

-- ================================================================
-- Integracion con el mercado: ademas de la comision, se abona el
-- tributo del trono (por defecto 1% del valor del trato) al tesoro
-- de cada trono con duenio. (Reemplaza wow_market_take.)
-- ================================================================
create or replace function public.wow_market_take(p_token text, p_id bigint, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; o wow_market_offers; ms bigint;
  take numeric; want_part numeric; fee numeric; net numeric; new_left numeric;
  shp numeric; share numeric; tt record;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select * into o from wow_market_offers where id = p_id for update;
  if o.id is null or not o.active then raise exception 'Esa oferta ya no está disponible.'; end if;
  if o.expires_ms <= ms then
    perform _wow_mkt_add(o.seller, o.give_key, o.give_left);
    update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
    raise exception 'Esa oferta ha caducado.'; end if;
  if o.seller = u.id then raise exception 'Esa oferta es tuya.'; end if;
  take := coalesce(p_qty, 0);
  if take <= 0 then raise exception 'Cantidad inválida.'; end if;
  if take >= o.give_left then
    take := o.give_left;
    want_part := o.want_left;
  else
    if _wow_mkt_is_troop(o.give_key) then take := floor(take); end if;
    if take <= 0 then raise exception 'Cantidad inválida.'; end if;
    want_part := o.want_left * (take / o.give_left);
    if _wow_mkt_is_troop(o.want_key) then
      want_part := greatest(1, round(want_part));
    else
      want_part := round(want_part, 2);
    end if;
    if want_part > o.want_left then want_part := o.want_left; end if;
    if want_part <= 0 then raise exception 'Cantidad demasiado pequeña.'; end if;
  end if;
  -- el comprador paga el total (want)
  perform _wow_mkt_sub(u.id, o.want_key, want_part);
  -- recibe lo ofrecido (give)
  perform _wow_mkt_add(u.id, o.give_key, take);
  -- el vendedor recibe want menos comision; el resto se destruye
  fee := _wow_mkt_fee();
  net := want_part * (1 - fee/100.0);
  if _wow_mkt_is_troop(o.want_key) then net := round(net); end if;
  if net < 0 then net := 0; end if;
  perform _wow_mkt_add(o.seller, o.want_key, net);
  -- tributo del trono: 1% (ajustable) del trato, descontado de la comision
  shp := _wow_throne_pct();
  share := want_part * least(shp, fee) / 100.0;
  if _wow_mkt_is_troop(o.want_key) then share := round(share); end if;
  if share > 0 then
    for tt in select node from wow_thrones where holder is not null loop
      perform _wow_throne_add(tt.node, o.want_key, share);
    end loop;
  end if;
  -- actualizar la oferta
  new_left := o.give_left - take;
  if new_left <= 0.0001 then
    update wow_market_offers set give_left = 0, want_left = 0, active = false where id = o.id;
  else
    update wow_market_offers set give_left = new_left, want_left = greatest(0, o.want_left - want_part) where id = o.id;
  end if;
  return jsonb_build_object('ok', true, 'took', take, 'paid', want_part, 'fee', fee, 'net', net, 'throne_share', share);
end $$;
grant execute on function public.wow_market_take(text, bigint, numeric) to anon, authenticated;

-- ================================================================
-- Ranking: agrega el numero de tronos que controla cada reino.
-- ================================================================
create or replace function public.wow_leaderboard(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'name', w.name, 'faction', w.faction, 'me', (w.id = u.id),
      'points', coalesce((select sum(g.level) from wow_buildings g where g.owner_id = w.id),0) * 100
                + coalesce((select sum(t.qty) from wow_troops t where t.owner_id = w.id),0),
      'level_sum', coalesce((select sum(g.level) from wow_buildings g where g.owner_id = w.id),0),
      'troops', coalesce((select sum(t.qty) from wow_troops t where t.owner_id = w.id),0),
      'thrones', (select count(*) from wow_thrones th where th.holder = w.id))
    order by (select count(*) from wow_thrones th where th.holder = w.id) desc,
             coalesce((select sum(g.level) from wow_buildings g where g.owner_id = w.id),0) * 100
              + coalesce((select sum(t.qty) from wow_troops t where t.owner_id = w.id),0) desc), '[]'::jsonb)
  into out
  from wow_users w where w.active and not coalesce(w.is_admin,false);
  return out;
end $$;
grant execute on function public.wow_leaderboard(text) to anon, authenticated;
