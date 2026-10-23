-- Estadísticas de CUP para el panel de administración
create or replace function public.wow_admin_cup_stats(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare u wow_users;
declare users jsonb;
declare nodes jsonb;
declare tu numeric := 0;
declare tf numeric := 0;
declare ta numeric := 0;
declare tt numeric := 0;
begin
  u := _wow_sess(p_token);
  if u.id is null or not coalesce(u.is_admin, false) then
    raise exception 'No tienes permisos de administrador.';
  end if;
  -- CUP en manos de jugadores
  select coalesce(sum(coalesce(cup, 0)), 0) into tu
    from public.wow_users
   where coalesce(active, true);
  -- CUP en tesoros de tronos/fortalezas y aldeas
  select coalesce(sum(qty) filter (where public._wow_node_kind(node) <> 'aldea'), 0),
         coalesce(sum(qty) filter (where public._wow_node_kind(node) = 'aldea'), 0)
    into tf, ta
    from public.wow_throne_treasure
   where key = 'cup';
  tf := coalesce(tf, 0);
  ta := coalesce(ta, 0);
  tt := coalesce(tu, 0) + tf + ta;
  -- Listado por jugador
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', w.id,
           'name', w.name,
           'alliance', coalesce(w.alliance, ''),
           'pos', w.pos,
           'cup', coalesce(w.cup, 0)
         ) order by coalesce(w.cup, 0) desc, w.name asc), '[]'::jsonb)
    into users
    from public.wow_users w
   where coalesce(w.active, true);
  -- Listado por nodo (fortalezas/aldeas)
  select coalesce(jsonb_agg(jsonb_build_object(
           'node', th.node,
           'name', th.name,
           'kind', public._wow_node_kind(th.node),
           'holder', coalesce(th.holder_name, ''),
           'holder_id', th.holder,
           'cup', coalesce((select x.qty from public.wow_throne_treasure x where x.node = th.node and x.key = 'cup'), 0)
         ) order by public._wow_node_kind(th.node), th.node), '[]'::jsonb)
    into nodes
    from public.wow_thrones th;
  return jsonb_build_object(
    'ok', true,
    'total_users', tu,
    'total_fortalezas', tf,
    'total_aldeas', ta,
    'total', tt,
    'users', users,
    'nodes', nodes
  );
end;
$$;

revoke all on function public.wow_admin_cup_stats(text) from public, anon, authenticated;
grant execute on function public.wow_admin_cup_stats(text) to anon, authenticated;
