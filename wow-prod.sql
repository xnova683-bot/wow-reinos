-- ================================================================
-- APENDICE CONTROL DE PRODUCCION: el administrador puede regular
-- cuanto producen los reinos.
--   - wow_settings 'prod_mult': multiplicador GLOBAL de produccion
--     (por defecto 1). 0 = nadie produce, 0.5 = la mitad, 2 = doble.
--   - wow_users.prod_mult: multiplicador POR REINO (por defecto 1).
--   - _wow_rate (override): aplica ambos multiplicadores al ritmo de
--     oro/madera/mineral. No toca capacidad, costes ni tiempos.
--   - wow_admin_setprod: cambia el multiplicador global (0 a 10).
--   - wow_admin_setproduser: cambia el de un reino concreto (0 a 10).
--   - wow_state (override): incluye 'prod_mult' para que el cliente
--     pueda avisar de que la produccion del reino esta alterada.
--   - Todos los cambios quedan registrados en wow_events.
-- ================================================================

-- multiplicador global por defecto
insert into wow_settings(key, val) values ('prod_mult', '1') on conflict (key) do nothing;

-- multiplicador por reino
alter table wow_users add column if not exists prod_mult numeric not null default 1;

-- limite comun (0 a 10, 2 decimales)
create or replace function public._wow_prod_clamp(p numeric)
returns numeric language sql immutable as $$
  select round(least(greatest(coalesce(p,1),0),10), 2)
$$;
revoke all on function public._wow_prod_clamp(numeric) from public, anon, authenticated;

-- multiplicador global efectivo
create or replace function public._wow_prod_global()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select _wow_prod_clamp(coalesce((select val::numeric from wow_settings where key = 'prod_mult'), 1))
$$;
revoke all on function public._wow_prod_global() from public, anon, authenticated;

-- informacion publica del multiplicador global
create or replace function public.wow_prod_info()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('mult', _wow_prod_global())
$$;
grant execute on function public.wow_prod_info() to anon, authenticated;

-- listado de reinos con su multiplicador de produccion
create or replace function public.wow_admin_list(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; out jsonb; ms bigint;
begin
  a := _wow_admin(p_token);
  perform _wow_resolve();
  ms := (extract(epoch from now())*1000)::bigint;
  select jsonb_build_object('now', ms, 'me', a.id, 'prod_mult', _wow_prod_global(), 'users', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', w.id, 'name', w.name, 'faction', w.faction, 'pos', w.pos,
      'active', w.active, 'is_admin', w.is_admin,
      'gold', floor(w.gold), 'wood', floor(w.wood), 'ore', floor(w.ore),
      'cup', round(coalesce(w.cup,0), 2),
      'prod_mult', _wow_prod_clamp(w.prod_mult),
      'points', _wow_points(w.id),
      'troops', coalesce((select sum(qty) from wow_troops where owner_id = w.id),0),
      'alliance', coalesce((select tag from wow_alliances where id = w.alliance),''),
      'created', w.created, 'last', w.last_ms
    ) order by w.created)
    from wow_users w
  ), '[]')) into out;
  return out;
end $$;
grant execute on function public.wow_admin_list(text) to anon, authenticated;

-- ritmo de produccion con los multiplicadores aplicados
create or replace function public._wow_rate(p_owner text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare g integer; w integer; o integer; mk integer; mult numeric; pm numeric; base jsonb;
begin
  select coalesce(max(case when bkey='tesoreria' then level end),0),
         coalesce(max(case when bkey='aserradero' then level end),0),
         coalesce(max(case when bkey='mina' then level end),0),
         coalesce(max(case when bkey='mercado' then level end),0)
    into g,w,o,mk from wow_buildings where owner_id = p_owner;
  mult := 1 + 0.05 * mk;
  pm := _wow_prod_global() * _wow_prod_clamp(coalesce((select prod_mult from wow_users where id = p_owner), 1));
  return jsonb_build_object('gold', round(round((30+25*g)*mult) * pm),
                            'wood', round(round((30+25*w)*mult) * pm),
                            'ore',  round(round((30+25*o)*mult) * pm));
end $$;
revoke all on function public._wow_rate(text) from public, anon, authenticated;

-- cambiar el multiplicador GLOBAL (solo admin)
create or replace function public.wow_admin_setprod(p_token text, p_mult numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; v numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'Solo el administrador puede hacer esto.'; end if;
  v := _wow_prod_clamp(p_mult);
  insert into wow_settings(key, val) values ('prod_mult', v::text)
    on conflict (key) do update set val = excluded.val;
  insert into wow_events(kind, txt, created)
    values ('prod', 'Producción global puesta en x'||v||' por '||u.name, (extract(epoch from now())*1000)::bigint);
  return jsonb_build_object('ok', true, 'prod_mult', v);
end $$;
revoke all on function public.wow_admin_setprod(text, numeric) from public, anon, authenticated;

-- cambiar el multiplicador de UN REINO (solo admin)
create or replace function public.wow_admin_setproduser(p_token text, p_id text, p_mult numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_users; v numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'Solo el administrador puede hacer esto.'; end if;
  select * into t from wow_users where id = p_id;
  if t.id is null then raise exception 'Ese reino no existe.'; end if;
  v := _wow_prod_clamp(p_mult);
  update wow_users set prod_mult = v where id = t.id;
  insert into wow_events(kind, txt, created)
    values ('prod', 'Producción de '||t.name||' puesta en x'||v||' por '||u.name, (extract(epoch from now())*1000)::bigint);
  return jsonb_build_object('ok', true, 'id', t.id, 'prod_mult', v);
end $$;
revoke all on function public.wow_admin_setproduser(text, text, numeric) from public, anon, authenticated;

-- estado: avisa del multiplicador del reino (global x suyo)
create or replace function public.wow_state(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; blds jsonb; trs jsonb; que jsonb; cap numeric; rate jsonb; ms bigint; pts integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  cap := _wow_cap(u.id); rate := _wow_rate(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select coalesce(jsonb_agg(jsonb_build_object('key', v.k, 'level', coalesce(b.level,0),
             'cost', _wow_bcost(v.k, coalesce(b.level,0)), 'time', _wow_btime(v.k, coalesce(b.level,0)),
             'prod', _wow_bprod(v.k, coalesce(b.level,0))) order by v.ord), '[]') into blds
    from (values ('mina',1),('aserradero',2),('tesoreria',3),('almacen',4),('cuartel',5),
                 ('herreria',6),('fortaleza',7),('mercado',8),('muralla',9)) v(k,ord)
    left join wow_buildings b on b.owner_id = u.id and b.bkey = v.k;
  select coalesce(jsonb_agg(jsonb_build_object('key', v.t, 'qty', coalesce(t.qty,0),
             'cost', _wow_tcost(v.t), 'time', _wow_ttime(v.t),
             'atk', _wow_atk(v.t), 'hp', _wow_hp(v.t), 'req', _wow_treq(v.t)) order by v.ord), '[]') into trs
    from (values ('soldado',1),('arquero',2),('jinete',3),('mago',4),('paladin',5),('dragon',6)) v(t,ord)
    left join wow_troops t on t.owner_id = u.id and t.tkey = v.t;
  select coalesce(jsonb_agg(jsonb_build_object('kind', q.kind, 'ref', q.ref, 'qty', q.qty, 'unit_ms', q.unit_ms,
           'start', q.start_ms, 'finish', q.finish_ms) order by q.kind), '[]') into que
    from wow_queue q where q.owner_id = u.id;
  pts := (select coalesce(sum(level),0) from wow_buildings where owner_id = u.id) * 100
       + (select coalesce(sum(qty),0) from wow_troops where owner_id = u.id);
  return jsonb_build_object('id', u.id, 'name', u.name, 'faction', u.faction, 'is_admin', u.is_admin,
    'gold', u.gold, 'wood', u.wood, 'ore', u.ore, 'cup', coalesce(u.cup,0), 'capacity', cap, 'rate', rate,
    'prod_mult', (_wow_prod_global() * _wow_prod_clamp(u.prod_mult)),
    'buildings', blds, 'troops', trs, 'queue', que->0, 'queues', que, 'points', pts, 'now', ms,
    'alliance', u.alliance,
    'ally_tag', coalesce((select tag from wow_alliances where id = u.alliance), ''),
    'ally_emblem', _wow_ally_icon(u.alliance),
    'online', _wow_online_count());
end $$;
revoke all on function public.wow_state(text) from public, anon, authenticated;
