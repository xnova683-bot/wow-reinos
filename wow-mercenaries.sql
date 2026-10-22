-- ================================================================
-- MERCADO NEGRO: mercenarios (tropas al instante pagando CUP)
--   soldado 5 · arquero 6 · jinete 9 · mago 12 CUP por unidad
--   el % del admin va a los administradores; el resto se lo llevan
--   los mercenarios (sale de la circulacion).
-- ================================================================

insert into wow_settings(key,val) values
  ('merc_cost_soldado','5'),
  ('merc_cost_arquero','6'),
  ('merc_cost_jinete','9'),
  ('merc_cost_mago','12'),
  ('merc_admin_pct','20'),
  ('merc_earned','0')
on conflict (key) do nothing;

create or replace function public._wow_merc_price(p_key text)
returns numeric language sql stable as $$
  select greatest(0, coalesce(
    (select val::numeric from wow_settings where key = 'merc_cost_' || p_key),
    case p_key when 'soldado' then 5 when 'arquero' then 6 when 'jinete' then 9 when 'mago' then 12 else 0 end));
$$;
revoke all on function public._wow_merc_price(text) from public, anon, authenticated;

create or replace function public._wow_merc_pct()
returns numeric language sql stable as $$
  select greatest(0, least(100, coalesce((select val::numeric from wow_settings where key='merc_admin_pct'), 20)));
$$;
revoke all on function public._wow_merc_pct() from public, anon, authenticated;

create or replace function public.wow_merc_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; prices jsonb; tq jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  select jsonb_object_agg(v.t, _wow_merc_price(v.t)) into prices
    from (values ('soldado'),('arquero'),('jinete'),('mago')) v(t);
  select coalesce(jsonb_object_agg(tkey, qty), '{}'::jsonb) into tq
    from wow_troops where owner_id = u.id;
  return jsonb_build_object('ok', true, 'cup', coalesce(u.cup,0),
    'prices', prices, 'troops', tq, 'admin_pct', _wow_merc_pct());
end $$;
revoke all on function public.wow_merc_info(text) from public;
grant execute on function public.wow_merc_info(text) to anon, authenticated;

create or replace function public.wow_merc_hire(p_token text, p_key text, p_qty integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; price numeric; cantidad integer; cost numeric; admin_cut numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no contratan mercenarios.'; end if;
  if coalesce(p_key,'') not in ('soldado','arquero','jinete','mago') then
    raise exception 'Tropa no válida.'; end if;
  u := _wow_tick(u.id);
  cantidad := greatest(coalesce(p_qty,0), 0);
  if cantidad < 1 then raise exception 'Elige cuántos mercenarios contratar.'; end if;
  if cantidad > 5000 then raise exception 'Máximo 5.000 mercenarios por contrato.'; end if;
  price := _wow_merc_price(p_key);
  cost := round(price * cantidad, 2);
  if coalesce(u.cup,0) < cost then
    raise exception 'Necesitas % CUP para contratar % %.', cost, cantidad, p_key; end if;
  update wow_users set cup = cup - cost where id = u.id;
  insert into wow_troops(owner_id, tkey, qty) values (u.id, p_key, cantidad)
    on conflict (owner_id, tkey) do update set qty = wow_troops.qty + excluded.qty;
  insert into wow_settings(key,val) values ('merc_earned', cost::text)
    on conflict (key) do update set val = (coalesce(wow_settings.val::numeric,0) + cost)::text;
  admin_cut := round(cost * _wow_merc_pct() / 100.0, 2);
  if admin_cut > 0 then
    update wow_users set cup = coalesce(cup,0) + admin_cut where is_admin = true;
  end if;
  return jsonb_build_object('ok', true, 'key', p_key, 'qty', cantidad, 'cost', cost,
    'admin_cut', admin_cut, 'cup', (select cup from wow_users where id = u.id),
    'total', (select qty from wow_troops where owner_id = u.id and tkey = p_key));
end $$;
revoke all on function public.wow_merc_hire(text, text, integer) from public;
grant execute on function public.wow_merc_hire(text, text, integer) to anon, authenticated;

create or replace function public.wow_admin_setmerc(p_token text, p_soldado numeric, p_arquero numeric, p_jinete numeric, p_mago numeric, p_admin numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if not (p_soldado >= 0 and p_soldado <= 1000000) then raise exception 'El precio del soldado debe estar entre 0 y 1.000.000 CUP.'; end if;
  if not (p_arquero >= 0 and p_arquero <= 1000000) then raise exception 'El precio del arquero debe estar entre 0 y 1.000.000 CUP.'; end if;
  if not (p_jinete >= 0 and p_jinete <= 1000000) then raise exception 'El precio del jinete debe estar entre 0 y 1.000.000 CUP.'; end if;
  if not (p_mago >= 0 and p_mago <= 1000000) then raise exception 'El precio del mago debe estar entre 0 y 1.000.000 CUP.'; end if;
  if not (p_admin >= 0 and p_admin <= 100) then raise exception 'La comisión del admin debe estar entre 0 y 100.'; end if;
  insert into wow_settings(key,val) values ('merc_cost_soldado', p_soldado::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('merc_cost_arquero', p_arquero::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('merc_cost_jinete', p_jinete::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('merc_cost_mago', p_mago::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('merc_admin_pct', p_admin::text) on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true,
    'prices', jsonb_build_object('soldado', _wow_merc_price('soldado'), 'arquero', _wow_merc_price('arquero'),
      'jinete', _wow_merc_price('jinete'), 'mago', _wow_merc_price('mago')),
    'admin_pct', _wow_merc_pct());
end $$;
revoke all on function public.wow_admin_setmerc(text, numeric, numeric, numeric, numeric, numeric) from public;
grant execute on function public.wow_admin_setmerc(text, numeric, numeric, numeric, numeric, numeric) to anon, authenticated;

create or replace function public.wow_admin_merc_stats(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  return jsonb_build_object('ok', true,
    'earned', coalesce((select val::numeric from wow_settings where key='merc_earned'), 0),
    'admin_pct', _wow_merc_pct(),
    'prices', jsonb_build_object('soldado', _wow_merc_price('soldado'), 'arquero', _wow_merc_price('arquero'),
      'jinete', _wow_merc_price('jinete'), 'mago', _wow_merc_price('mago')));
end $$;
revoke all on function public.wow_admin_merc_stats(text) from public;
grant execute on function public.wow_admin_merc_stats(text) to anon, authenticated;
