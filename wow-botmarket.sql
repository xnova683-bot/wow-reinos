-- ================================================================
-- APENDICE MERCADO DE LOS REINOS AUTOMATICOS
--   - Los reinos automaticos VENDEN recursos y tropas por CUP, al
--     precio que fija el administrador (rango min-max por objeto).
--     NUNCA compran: no aceptan ofertas de nadie.
--   - El CUP que ganan va directo a la cuenta de Administracion y
--     se lleva un contador (wow_settings.bot_cup_earned) para el
--     panel del administrador.
--   - El administrador fija el rango de cada objeto:
--     hasta = 0 significa "eso no lo venden".
--   - _wow_bot_market: lo llama el turno global (wow_bots_tick).
--   - wow_market_take (override): si el vendedor es un reino
--     automatico, el CUP va a Administracion en vez de al bot.
-- ================================================================

create table if not exists public.wow_bot_prices(
  item text primary key,
  lo numeric(16,4) not null default 0,
  hi numeric(16,4) not null default 0
);
alter table public.wow_bot_prices enable row level security;
revoke all on table public.wow_bot_prices from public, anon, authenticated;

insert into public.wow_bot_prices(item, lo, hi) values
  ('gold',0.10,0.30), ('wood',0.05,0.15), ('ore',0.20,0.50),
  ('soldado',2,4), ('arquero',3,6), ('jinete',5,10),
  ('mago',8,16), ('paladin',12,24), ('dragon',25,50)
on conflict (item) do nothing;

insert into public.wow_settings(key, val) values ('bot_cup_earned', '0')
  on conflict (key) do nothing;

-- objetos que pueden vender (nunca cup)
create or replace function public._wow_bot_items()
returns text[] language sql immutable as $$
  select array['gold','wood','ore','soldado','arquero','jinete','mago','paladin','dragon']::text[]
$$;
revoke all on function public._wow_bot_items() from public, anon, authenticated;

-- cuenta de administracion (la primera que exista)
create or replace function public._wow_bot_bank()
returns text language sql stable security definer set search_path to 'public' as $$
  select id from wow_users where is_admin order by created, id limit 1
$$;
revoke all on function public._wow_bot_bank() from public, anon, authenticated;

-- ingresar el CUP de una venta de bot: a Administracion + contador
create or replace function public._wow_bot_bank_add(p_qty numeric, p_seller text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare tgt text;
begin
  if coalesce(p_qty,0) <= 0 then return; end if;
  tgt := _wow_bot_bank();
  if tgt is null or tgt = p_seller then tgt := p_seller; end if;
  update wow_users set cup = cup + p_qty where id = tgt;
  insert into wow_settings(key, val) values ('bot_cup_earned', p_qty::text)
    on conflict (key) do update set val = (coalesce(nullif(wow_settings.val,'')::numeric,0) + p_qty)::text;
end $$;
revoke all on function public._wow_bot_bank_add(numeric, text) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- panel del administrador: precios + lo que han ganado
-- ----------------------------------------------------------------
create or replace function public.wow_admin_bot_prices(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  return jsonb_build_object('ok', true,
    'earned', coalesce((select nullif(val,'')::numeric from wow_settings where key = 'bot_cup_earned'), 0),
    'admin_cup', coalesce((select cup from wow_users where id = _wow_bot_bank()), 0),
    'prices', coalesce((select jsonb_agg(jsonb_build_object('item', p.item, 'lo', p.lo, 'hi', p.hi)
                order by array_position(_wow_bot_items(), p.item)) from wow_bot_prices p), '[]'::jsonb),
    'offers', (select count(*) from wow_market_offers o join wow_bots b on b.user_id = o.seller
                join wow_users w on w.id = o.seller
                where o.active));
end $$;
grant execute on function public.wow_admin_bot_prices(text) to anon, authenticated;

create or replace function public.wow_admin_bot_price(p_token text, p_item text, p_lo numeric, p_hi numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; lo numeric; hi numeric;
begin
  a := _wow_admin(p_token);
  if not (coalesce(p_item,'') = any(_wow_bot_items())) then
    raise exception 'Ese objeto no se puede vender.'; end if;
  lo := greatest(0, coalesce(p_lo,0));
  hi := greatest(0, coalesce(p_hi,0));
  if hi > 0 and hi < lo then raise exception 'El precio máximo no puede ser menor que el mínimo.'; end if;
  if lo > 100000 or hi > 100000 then raise exception 'Ese precio es demasiado alto.'; end if;
  insert into wow_bot_prices(item, lo, hi) values (p_item, lo, hi)
    on conflict (item) do update set lo = excluded.lo, hi = excluded.hi;
  return jsonb_build_object('ok', true, 'item', p_item, 'lo', lo, 'hi', hi, 'on', hi > 0);
end $$;
grant execute on function public.wow_admin_bot_price(text, text, numeric, numeric) to anon, authenticated;

-- ----------------------------------------------------------------
-- el reino automatico pone una oferta de venta (si le sobra algo)
-- ----------------------------------------------------------------
create or replace function public._wow_bot_market(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  b wow_bots; it text; plo numeric; phi numeric; price numeric; stock numeric;
  sell numeric; want numeric; n integer; ms bigint; cand text[] := '{}';
begin
  select * into b from wow_bots where user_id = p_id and active;
  if b.user_id is null then return; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  select count(*) into n from wow_market_offers where seller = p_id and active;
  if n >= 2 then return; end if;                 -- como mucho 2 ofertas a la vez
  if random() > 0.35 then return; end if;        -- no lo intentan cada minuto
  foreach it in array _wow_bot_items() loop
    select p.lo, p.hi into plo, phi from wow_bot_prices p where p.item = it;
    if coalesce(phi,0) <= 0 then continue; end if; -- desactivado por el admin
    if it in ('gold','wood','ore') then
      select case it when 'gold' then gold when 'wood' then wood else ore end
        into stock from wow_users where id = p_id;
      if coalesce(stock,0) < 400 then continue; end if;   -- solo sobrantes
    else
      select qty into stock from wow_troops where owner_id = p_id and tkey = it;
      if coalesce(stock,0) < 30 then continue; end if;
    end if;
    cand := cand || it;
  end loop;
  if array_length(cand, 1) is null then return; end if;
  it := cand[1 + floor(random() * array_length(cand, 1))::int];
  select p.lo, p.hi into plo, phi from wow_bot_prices p where p.item = it;
  if it in ('gold','wood','ore') then
    select case it when 'gold' then gold when 'wood' then wood else ore end
      into stock from wow_users where id = p_id;
    sell := floor(stock * 0.25);
    if sell > 1000 then sell := 1000; end if;
  else
    select qty into stock from wow_troops where owner_id = p_id and tkey = it;
    sell := greatest(5, floor(stock * 0.10));
    if sell > 200 then sell := 200; end if;
  end if;
  if coalesce(sell,0) <= 0 then return; end if;
  price := plo + random() * (phi - plo);
  if coalesce(price,0) <= 0 then return; end if;
  want := round(sell * price, 2);
  if coalesce(want,0) <= 0 then return; end if;
  begin
    perform _wow_mkt_sub(p_id, it, sell);
  exception when others then return;
  end;
  insert into wow_market_offers(seller, seller_name, give_key, give_qty, give_left, want_key, want_qty, want_left, created, expires_ms, active)
    values (p_id, (select name from wow_users where id = p_id), it, sell, sell, 'cup', want, want, ms, ms + 86400000, true);
end $$;
revoke all on function public._wow_bot_market(text) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- turno global (igual que el interruptor + mercado de los bots)
-- ----------------------------------------------------------------
create or replace function public.wow_bots_tick(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare b record; ms bigint; n integer := 0; mx bigint;
begin
  perform _wow_resolve();
  if _wow_bot_auto() = 0 then return jsonb_build_object('ok', true, 'auto', false, 'acted', 0); end if;
  ms := (extract(epoch from now())*1000)::bigint;
  update wow_users set last_ms = ms
   where active and id in (select user_id from wow_bots where active);
  for b in select user_id, level from wow_bots where active and (p_force or next_ms <= ms) loop
    begin
      perform _wow_bot_act(b.user_id);
      perform _wow_bot_market(b.user_id);
      n := n + 1;
    exception when others then
      update wow_bots set next_ms = ms + 60000 where user_id = b.user_id;
    end;
    mx := ms + (((_wow_bot_level(b.level)->>'min')::int * 90000))::bigint;
    update wow_bots set next_ms = least(next_ms, mx) where user_id = b.user_id;
  end loop;
  return jsonb_build_object('ok', true, 'auto', true, 'acted', n);
end $$;
revoke all on function public.wow_bots_tick(boolean) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- aceptar oferta (override): el CUP de un bot va a Administracion
-- ----------------------------------------------------------------
create or replace function public.wow_market_take(p_token text, p_id bigint, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; o wow_market_offers; ms bigint;
  take numeric; want_part numeric; fee numeric; net numeric; new_left numeric;
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
  perform _wow_mkt_sub(u.id, o.want_key, want_part);
  perform _wow_mkt_add(u.id, o.give_key, take);
  fee := _wow_mkt_fee();
  net := want_part * (1 - fee/100.0);
  if _wow_mkt_is_troop(o.want_key) then net := round(net); end if;
  if net < 0 then net := 0; end if;
  -- el CUP de la venta de un reino automatico va a Administracion
  if o.want_key = 'cup' and exists(select 1 from wow_bots where user_id = o.seller) then
    perform _wow_bot_bank_add(net, o.seller);
  else
    perform _wow_mkt_add(o.seller, o.want_key, net);
  end if;
  new_left := o.give_left - take;
  if new_left <= 0.0001 then
    update wow_market_offers set give_left = 0, want_left = 0, active = false where id = o.id;
  else
    update wow_market_offers set give_left = new_left, want_left = greatest(0, o.want_left - want_part) where id = o.id;
  end if;
  return jsonb_build_object('ok', true, 'took', take, 'paid', want_part, 'fee', fee, 'net', net);
end $$;
grant execute on function public.wow_market_take(text, bigint, numeric) to anon, authenticated;
