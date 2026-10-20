-- ================================================================
-- APENDICE ALDEAS: POBLADOS NEUTRALES CONQUISTABLES
--   - Ocho aldeas: nodos 42..45 (continente alto) y 46..49 (bajo).
--   - Empiezan LIBRES: el primero que llega con tropas las ocupa;
--     otros reinos atacan la guarnicion para quitarlas.
--   - El duenio recibe produccion (100/h, configurable) acumulada en
--     un tesoro que reclama cuando quiere, y un % del valor del trato
--     del mercado (tributo, 1% por defecto y configurable por admin).
--   - Reutiliza el motor de tronos (misma tabla wow_thrones con `kind`,
--     mismo tesoro/historial y mismas funciones wow_throne_*).
-- ================================================================

-- tipo de estructura por nodo: 'trono' (def.) o 'aldea'
alter table public.wow_thrones add column if not exists kind text not null default 'trono';

insert into public.wow_thrones(node, name, kind) values
  (42, 'Aldea del Alba',       'aldea'),
  (43, 'Aldea del Bosque',     'aldea'),
  (44, 'Aldea de la Colina',   'aldea'),
  (45, 'Aldea del Río',        'aldea'),
  (46, 'Aldea de la Costa',    'aldea'),
  (47, 'Aldea del Valle',      'aldea'),
  (48, 'Aldea del Desierto',   'aldea'),
  (49, 'Aldea de la Niebla',   'aldea')
  on conflict (node) do nothing;
-- por si quedaran filas de aldeas fuera de rango
update public.wow_thrones set kind = 'aldea' where node in (42,43,44,45,46,47,48,49);

insert into public.wow_settings(key, val) values ('aldea_share', '1')
  on conflict (key) do nothing;
insert into public.wow_settings(key, val) values
  ('aldea_gold_h', '100'), ('aldea_wood_h', '100'), ('aldea_ore_h', '100')
  on conflict (key) do nothing;

-- ---- helpers internos por tipo de nodo ----
create or replace function public._wow_aldea_pct()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = 'aldea_share'), 1)
$$;
revoke all on function public._wow_aldea_pct() from public, anon, authenticated;

create or replace function public._wow_node_kind(p_node integer)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select kind from wow_thrones where node = p_node), 'trono')
$$;
revoke all on function public._wow_node_kind(integer) from public, anon, authenticated;

create or replace function public._wow_node_pct(p_node integer)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select case _wow_node_kind(p_node) when 'aldea' then _wow_aldea_pct() else _wow_throne_pct() end
$$;
revoke all on function public._wow_node_pct(integer) from public, anon, authenticated;

create or replace function public._wow_node_rate(p_node integer, p_res text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select _wow_throne_rate(case _wow_node_kind(p_node)
    when 'aldea' then 'aldea_' || p_res || '_h'
    else 'throne_' || p_res || '_h' end)
$$;
revoke all on function public._wow_node_rate(integer, text) from public, anon, authenticated;

-- ---- produccion por hora segun el tipo de nodo (reemplaza la de tronos) ----
create or replace function public._wow_throne_accrue()
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  ms bigint; t record; hrs numeric; rg numeric; rw numeric; ro numeric;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  for t in select * from wow_thrones where holder is not null for update loop
    if coalesce(t.accrue_ms,0) <= 0 then
      update wow_thrones set accrue_ms = ms where node = t.node;
      continue;
    end if;
    hrs := (ms - t.accrue_ms)::numeric / 3600000.0;
    if hrs <= 0 then continue; end if;
    rg := _wow_node_rate(t.node, 'gold');
    rw := _wow_node_rate(t.node, 'wood');
    ro := _wow_node_rate(t.node, 'ore');
    if rg > 0 then perform _wow_throne_add(t.node, 'gold', round(rg * hrs, 2)); end if;
    if rw > 0 then perform _wow_throne_add(t.node, 'wood', round(rw * hrs, 2)); end if;
    if ro > 0 then perform _wow_throne_add(t.node, 'ore', round(ro * hrs, 2)); end if;
    update wow_thrones set accrue_ms = ms where node = t.node;
  end loop;
end $$;
revoke all on function public._wow_throne_accrue() from public, anon, authenticated;

-- ---- info de nodos (reutilizable trono/aldea) ----
create or replace function public._wow_fort_info(p_uid text, p_kind text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare t wow_thrones; arr jsonb := '[]'::jsonb; g numeric; tr jsonb; fac text; hist jsonb;
begin
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
    arr := arr || jsonb_build_object(
      'node', t.node, 'name', t.name, 'kind', t.kind,
      'holder', t.holder, 'holder_name', t.holder_name,
      'faction', fac, 'garrison', coalesce(g,0), 'gdetail', t.garrison, 'since', t.since_ms,
      'mine', (t.holder = p_uid), 'treasure', tr, 'history', hist);
  end loop;
  return arr;
end $$;
revoke all on function public._wow_fort_info(text, text) from public, anon, authenticated;

create or replace function public.wow_throne_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  perform _wow_throne_accrue();
  return jsonb_build_object('ok', true, 'share', _wow_throne_pct(),
    'thrones', _wow_fort_info(u.id, 'trono'),
    'rates', jsonb_build_object('gold', _wow_throne_rate('throne_gold_h'),
                                'wood', _wow_throne_rate('throne_wood_h'),
                                'ore',  _wow_throne_rate('throne_ore_h')));
end $$;
grant execute on function public.wow_throne_info(text) to anon, authenticated;

create or replace function public.wow_aldea_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  perform _wow_throne_accrue();
  return jsonb_build_object('ok', true, 'share', _wow_aldea_pct(),
    'aldeas', _wow_fort_info(u.id, 'aldea'),
    'rates', jsonb_build_object('gold', _wow_throne_rate('aldea_gold_h'),
                                'wood', _wow_throne_rate('aldea_wood_h'),
                                'ore',  _wow_throne_rate('aldea_ore_h')));
end $$;
grant execute on function public.wow_aldea_info(text) to anon, authenticated;

-- ---- ajuste admin del tributo de aldeas ----
create or replace function public.wow_admin_setaldeashare(p_token text, p_pct numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  if p_pct is null or p_pct < 0.01 or p_pct > 20 then raise exception 'El tributo de aldeas debe estar entre 0,01 y 20.'; end if;
  insert into wow_settings(key, val) values ('aldea_share', trim_scale(round(p_pct, 2))::text)
    on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'share', trim_scale(round(p_pct, 2)));
end $$;
grant execute on function public.wow_admin_setaldeashare(text, numeric) to anon, authenticated;

-- ---- ajuste admin de la produccion de recursos de las aldeas (por hora) ----
create or replace function public.wow_admin_setaldeas(p_token text, p_gold numeric, p_wood numeric, p_ore numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  if p_gold is null or p_wood is null or p_ore is null
     or p_gold < 0 or p_wood < 0 or p_ore < 0
     or p_gold > 100000 or p_wood > 100000 or p_ore > 100000 then
    raise exception 'La producción debe estar entre 0 y 100000 por hora.';
  end if;
  insert into wow_settings(key, val) values ('aldea_gold_h', p_gold::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key, val) values ('aldea_wood_h', p_wood::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key, val) values ('aldea_ore_h',  p_ore::text)  on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'rates', jsonb_build_object('gold', p_gold, 'wood', p_wood, 'ore', p_ore));
end $$;
grant execute on function public.wow_admin_setaldeas(text, numeric, numeric, numeric) to anon, authenticated;

-- ================================================================
-- Mercado: el tributo va al tesoro de CADA estructura con duenio,
-- con su % segun el tipo (trono -> throne_share, aldea -> aldea_share).
-- (Reemplaza wow_market_take del apendice de tronos.)
-- ================================================================
create or replace function public.wow_market_take(p_token text, p_id bigint, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; o wow_market_offers; ms bigint;
  take numeric; want_part numeric; fee numeric; net numeric; new_left numeric;
  share numeric; tt record;
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
  -- tributo: % del valor del trato segun el tipo de cada estructura con duenio
  share := 0;
  for tt in select node from wow_thrones where holder is not null order by node loop
    share := want_part * least(_wow_node_pct(tt.node), fee) / 100.0;
    if _wow_mkt_is_troop(o.want_key) then share := round(share); end if;
    if share > 0 then perform _wow_throne_add(tt.node, o.want_key, share); end if;
  end loop;
  -- actualizar la oferta
  new_left := o.give_left - take;
  if new_left <= 0.0001 then
    update wow_market_offers set give_left = 0, want_left = 0, active = false where id = o.id;
  else
    update wow_market_offers set give_left = new_left, want_left = greatest(0, o.want_left - want_part) where id = o.id;
  end if;
  return jsonb_build_object('ok', true, 'took', take, 'paid', want_part, 'fee', fee, 'net', net, 'throne_share', share);
end $$;
grant execute on function public.wow_market_take(text, bigint, numeric) to anon, authenticated;

-- ================================================================
-- Ranking: agrega tronos y aldeas que controla cada reino.
-- ================================================================
create or replace function public.wow_leaderboard(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'name', s.name, 'faction', s.faction, 'me', s.me, 'created', s.created,
      'alliance', s.atag,
      'points', s.lsum * 100 + s.tsum, 'level_sum', s.lsum, 'troops', s.tsum,
      'thrones', s.thrones, 'aldeas', s.aldeas)
    order by s.thrones desc, s.aldeas desc, (s.lsum * 100 + s.tsum) desc, s.created), '[]'::jsonb)
    into out
    from (
      select w.id, w.name, w.faction, w.created, (w.id = u.id) me, coalesce(al.tag,'') atag,
        coalesce((select sum(b.level) from wow_buildings b where b.owner_id = w.id),0) lsum,
        coalesce((select sum(t.qty) from wow_troops t where t.owner_id = w.id),0) tsum,
        (select count(*) from wow_thrones th where th.holder = w.id and th.kind = 'trono') thrones,
        (select count(*) from wow_thrones th where th.holder = w.id and th.kind = 'aldea') aldeas
      from wow_users w left join wow_alliances al on al.id = w.alliance
      where w.active and not coalesce(w.is_admin,false)
    ) s;
  return out;
end $$;
grant execute on function public.wow_leaderboard(text) to anon, authenticated;
