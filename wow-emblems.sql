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

-- ================================================================
-- EL EMBLEMA REPRESENTA A LA ALIANZA: sale junto a su [TAG] en la
-- barra de arriba, el ranking, la lista de alianzas, la diplomacia
-- (guerras y pactos) y el chat global.
-- ================================================================

-- ---- estado del reino: + emblema de mi alianza (barra de arriba) ----
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
    'buildings', blds, 'troops', trs, 'queue', que->0, 'queues', que, 'points', pts, 'now', ms,
    'alliance', u.alliance,
    'ally_tag', coalesce((select tag from wow_alliances where id = u.alliance), ''),
    'ally_emblem', _wow_ally_icon(u.alliance),
    'online', _wow_online_count());
end $$;
grant execute on function public.wow_state(text) to anon, authenticated;

-- ---- lista de alianzas: + emblema ----
create or replace function public.wow_alliance_list(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', a.id, 'name', a.name, 'tag', a.tag, 'descr', a.descr, 'emblem', a.emblem,
             'members', (select count(*) from wow_users w where w.alliance = a.id),
             'points', (select coalesce(sum(_wow_points(w.id)),0) from wow_users w where w.alliance = a.id),
             'mine', a.id = u.alliance)
           order by (select coalesce(sum(_wow_points(w.id)),0) from wow_users w where w.alliance = a.id) desc, a.created), '[]') into out
    from wow_alliances a;
  return out;
end $$;
grant execute on function public.wow_alliance_list(text) to anon, authenticated;

-- ---- ranking de alianzas: + emblema ----
create or replace function public.wow_alliance_rank(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', x.id, 'name', x.name, 'tag', x.tag, 'emblem', x.emblem,
             'members', x.members, 'points', x.points,
             'troops', x.troops, 'thrones', x.thrones,
             'wins', x.wins, 'losses', x.losses,
             'mine', x.id = u.alliance) order by x.points desc, x.wins desc, x.created), '[]') into out
    from (
      select a.id, a.name, a.tag, a.emblem, a.created,
             a.war_wins as wins, a.war_losses as losses,
             (select count(*) from wow_users w where w.alliance = a.id) as members,
             (select coalesce(sum(_wow_points(w.id)),0) from wow_users w where w.alliance = a.id) as points,
             (select coalesce(sum(t.qty),0) from wow_troops t
                join wow_users w on w.id = t.owner_id where w.alliance = a.id) as troops,
             (select count(*) from wow_thrones th
                join wow_users w on w.id = th.holder where w.alliance = a.id) as thrones
        from wow_alliances a
    ) x;
  return out;
end $$;
grant execute on function public.wow_alliance_rank(text) to anon, authenticated;

-- ---- guerras: + emblema de cada bando ----
create or replace function public.wow_ally_wars(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_war_tick();
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', w.id, 'a', w.a, 'b', w.b,
             'a_tag', w.a_tag, 'b_tag', w.b_tag,
             'a_name', w.a_name, 'b_name', w.b_name,
             'a_icon', _wow_ally_icon(w.a), 'b_icon', _wow_ally_icon(w.b),
             'a_score', w.a_score, 'b_score', w.b_score,
             'ends', w.ends, 'started', w.started,
             'mine', (u.alliance in (w.a, w.b)),
             'i_am_a', (u.alliance = w.a))
           order by w.started desc), '[]') into out
    from wow_ally_wars w where w.active;
  return jsonb_build_object('wars', out, 'mine', u.alliance);
end $$;
grant execute on function public.wow_ally_wars(text) to anon, authenticated;

-- ---- diplomacia (pactos y ofertas): + emblema del rival ----
create or replace function public.wow_ally_diplo(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; pacts jsonb; oin jsonb; oout jsonb; vlead boolean;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_war_tick();
  if u.alliance is null then
    return jsonb_build_object('pacts', '[]'::jsonb, 'offers_in', '[]'::jsonb, 'offers_out', '[]'::jsonb,
      'is_leader', false, 'mine', null);
  end if;
  vlead := exists(select 1 from wow_alliances a where a.id = u.alliance and a.leader = u.id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'a', p.a, 'b', p.b, 'a_tag', p.a_tag, 'b_tag', p.b_tag,
           'a_name', p.a_name, 'b_name', p.b_name, 'hours', p.hours,
           'a_icon', _wow_ally_icon(p.a), 'b_icon', _wow_ally_icon(p.b),
           'started', p.started, 'ends', p.ends, 'offer_ends', p.offer_ends,
           'offered_by', p.offered_by, 'i_am_a', (u.alliance = p.a)) order by p.id desc), '[]') into pacts
    from wow_ally_pacts p
   where p.state = 'activo' and u.alliance in (p.a, p.b);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'a', p.a, 'b', p.b, 'a_tag', p.a_tag, 'b_tag', p.b_tag,
           'a_name', p.a_name, 'b_name', p.b_name, 'hours', p.hours,
           'a_icon', _wow_ally_icon(p.a), 'b_icon', _wow_ally_icon(p.b),
           'started', p.started, 'ends', p.ends, 'offer_ends', p.offer_ends,
           'offered_by', p.offered_by, 'i_am_a', (u.alliance = p.a)) order by p.id desc), '[]') into oin
    from wow_ally_pacts p
   where p.state = 'oferta' and p.offered_by <> u.alliance and u.alliance in (p.a, p.b);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'a', p.a, 'b', p.b, 'a_tag', p.a_tag, 'b_tag', p.b_tag,
           'a_name', p.a_name, 'b_name', p.b_name, 'hours', p.hours,
           'a_icon', _wow_ally_icon(p.a), 'b_icon', _wow_ally_icon(p.b),
           'started', p.started, 'ends', p.ends, 'offer_ends', p.offer_ends,
           'offered_by', p.offered_by, 'i_am_a', (u.alliance = p.a)) order by p.id desc), '[]') into oout
    from wow_ally_pacts p
   where p.state = 'oferta' and p.offered_by = u.alliance;
  return jsonb_build_object('pacts', pacts, 'offers_in', oin, 'offers_out', oout,
    'is_leader', vlead, 'mine', u.alliance);
end $$;
grant execute on function public.wow_ally_diplo(text) to anon, authenticated;

-- ---- chat global: + emblema de la alianza del que escribe ----
create or replace function public.wow_gchat(p_token text, p_since bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id, 'name', c.name, 'faction', c.faction, 'tag', c.ally_tag,
             'emblem', coalesce((select al.emblem from wow_alliances al where al.tag = c.ally_tag), ''),
             'msg', c.msg, 'created', c.created, 'me', c.user_id = u.id) order by c.id), '[]') into out
    from (select * from wow_gchat
           where (coalesce(p_since,0) = 0 or created > coalesce(p_since,0))
           order by id desc limit 60) c;
  return out;
end $$;
grant execute on function public.wow_gchat(text, bigint) to anon, authenticated;

