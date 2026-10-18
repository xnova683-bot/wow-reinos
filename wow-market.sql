-- ================================================================
-- APENDICE MERCADO v2: MERCADO ENTRE JUGADORES
--   - Ofertas con precio libre: el jugador da X y pide Y.
--   - Aceptacion PARCIAL permitida.
--   - Comision configurable por el admin (por defecto 20%): se
--     descuenta de lo que RECIBE el vendedor y se destruye.
--   - El admin NO comercia (solo asigna CUP y ajusta la comision).
--   - Las ofertas caducan en 1 dia (se devuelve lo reservado).
-- Objetos: gold, wood, ore, cup, soldado, arquero, jinete, mago,
--          paladin, dragon.
-- ================================================================

-- ---- quitar la tienda instantanea anterior ----
drop function if exists public.wow_market_sell_troop(text, text, integer);
drop function if exists public.wow_market_buy_troop(text, text, integer);
drop function if exists public.wow_market_sell_resource(text, text, numeric);
drop function if exists public.wow_market_buy_resource(text, text, numeric);

-- ---- tablas ----
create table if not exists public.wow_settings(
  key text primary key,
  val text not null default ''
);
insert into public.wow_settings(key, val) values ('market_fee', '20')
  on conflict (key) do nothing;

create table if not exists public.wow_market_offers(
  id bigserial primary key,
  seller text not null references public.wow_users(id) on delete cascade,
  seller_name text not null default '',
  give_key text not null,
  give_qty numeric(16,2) not null default 0,
  give_left numeric(16,2) not null default 0,
  want_key text not null,
  want_qty numeric(16,2) not null default 0,
  want_left numeric(16,2) not null default 0,
  created bigint not null default 0,
  expires_ms bigint not null default 0,
  active boolean not null default true
);
create index if not exists wow_market_offers_active_idx on public.wow_market_offers(active, expires_ms);

alter table public.wow_settings enable row level security;
alter table public.wow_market_offers enable row level security;

-- ---- helpers internos ----
create or replace function public._wow_mkt_ok(p_key text)
returns boolean language sql immutable as $$
  select p_key in ('gold','wood','ore','cup','soldado','arquero','jinete','mago','paladin','dragon')
$$;

create or replace function public._wow_mkt_is_troop(p_key text)
returns boolean language sql immutable as $$
  select p_key in ('soldado','arquero','jinete','mago','paladin','dragon')
$$;

create or replace function public._wow_mkt_fee()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = 'market_fee'), 20)
$$;

create or replace function public._wow_mkt_sub(p_owner text, p_key text, p_qty numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
declare cur numeric;
begin
  if coalesce(p_qty,0) <= 0 then raise exception 'Cantidad inválida.'; end if;
  if p_key in ('gold','wood','ore','cup') then
    select case p_key when 'gold' then gold when 'wood' then wood when 'ore' then ore else cup end
      into cur from wow_users where id = p_owner;
    if coalesce(cur,0) < p_qty then raise exception 'No tienes suficientes recursos para esa operación.'; end if;
    update wow_users set
        gold = case when p_key = 'gold' then gold - p_qty else gold end,
        wood = case when p_key = 'wood' then wood - p_qty else wood end,
        ore  = case when p_key = 'ore'  then ore  - p_qty else ore  end,
        cup  = case when p_key = 'cup'  then cup  - p_qty else cup  end
      where id = p_owner;
  else
    select qty into cur from wow_troops where owner_id = p_owner and tkey = p_key;
    if coalesce(cur,0) < p_qty then raise exception 'No tienes suficientes tropas para esa operación.'; end if;
    update wow_troops set qty = qty - p_qty::int where owner_id = p_owner and tkey = p_key;
    delete from wow_troops where owner_id = p_owner and tkey = p_key and qty <= 0;
  end if;
end $$;

create or replace function public._wow_mkt_add(p_owner text, p_key text, p_qty numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(p_qty,0) <= 0 then return; end if;
  if p_key in ('gold','wood','ore','cup') then
    update wow_users set
        gold = case when p_key = 'gold' then gold + p_qty else gold end,
        wood = case when p_key = 'wood' then wood + p_qty else wood end,
        ore  = case when p_key = 'ore'  then ore  + p_qty else ore  end,
        cup  = case when p_key = 'cup'  then cup  + p_qty else cup  end
      where id = p_owner;
  else
    insert into wow_troops(owner_id, tkey, qty) values (p_owner, p_key, p_qty::int)
      on conflict (owner_id, tkey) do update set qty = wow_troops.qty + excluded.qty;
  end if;
end $$;

revoke all on function public._wow_mkt_ok(text) from public, anon, authenticated;
revoke all on function public._wow_mkt_is_troop(text) from public, anon, authenticated;
revoke all on function public._wow_mkt_fee() from public, anon, authenticated;
revoke all on function public._wow_mkt_sub(text, text, numeric) from public, anon, authenticated;
revoke all on function public._wow_mkt_add(text, text, numeric) from public, anon, authenticated;

-- ---- comision (lectura publica) ----
create or replace function public.wow_market_fee()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('fee', _wow_mkt_fee())
$$;
grant execute on function public.wow_market_fee() to anon, authenticated;

-- ---- publicar oferta ----
create or replace function public.wow_market_offer(p_token text, p_give text, p_give_qty numeric, p_want text, p_want_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ms bigint; n integer; nid bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  if not _wow_mkt_ok(p_give) then raise exception 'Objeto a dar no válido.'; end if;
  if not _wow_mkt_ok(p_want) then raise exception 'Objeto a pedir no válido.'; end if;
  if coalesce(p_want,'') <> 'cup' then
    raise exception 'En "Pido" solo puedes pedir 🧿 CUP.'; end if;
  if p_give = p_want then raise exception 'No puedes cambiar un objeto por sí mismo.'; end if;
  if coalesce(p_give_qty,0) <= 0 then raise exception 'Cantidad a dar inválida.'; end if;
  if coalesce(p_want_qty,0) <= 0 then raise exception 'Cantidad a pedir inválida.'; end if;
  if _wow_mkt_is_troop(p_give) and p_give_qty <> floor(p_give_qty) then
    raise exception 'Las tropas se comercian en unidades enteras.'; end if;
  if _wow_mkt_is_troop(p_want) and p_want_qty <> floor(p_want_qty) then
    raise exception 'Las tropas se comercian en unidades enteras.'; end if;
  select count(*) into n from wow_market_offers where seller = u.id and active;
  if n >= 5 then raise exception 'Ya tienes el máximo de 5 ofertas activas.'; end if;
  perform _wow_mkt_sub(u.id, p_give, p_give_qty);
  insert into wow_market_offers(seller, seller_name, give_key, give_qty, give_left, want_key, want_qty, want_left, created, expires_ms, active)
    values (u.id, u.name, p_give, p_give_qty, p_give_qty, p_want, p_want_qty, p_want_qty, ms, ms + 86400000, true)
    returning id into nid;
  return jsonb_build_object('ok', true, 'id', nid);
end $$;
grant execute on function public.wow_market_offer(text, text, numeric, text, numeric) to anon, authenticated;

-- ---- listado (ofertas ajenas + mis ofertas) ----
create or replace function public.wow_market_list(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ms bigint; o record; offs jsonb; mine jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  for o in select * from wow_market_offers where active and expires_ms <= ms for update loop
    perform _wow_mkt_add(o.seller, o.give_key, o.give_left);
    update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'who', x.seller_name, 'give', x.give_key, 'give_left', x.give_left, 'give_qty', x.give_qty,
      'want', x.want_key, 'want_left', x.want_left, 'want_qty', x.want_qty, 'expires', x.expires_ms
    ) order by x.id desc), '[]'::jsonb)
   into offs
   from wow_market_offers x join wow_users w on w.id = x.seller
   where x.active and x.seller <> u.id and not w.is_admin;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'give', x.give_key, 'give_left', x.give_left, 'give_qty', x.give_qty,
      'want', x.want_key, 'want_left', x.want_left, 'want_qty', x.want_qty, 'expires', x.expires_ms
    ) order by x.id desc), '[]'::jsonb)
   into mine
   from wow_market_offers x where x.active and x.seller = u.id;
  return jsonb_build_object('ok', true, 'fee', _wow_mkt_fee(), 'offers', offs, 'mine', mine);
end $$;
grant execute on function public.wow_market_list(text) to anon, authenticated;

-- ---- tomar (aceptar) oferta, parcial permitido ----
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
  -- actualizar la oferta
  new_left := o.give_left - take;
  if new_left <= 0.0001 then
    update wow_market_offers set give_left = 0, want_left = 0, active = false where id = o.id;
  else
    update wow_market_offers set give_left = new_left, want_left = greatest(0, o.want_left - want_part) where id = o.id;
  end if;
  return jsonb_build_object('ok', true, 'took', take, 'paid', want_part, 'fee', fee, 'net', net);
end $$;
grant execute on function public.wow_market_take(text, bigint, numeric) to anon, authenticated;

-- ---- cancelar oferta propia (devuelve lo reservado) ----
create or replace function public.wow_market_cancel(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; o wow_market_offers; r numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  select * into o from wow_market_offers where id = p_id for update;
  if o.id is null or not o.active then raise exception 'La oferta ya no existe.'; end if;
  if o.seller <> u.id then raise exception 'Esa oferta no es tuya.'; end if;
  r := o.give_left;
  perform _wow_mkt_add(u.id, o.give_key, r);
  update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
  return jsonb_build_object('ok', true, 'refund', r);
end $$;
grant execute on function public.wow_market_cancel(text, bigint) to anon, authenticated;

-- ---- admin: ajustar comision ----
create or replace function public.wow_admin_setfee(p_token text, p_fee numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  if p_fee is null or p_fee < 0 or p_fee > 90 then raise exception 'La comisión debe estar entre 0 y 90.'; end if;
  insert into wow_settings(key, val) values ('market_fee', p_fee::text)
    on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'fee', p_fee);
end $$;
grant execute on function public.wow_admin_setfee(text, numeric) to anon, authenticated;
