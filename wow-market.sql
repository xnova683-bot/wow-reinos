-- ================================================================
-- APENDICE MERCADO: compra/venta de recursos y tropas con CUP
--   CUP solo la obtiene un usuario mediante wow_admin_grant.
--   - VENDER: gasta el recurso/tropa y obtiene CUP.
--   - COMPRAR: gasta CUP y obtiene el recurso/tropa.
-- ================================================================

create or replace function public._wow_tval(p_key text)
returns integer language sql immutable as $$
  select case p_key when 'soldado' then 50 when 'arquero' then 60 when 'jinete' then 100
                     when 'mago' then 150 when 'paladín' then 200 else 300 end;
$$;

revoke all on function public._wow_tval(text) from public, anon, authenticated;
grant execute on function public._wow_tval(text) to anon, authenticated;

-- VENDER tropas por CUP
create or replace function public.wow_market_sell_troop(p_token text, p_key text, p_qty integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; val integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  val := _wow_tval(p_key);
  if val is null then raise exception 'Tropa no válida.'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'Cantidad inválida.'; end if;
  if coalesce((select qty from wow_troops where owner_id=u.id and tkey=p_key),0) < p_qty then
    raise exception 'No tienes suficientes tropas de ese tipo.'; end if;
  update wow_troops set qty = qty - p_qty where owner_id = u.id and tkey = p_key;
  delete from wow_troops where owner_id = u.id and tkey = p_key and qty <= 0;
  update wow_users set cup = coalesce(cup,0) + p_qty * val where id = u.id;
  return jsonb_build_object('ok', true, 'qty', p_qty, 'val', val, 'cup_gain', p_qty * val);
end $$;
grant execute on function public.wow_market_sell_troop(text, text, integer) to anon, authenticated;

-- COMPRAR tropas con CUP
create or replace function public.wow_market_buy_troop(p_token text, p_key text, p_qty integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; val integer; cost integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  val := _wow_tval(p_key);
  if val is null then raise exception 'Tropa no válida.'; end if;
  if coalesce(p_qty,0) <= 0 then raise exception 'Cantidad inválida.'; end if;
  cost := p_qty * val;
  if (coalesce(u.cup,0)) < cost then raise exception 'Necesitas % CUP para comprar una unidad de %.', cost, p_key; end if;
  update wow_users set cup = coalesce(u.cup,0) - cost where id = u.id;
  insert into wow_troops(owner_id, tkey, qty) values (u.id, p_key, p_qty)
    on conflict (owner_id, tkey) do update set qty = wow_troops.qty + p_qty;
  return jsonb_build_object('ok', true, 'qty', p_qty, 'val', val, 'cup_cost', cost);
end $$;
grant execute on function public.wow_market_buy_troop(text, text, integer) to anon, authenticated;

-- VENDER recursos por CUP
create or replace function public.wow_market_sell_resource(p_token text, p_key text, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; upc numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  if p_key not in ('gold','wood','ore') then raise exception 'Recurso no válido.'; end if;
  upc := case p_key when 'gold' then 10 when 'wood' then 20 else 30 end;
  if coalesce(p_qty,0) <= 0 then raise exception 'Cantidad inválida.'; end if;
  if (case p_key when 'gold' then u.gold when 'wood' then u.wood else u.ore end) < p_qty then
    raise exception 'No tienes suficientes recursos.'; end if;
  update wow_users set
      gold = case when p_key = 'gold' then u.gold - p_qty else u.gold end,
      wood = case when p_key = 'wood' then u.wood - p_qty else u.wood end,
      ore  = case when p_key = 'ore'  then u.ore  - p_qty else u.ore  end,
      cup  = coalesce(u.cup,0) + floor(p_qty / upc)
    where id = u.id;
  return jsonb_build_object('ok', true, 'qty', p_qty, 'upc', upc, 'cup_gain', floor(p_qty / upc));
end $$;
grant execute on function public.wow_market_sell_resource(text, text, numeric) to anon, authenticated;

-- COMPRAR recursos con CUP
create or replace function public.wow_market_buy_resource(p_token text, p_key text, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; upc numeric; cost numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  if p_key not in ('gold','wood','ore') then raise exception 'Recurso no válido.'; end if;
  upc := case p_key when 'gold' then 10 when 'wood' then 20 else 30 end;
  if coalesce(p_qty,0) <= 0 then raise exception 'Cantidad inválida.'; end if;
  cost := p_qty * upc;
  if (coalesce(u.cup,0)) < cost then raise exception 'Necesitas % CUP para comprar %.', cost, p_key; end if;
  update wow_users set
      gold = case when p_key = 'gold' then u.gold + p_qty else u.gold end,
      wood = case when p_key = 'wood' then u.wood + p_qty else u.wood end,
      ore  = case when p_key = 'ore'  then u.ore  + p_qty else u.ore  end,
      cup  = coalesce(u.cup,0) - cost
    where id = u.id;
  return jsonb_build_object('ok', true, 'qty', p_qty, 'upc', upc, 'cup_cost', cost);
end $$;
grant execute on function public.wow_market_buy_resource(text, text, numeric) to anon, authenticated;
