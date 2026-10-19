-- ================================================================
-- APENDICE EMBLEMA DE ALIANZA
--   - El lider elige un icono (emoji) para su clan.
--   - El emblema sale en el mapa sobre las ALDEAS y FORTALEZAS
--     conquistadas por la alianza (en vez del 🏛️ por defecto),
--     en la ficha de cada lugar y en la cabecera de la alianza.
--   - wow_alliance_info devuelve el emblema actual y la lista de
--     emblemas disponibles (para pintar el selector).
--   - Solo el lider puede cambiarlo; '' lo quita.
-- ================================================================

alter table public.wow_alliances add column if not exists emblem text not null default '';

-- emblemas disponibles
create or replace function public._wow_emblems()
returns text[] language sql immutable as $$
  select array['🦁','🐺','🐉','🦅','🐻','🐍','🕷️','🦂','🐗','🦌','⚔️','🛡️','👑','💀',
               '🔥','⚡','🌙','☀️','⭐','🌊','🌲','🏔️','🏰','🏹','⚓','🔱']::text[]
$$;
revoke all on function public._wow_emblems() from public, anon, authenticated;

-- emblema de una alianza ('' = sin emblema)
create or replace function public._wow_ally_icon(p_ally text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select emblem from wow_alliances where id = p_ally), '')
$$;
revoke all on function public._wow_ally_icon(text) from public, anon, authenticated;

-- elegir o quitar el emblema (solo el lider)
create or replace function public.wow_alliance_emblem(p_token text, p_icon text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a wow_alliances; ic text;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'No estás en ninguna alianza.'; end if;
  select * into a from wow_alliances where id = u.alliance;
  if a.id is null then raise exception 'Esa alianza ya no existe.'; end if;
  if a.leader <> u.id then raise exception 'Solo el líder puede elegir el emblema de la alianza.'; end if;
  ic := btrim(coalesce(p_icon, ''));
  if length(ic) > 8 then raise exception 'Ese emblema no está disponible.'; end if;
  if ic <> '' and not (ic = any(_wow_emblems())) then
    raise exception 'Ese emblema no está disponible.'; end if;
  update wow_alliances set emblem = ic where id = a.id;
  return jsonb_build_object('ok', true, 'emblem', ic);
end $$;
grant execute on function public.wow_alliance_emblem(text, text) to anon, authenticated;

-- ---- ficha de nodos: + emblema del clan que lo tiene ----
create or replace function public._wow_fort_info(p_uid text, p_kind text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare t wow_thrones; arr jsonb := '[]'::jsonb; g numeric; tr jsonb; fac text; hist jsonb;
        ua text; lab text;
begin
  ua := _wow_ally_of(p_uid);
  for t in select * from wow_thrones where kind = p_kind order by node loop
    select coalesce(sum((value)::numeric),0) into g from jsonb_each_text(t.garrison);
    select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into tr
      from wow_throne_treasure where node = t.node and qty > 0;
    select coalesce(jsonb_agg(jsonb_build_object(
        'kind', h.kind, 'who', h.actor_name, 'who_id', h.actor,
        'detail', h.detail, 'created', h.created) order by h.id desc), '[]'::jsonb)
      into hist from (select * from wow_throne_history where node = t.node order by id desc limit 8) h;
    fac := null;
    if t.holder is not null then select faction into fac from wow_users where id = t.holder; end if;
    lab := null;
    if t.holder_ally is not null then lab := _wow_ally_label(t.holder_ally); end if;
    arr := arr || jsonb_build_object(
      'node', t.node, 'name', t.name, 'kind', t.kind,
      'holder', t.holder, 'holder_name', t.holder_name,
      'holder_ally', t.holder_ally, 'ally', lab, 'ally_icon', _wow_ally_icon(t.holder_ally),
      'faction', fac, 'garrison', coalesce(g,0), 'gdetail', t.garrison, 'since', t.since_ms,
      'mine', _wow_node_mine(t.holder, t.holder_ally, p_uid, ua), 'treasure', tr, 'history', hist);
  end loop;
  return arr;
end $$;
revoke all on function public._wow_fort_info(text, text) from public, anon, authenticated;

-- ---- info de la alianza: + emblema actual y emblemas disponibles ----
create or replace function public.wow_alliance_info(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a wow_alliances; mem jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select * into a from wow_alliances where id = p_id;
  if a.id is null then raise exception 'Esa alianza ya no existe.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', w.id, 'name', w.name, 'faction', w.faction, 'points', _wow_points(w.id),
             'leader', w.id = a.leader, 'me', w.id = u.id)
           order by (w.id = a.leader) desc, w.created), '[]') into mem
    from wow_users w where w.alliance = a.id;
  return jsonb_build_object('id', a.id, 'name', a.name, 'tag', a.tag, 'descr', a.descr,
    'emblem', a.emblem, 'emblems', _wow_emblems(),
    'leader', (select name from wow_users where id = a.leader),
    'members', mem, 'is_member', u.alliance = a.id,
    'is_leader', (u.id = a.leader));
end $$;
grant execute on function public.wow_alliance_info(text, text) to anon, authenticated;
