-- ================================================================
-- APENDICE MINEROS Y LEÑADORES: segundo contrato de la taberna
--   - wow_miner_contracts: contrato por reino (owner, until_ms, created)
--   - Precio 200 CUP / 30 dias (configurable)
--   - Efecto: duplica la produccion por hora de oro/madera/mineral
--   - Independiente de la Madam. Se pueden tener ambos a la vez.
--   - Reparto identico al contrato de la Madam:
--     % admin (madam_admin_pct) + resto a tronos/aldeas (tavern_pct_trono/altea)
-- ================================================================

insert into wow_settings(key,val) values
  ('miner_cost','200'),
  ('miner_days','30')
on conflict (key) do nothing;

create table if not exists wow_miner_contracts (
  owner text primary key,
  until_ms bigint not null default 0,
  created bigint not null default 0
);

create or replace function public._wow_miner_cost()
returns numeric language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='miner_cost'),200);
$$;

create or replace function public._wow_miner_days()
returns numeric language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='miner_days'),30);
$$;

create or replace function public._wow_miner_active(p_owner text)
returns boolean language sql stable set search_path to 'public' as $$
  select exists (
    select 1 from wow_miner_contracts c
    where c.owner = p_owner
      and c.until_ms > (extract(epoch from now())*1000)::bigint
  );
$$;

create or replace function public.wow_miner_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; c wow_miner_contracts; ms bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select * into c from wow_miner_contracts where owner = u.id;
  return jsonb_build_object('ok', true,
    'cost', _wow_miner_cost(), 'days', _wow_miner_days(),
    'cup', coalesce(u.cup,0),
    'active', (c.owner is not null and c.until_ms > ms),
    'until', coalesce(c.until_ms, 0),
    'remain_ms', greatest(0, coalesce(c.until_ms,0) - ms));
end $$;
revoke all on function public.wow_miner_info(text) from public;
grant execute on function public.wow_miner_info(text) to anon, authenticated;

create or replace function public.wow_miner_hire(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; c wow_miner_contracts; cost numeric; ms bigint; base bigint; until_ms bigint; repartido numeric; admin_cut numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no contratan.'; end if;
  u := _wow_tick(u.id);
  cost := _wow_miner_cost();
  if coalesce(u.cup,0) < cost then raise exception 'Necesitas % CUP para contratar a los mineros.', cost; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  select * into c from wow_miner_contracts where owner = u.id for update;
  base := greatest(ms, coalesce(c.until_ms,0));
  until_ms := base + (_wow_miner_days()*86400000)::bigint;
  update wow_users set cup = cup - cost where id = u.id;
  insert into wow_settings(key,val) values ('madam_earned', cost::text)
    on conflict (key) do update set val = (coalesce(wow_settings.val::numeric,0) + cost)::text;
  insert into wow_miner_contracts(owner, until_ms, created)
    values (u.id, until_ms, ms)
    on conflict (owner) do update set until_ms = excluded.until_ms;
  admin_cut := round(cost * _wow_madam_admin_pct() / 100.0, 2);
  if admin_cut > 0 then
    update wow_users set cup = coalesce(cup,0) + admin_cut where is_admin = true;
  end if;
  repartido := _wow_tavern_distribute(cost - admin_cut, 'cup');
  return jsonb_build_object('ok', true, 'cost', cost, 'until', until_ms,
    'cup', (select cup from wow_users where id=u.id), 'admin_cut', admin_cut, 'shared', repartido);
end $$;
revoke all on function public.wow_miner_hire(text) from public;
grant execute on function public.wow_miner_hire(text) to anon, authenticated;

-- Sobreescribir _wow_rate para duplicar la produccion si hay contrato de mineros activo
create or replace function public._wow_rate(p_owner text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare g integer; w integer; o integer; mk integer; mult numeric; pm numeric;
        gg numeric; ww numeric; oo numeric;
begin
  select coalesce(max(case when bkey='tesoreria' then level end),0),
         coalesce(max(case when bkey='aserradero' then level end),0),
         coalesce(max(case when bkey='mina' then level end),0),
         coalesce(max(case when bkey='mercado' then level end),0)
    into g,w,o,mk from wow_buildings where owner_id = p_owner;
  mult := 1 + 0.05 * mk;
  pm := _wow_prod_global() * _wow_prod_clamp(coalesce((select prod_mult from wow_users where id = p_owner), 1));
  gg := round(round((30+25*g)*mult) * pm);
  ww := round(round((30+25*w)*mult) * pm);
  oo := round(round((30+25*o)*mult) * pm);
  if _wow_miner_active(p_owner) then
    gg := gg * 2;
    ww := ww * 2;
    oo := oo * 2;
  end if;
  return jsonb_build_object('gold', gg, 'wood', ww, 'ore', oo);
end $$;
revoke all on function public._wow_rate(text) from public, anon, authenticated;

create or replace function public.wow_admin_setmineros(p_token text, p_cost numeric, p_days numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if p_cost is null or p_cost < 0 or p_cost > 1000000 then raise exception 'El precio debe estar entre 0 y 1.000.000 CUP.'; end if;
  if p_days is null or p_days < 1 or p_days > 365 then raise exception 'La duración debe estar entre 1 y 365 días.'; end if;
  insert into wow_settings(key,val) values ('miner_cost', p_cost::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('miner_days', p_days::text) on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'cost', _wow_miner_cost(), 'days', _wow_miner_days());
end $$;
revoke all on function public.wow_admin_setmineros(text, numeric, numeric) from public;
grant execute on function public.wow_admin_setmineros(text, numeric, numeric) to anon, authenticated;

create or replace function public.wow_admin_miner_contracts(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; ms bigint;
begin
  a := _wow_admin(p_token);
  ms := (extract(epoch from now())*1000)::bigint;
  return jsonb_build_object('now', ms,
    'contracts', coalesce((
      select jsonb_agg(jsonb_build_object(
        'owner', c.owner, 'name', w.name, 'faction', w.faction,
        'alliance', coalesce(al.tag, ''),
        'until', c.until_ms, 'remain_ms', greatest(0, c.until_ms - ms)
      ) order by c.until_ms asc)
      from wow_miner_contracts c
      join wow_users w on w.id = c.owner
      left join wow_alliances al on al.id = w.alliance
      where c.until_ms > ms
    ), '[]'::jsonb));
end $$;
revoke all on function public.wow_admin_miner_contracts(text) from public;
grant execute on function public.wow_admin_miner_contracts(text) to anon, authenticated;
