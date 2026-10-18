-- ================================================================
-- APENDICE ONLINE: reinos en linea (contador publico)
--   - last_ms se actualiza en cada refresco (wow_state -> _wow_tick),
--     que el cliente dispara cada 20 s mientras el juego esta abierto.
--   - "en linea" = reino activo con last_ms dentro del umbral
--     (online_min minutos, 5 por defecto, ajustable por admin).
--   - Cuenta por usuario (varias pestanas = 1) e incluye a Administracion.
-- ================================================================

insert into public.wow_settings(key, val) values ('online_min', '5')
  on conflict (key) do nothing;

-- minutos que definen "en linea"
create or replace function public._wow_online_min()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = 'online_min'), 5)
$$;
revoke all on function public._wow_online_min() from public, anon, authenticated;

-- reinos activos vistos dentro del umbral
create or replace function public._wow_online_count()
returns integer language sql stable security definer set search_path to 'public' as $$
  select count(*)::int from wow_users
   where active
     and last_ms >= (extract(epoch from now())*1000)::bigint
                    - (_wow_online_min() * 60000)::bigint
$$;
revoke all on function public._wow_online_count() from public, anon, authenticated;

-- consulta publica (para el juego)
create or replace function public.wow_online(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  return jsonb_build_object('count', _wow_online_count(), 'min', _wow_online_min());
end $$;
grant execute on function public.wow_online(text) to anon, authenticated;

-- info para el panel admin
create or replace function public.wow_online_info()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('min', _wow_online_min(), 'count', _wow_online_count())
$$;
grant execute on function public.wow_online_info() to anon, authenticated;

-- ajustar umbral en minutos (solo admin)
create or replace function public.wow_admin_setonline(p_token text, p_min numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if p_min is null or p_min < 1 or p_min > 60 then
    raise exception 'El tiempo en línea debe estar entre 1 y 60 minutos.'; end if;
  insert into wow_settings(key, val) values ('online_min', p_min::text)
    on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'min', p_min);
end $$;
grant execute on function public.wow_admin_setonline(text, numeric) to anon, authenticated;

-- ---- wow_state: incluye el contador de reinos en linea ----
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
    from (values ('mina',1),('aserradero',2),('tesoreria',3),('almacen',4),('cuartel',5),('muralla',6)) v(k,ord)
    left join wow_buildings b on b.owner_id = u.id and b.bkey = v.k;
  select coalesce(jsonb_agg(jsonb_build_object('key', v.t, 'qty', coalesce(t.qty,0),
             'cost', _wow_tcost(v.t), 'time', _wow_ttime(v.t),
             'atk', _wow_atk(v.t), 'hp', _wow_hp(v.t)) order by v.ord), '[]') into trs
    from (values ('soldado',1),('arquero',2),('jinete',3),('mago',4),('paladin',5),('dragon',6)) v(t,ord)
    left join wow_troops t on t.owner_id = u.id and t.tkey = v.t;
  select coalesce(jsonb_agg(jsonb_build_object('kind', q.kind, 'ref', q.ref, 'qty', q.qty, 'unit_ms', q.unit_ms,
           'start', q.start_ms, 'finish', q.finish_ms) order by q.kind), '[]') into que
    from wow_queue q where q.owner_id = u.id;
  pts := (select coalesce(sum(level),0) from wow_buildings where owner_id = u.id) * 100
       + (select coalesce(sum(qty),0) from wow_troops where owner_id = u.id);
  return jsonb_build_object('id', u.id, 'name', u.name, 'faction', u.faction, 'is_admin', u.is_admin,
    'gold', u.gold, 'wood', u.wood, 'ore', u.ore, 'cup', coalesce(u.cup,0), 'capacity', cap, 'rate', rate,
    'buildings', blds, 'troops', trs, 'queue', que->0, 'queues', que, 'points', pts, 'now', ms,
    'alliance', u.alliance,
    'ally_tag', coalesce((select tag from wow_alliances where id = u.alliance), ''),
    'online', _wow_online_count());
end $$;
grant execute on function public.wow_state(text) to anon, authenticated;
