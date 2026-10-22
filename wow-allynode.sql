-- ================================================================
-- APENDICE ALIANZAS PROPIETARIAS: tronos y aldeas en nombre de la
-- alianza + arcon comun y reparto por porcentajes que decide el lider.
--   - Al conquistar un nodo estando en alianza, pasa a ser DE LA
--     ALIANZA (se guarda holder_ally) y el nombre que se muestra es
--     el de la alianza ([TAG] Nombre).
--   - Cualquier miembro puede reforzar, retirar y reclamar el tesoro
--     de un nodo de su alianza; el tesoro va al ARCON comun.
--   - El lider reparte el arcon por porcentajes (o paga sueltos).
--   - No se puede atacar un nodo de tu propia alianza.
--   - Los reinos automaticos de la alianza refuerzan sus nodos y
--     atacan los de la alianza enemiga en guerra.
-- ================================================================

-- ----------------------------------------------------------------
-- 1) La propiedad puede ser de una alianza
-- ----------------------------------------------------------------
alter table public.wow_thrones add column if not exists holder_ally text;
create index if not exists wow_thrones_holder_ally_idx on public.wow_thrones(holder_ally);

-- los nodos ya ocupados por un miembro de alianza pasan a ser de la alianza
update public.wow_thrones t set holder_ally = w.alliance
  from public.wow_users w
 where t.holder = w.id and t.holder is not null
   and w.alliance is not null and t.holder_ally is null;

-- ----------------------------------------------------------------
-- 2) Arcon de la alianza y porcentajes de reparto
-- ----------------------------------------------------------------
create table if not exists public.wow_alliance_vault(
  alliance_id text not null references public.wow_alliances(id) on delete cascade,
  key text not null,
  qty numeric(16,2) not null default 0,
  primary key (alliance_id, key)
);
create table if not exists public.wow_alliance_share(
  alliance_id text not null references public.wow_alliances(id) on delete cascade,
  user_id text not null,
  pct numeric(5,2) not null default 0,
  primary key (alliance_id, user_id)
);
alter table public.wow_alliance_vault enable row level security;
alter table public.wow_alliance_share enable row level security;
revoke all on public.wow_alliance_vault from public, anon, authenticated;
revoke all on public.wow_alliance_share from public, anon, authenticated;

-- ---- helpers internos ----
create or replace function public._wow_node_mine(p_holder text, p_ally text, p_uid text, p_ually text)
returns boolean language sql immutable as $$
  select coalesce(p_holder = p_uid, false)
      or coalesce(p_ally = p_ually and p_ally is not null, false)
$$;
revoke all on function public._wow_node_mine(text, text, text, text) from public, anon, authenticated;

create or replace function public._wow_ally_label(p_ally text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select '[' || al.tag || '] ' || al.name from wow_alliances al where al.id = p_ally), '')
$$;
revoke all on function public._wow_ally_label(text) from public, anon, authenticated;

create or replace function public._wow_vault_add(p_ally text, p_key text, p_qty numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if p_ally is null or coalesce(p_qty,0) <= 0 then return; end if;
  insert into wow_alliance_vault(alliance_id, key, qty) values (p_ally, p_key, p_qty)
    on conflict (alliance_id, key) do update set qty = wow_alliance_vault.qty + excluded.qty;
end $$;
revoke all on function public._wow_vault_add(text, text, numeric) from public, anon, authenticated;

create or replace function public._wow_ally_of(p_uid text)
returns text language sql stable security definer set search_path to 'public' as $$
  select alliance from wow_users where id = p_uid
$$;
revoke all on function public._wow_ally_of(text) from public, anon, authenticated;

create or replace function public._wow_ally_leader(p_ally text)
returns text language sql stable security definer set search_path to 'public' as $$
  select leader from wow_alliances where id = p_ally
$$;
revoke all on function public._wow_ally_leader(text) from public, anon, authenticated;

create or replace function public._wow_res_name(p_key text)
returns text language sql immutable as $$
  select case p_key
    when 'gold' then 'oro' when 'wood' then 'madera' when 'ore' then 'mineral' when 'cup' then 'CUP'
    when 'soldado' then 'soldados' when 'arquero' then 'arqueros' when 'jinete' then 'jinetes'
    when 'mago' then 'magos' when 'paladin' then 'paladines' when 'dragon' then 'dragones'
    else p_key end
$$;
revoke all on function public._wow_res_name(text) from public, anon, authenticated;

create or replace function public._wow_res_str(p_json jsonb)
returns text language sql immutable as $$
  select coalesce(string_agg(t.txt, ', ' order by t.k), '')
    from (select key k, trim(to_char((value)::numeric, 'FM999999990.##')) || ' ' || _wow_res_name(key) txt
            from jsonb_each_text(coalesce(p_json, '{}'::jsonb))) t
$$;
revoke all on function public._wow_res_str(jsonb) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- 2b) Proteccion de novatos en tronos y aldeas.
--     La parte protegida de un lugar es su dueño y, si el lugar no
--     tiene dueño, el principal contribuyente de su guarnición.
-- ----------------------------------------------------------------
create or replace function public._wow_node_protect(p_node integer)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$

declare t wow_thrones; uid text; pts numeric; nm text;
begin
  select * into t from wow_thrones where node = p_node;
  if t.node is null then
    return jsonb_build_object('kind','none','points',null,'user_id',null,'name',null);
  end if;
  if t.holder is not null and t.holder <> '' then
    pts := _wow_points(t.holder);
    select coalesce(w.name, t.holder_name) into nm from wow_users w where w.id = t.holder;
    return jsonb_build_object('kind','holder','points',pts,'user_id',t.holder,'name',nm);
  end if;
  select c.user_id into uid from wow_node_contrib c
    where c.node = p_node
      and coalesce((select sum((x.value)::int) from jsonb_each_text(c.troops) x),0) > 0
    order by (select coalesce(sum((x.value)::int),0) from jsonb_each_text(c.troops) x) desc
    limit 1;
  if uid is null then
    return jsonb_build_object('kind','none','points',null,'user_id',null,'name',null);
  end if;
  pts := _wow_points(uid);
  select w.name into nm from wow_users w where w.id = uid;
  return jsonb_build_object('kind','garrison','points',pts,'user_id',uid,'name',nm);
end $$;
revoke all on function public._wow_node_protect(integer) from public, anon, authenticated;

-- Un objetivo (reino o lugar) se puede atacar con estos puntos:
-- el atacante llega al umbral de reinos, la parte protegida tambien y la
-- diferencia no llega al umbral que corresponda al tipo de objetivo.
drop function if exists public._wow_target_attack_ok(text, text, integer, numeric, numeric);
create or replace function public._wow_target_attack_ok(p_kind text, p_ref text, p_node integer, p_pts numeric)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$

declare tpts numeric; prot numeric; tprot numeric;
begin
  prot := _wow_protect_reino();
  if prot > 0 and p_pts is not null and p_pts < prot then return false; end if;
  if p_kind = 'reino' then
    tprot := prot;
    select _wow_points(p_ref) into tpts;
    if tpts is null then return false; end if;
  else
    tprot := case when p_kind = 'aldea' then _wow_protect_aldea() else _wow_protect_trono() end;
    select (_wow_node_protect(p_node)->>'points')::numeric into tpts;
    if tpts is null then return true; end if;
  end if;
  if tprot is null or tprot <= 0 then return true; end if;
  if tpts < tprot then return false; end if;
  if p_pts is not null and (p_pts - tpts) >= tprot then return false; end if;
  return true;
end $$;
revoke all on function public._wow_target_attack_ok(text, text, integer, numeric) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- 3) Info de nodos: dueño visible + "es mio / de mi alianza"
-- ----------------------------------------------------------------
create or replace function public._wow_fort_info(p_uid text, p_kind text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare t wow_thrones; arr jsonb := '[]'::jsonb; g numeric; tr jsonb; fac text; hist jsonb;
        ua text; lab text; hp numeric; pk text; pn text; pr jsonb;
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
    if t.holder is not null and t.holder <> '' then
      hp := _wow_points(t.holder);
      pk := 'holder';
      pn := t.holder_name;
    else
      pr := _wow_node_protect(t.node);
      hp := (pr->>'points')::numeric;
      pk := pr->>'kind';
      pn := pr->>'name';
    end if;
    arr := arr || jsonb_build_object(
      'node', t.node, 'name', t.name, 'kind', t.kind,
      'holder', t.holder, 'holder_name', t.holder_name,
      'holder_ally', t.holder_ally, 'ally', lab,
      'faction', fac, 'garrison', coalesce(g,0), 'gdetail', t.garrison, 'since', t.since_ms,
      'mine', _wow_node_mine(t.holder, t.holder_ally, p_uid, ua), 'treasure', tr, 'history', hist,
      'holder_points', hp, 'prot_kind', pk, 'prot_name', pn);
  end loop;
  return arr;
end $$;
revoke all on function public._wow_fort_info(text, text) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- 4) Llegada de tropas a un nodo (copia de _wow_throne_land con
--    propiedad de alianza y tesoro al arcon)
-- ----------------------------------------------------------------
create or replace function public._wow_throne_land(p_fleet_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  f wow_fleets; u wow_users; t wow_thrones; ms bigint; z record; r record;
  sim jsonb; surv jsonb; msg jsonb; prev text; ret integer; ually text; lab text;
  a_forge int; a_fort int; d_forge int; d_fort int; d_wall int;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  select * into f from wow_fleets where id = p_fleet_id;
  if f.id is null then return; end if;
  select * into u from wow_users where id = f.attacker;
  if u.id is null then delete from wow_fleets where id = f.id; return; end if;
  select * into t from wow_thrones where node = f.node for update;

  -- ---- reclamar tesoro ----
  if f.kind = 'throne_claim' then
    msg := '{}'::jsonb;
    if t.node is not null and _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
      perform _wow_throne_accrue();
      for r in select key, qty from wow_throne_treasure where node = t.node and qty > 0 for update loop
        msg := msg || jsonb_build_object(r.key, r.qty);
        if t.holder_ally is not null then perform _wow_vault_add(t.holder_ally, r.key, r.qty); end if;
      end loop;
      delete from wow_throne_treasure where node = t.node;
      if msg <> '{}'::jsonb then perform _wow_throne_log(t.node, 'claim', u.id, u.name, msg); end if;
      -- si el nodo es de una alianza, el tesoro se queda en el arcon comun
      if t.holder_ally is not null then
        lab := _wow_ally_label(t.holder_ally);
        perform _wow_event('alliance', '🏛️ ' || u.name || ' ha llevado el tesoro de ' || t.name ||
          ' al arcón de ' || coalesce(nullif(lab,''), 'su alianza') || '.');
        insert into wow_reports(owner, kind, data, created)
          values (u.id, 'out', jsonb_build_object('dir','vault','who',coalesce(t.name,''),'win',true,
            'loot',msg,'ally',lab,'created',ms), ms);
        delete from wow_fleets where id = f.id;
        return;
      end if;
    end if;
    ret := _wow_travel_node(u.pos, coalesce(f.node, _wow_pos_node(u.pos)));
    update wow_fleets set state = 'returning', loot = msg, arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
    return;
  end if;

  -- ---- refuerzo: suma a la guarnicion; si ya no es tuyo, vuelve a casa ----
  if f.kind = 'throne_rein' then
    if t.node is not null and _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
      surv := t.garrison;
      for z in select key, value::int from jsonb_each_text(f.troops) loop
        surv := jsonb_set(surv, array[z.key], to_jsonb(coalesce((surv->>z.key)::int,0) + z.value), true);
      end loop;
      update wow_thrones set garrison = surv where node = t.node;
      perform _wow_throne_log(t.node, 'reinforce', u.id, u.name, jsonb_build_object('troops', f.troops));
      perform _wow_event('throne', '🛡️ ' || u.name || ' ha reforzado ' || t.name || '.');
      insert into wow_reports(owner, kind, data, created)
        values (u.id, 'out', jsonb_build_object('dir','throne_rein','who',coalesce(t.name,''),'win',true,'created',ms), ms);
    else
      ret := _wow_travel_node(u.pos, coalesce(f.node, _wow_pos_node(u.pos)));
      update wow_fleets set state = 'returning', arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
      insert into wow_reports(owner, kind, data, created)
        values (u.id, 'out', jsonb_build_object('dir','throne_rein','who',coalesce(t.name,''),'win',false,
          'note','Ya no controlabas ese lugar: tus tropas vuelven a casa.','created',ms), ms);
      return;
    end if;
    delete from wow_fleets where id = f.id;
    return;
  end if;

  -- ---- asalto: si el objetivo desaparecio, las tropas vuelven ----
  if t.node is null then
    ret := _wow_travel_node(u.pos, _wow_pos_node(u.pos));
    update wow_fleets set state = 'returning', arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who','','win',false,
        'note','El objetivo ya no existe: tus tropas vuelven a casa.','created',ms), ms);
    return;
  end if;

  -- ---- libre o guarnicion vacia: se ocupa sin lucha ----
  if coalesce(t.holder,'') = '' or t.garrison = '{}'::jsonb then
    ually := u.alliance;
    update wow_thrones set holder = u.id, holder_name = u.name, holder_ally = ually,
      since_ms = ms, garrison = f.troops, accrue_ms = ms where node = t.node;
    perform _wow_throne_log(t.node, 'take', u.id, u.name, jsonb_build_object('garrison', f.troops));
    lab := _wow_ally_label(ually);
    perform _wow_event('throne', (case when t.kind = 'aldea' then '🛖 ' else '🏯 ' end) || u.name || ' ha ocupado ' || t.name ||
      (case when ually is not null then ' en nombre de ' || coalesce(nullif(lab,''),'su alianza') else '' end) || '.');
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',true,'battle',null,
        'ally', lab, 'created',ms), ms);
    delete from wow_fleets where id = f.id;
    return;
  end if;

  -- ---- batalla contra la guarnicion (muros/herreria/fortaleza del duenio) ----
  prev := t.holder_name;
  a_forge := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'herreria'), 0);
  a_fort  := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'fortaleza'), 0);
  d_forge := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'herreria'), 0);
  d_fort  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'fortaleza'), 0);
  d_wall  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'muralla'), 0);
  sim := _wow_sim(f.troops, t.garrison, d_wall, (ms/1000) + t.node*131,
                  1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort);
  if (sim->>'winner') = 'attacker' then
    ually := u.alliance;
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'a_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    update wow_thrones set holder = u.id, holder_name = u.name, holder_ally = ually,
      since_ms = ms, garrison = surv, accrue_ms = ms where node = t.node;
    perform _wow_throne_log(t.node, 'conquest', u.id, u.name, jsonb_build_object('from', prev));
    lab := _wow_ally_label(ually);
    perform _wow_event('throne', (case when t.kind = 'aldea' then '🏘️ ' else '👑 ' end) || u.name || ' ha conquistado ' || t.name ||
      ' (antes de ' || coalesce(prev, 'nadie') || ')' ||
      (case when ually is not null then ', en nombre de ' || coalesce(nullif(lab,''),'su alianza') else '' end) || '.');
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',true,'from',u.name,'battle',sim,'ally',lab,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',true,'from',u.name,'battle',sim,'created',ms), ms);
  else
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'d_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    update wow_thrones set garrison = surv where node = t.node;
    perform _wow_throne_log(t.node, 'defended', u.id, u.name, jsonb_build_object('holder', prev));
    perform _wow_event('throne', '🛡️ La guarnición de ' || t.name || ' ha rechazado el ataque de ' || u.name || '.');
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms);
  end if;
  delete from wow_fleets where id = f.id;
end $$;
revoke all on function public._wow_throne_land(bigint) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- 5) Atacar / reforzar / retirar / reclamar con propiedad de alianza
-- ----------------------------------------------------------------
create or replace function public.wow_throne_attack(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; z record; travel integer;
        protect numeric; tpts numeric; pr jsonb; plprot numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian ni conquistan.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if t.holder_ally is not null and t.holder_ally = u.alliance then
    raise exception 'Ese lugar ya es de tu alianza.'; end if;
  protect := _wow_protect_reino();
  plprot := case when t.kind = 'aldea' then _wow_protect_aldea() else _wow_protect_trono() end;
  if protect > 0 then
    if not u.is_admin and _wow_points(u.id) < protect then
      raise exception 'Estás en protección de novatos: no puedes atacar hasta superar % puntos.', trunc(protect)::int; end if;
  end if;
  if plprot > 0 then
    pr := _wow_node_protect(t.node);
    if (pr->>'points') is not null then
      tpts := (pr->>'points')::numeric;
      if tpts < plprot then
        raise exception 'Ese lugar está protegido por ser de un novato (menos de % puntos).', trunc(plprot)::int; end if;
      if not u.is_admin and (_wow_points(u.id) - tpts) >= plprot then
        raise exception 'No puedes atacar a un lugar cuyo dueño es mucho más débil: la diferencia de puntos no puede llegar a %.', trunc(plprot)::int; end if;
    end if;
  end if;
  if exists(select 1 from wow_fleets where attacker = u.id and node = p_node and state = 'outbound') then
    raise exception 'Ya tienes un ejército en camino a %.', t.name; end if;
  for z in select key, value::int from jsonb_each_text(army) loop
    perform _wow_mkt_sub(u.id, z.key, z.value);
  end loop;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'outbound', 'throne_atk', ms, ms + travel*1000, ms);
  perform _wow_event('throne', '⚔️ ' || u.name || ' ha enviado un ejército contra ' || t.name || '.');
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name);
end $$;
grant execute on function public.wow_throne_attack(text, integer, jsonb) to anon, authenticated;

create or replace function public.wow_throne_reinforce(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; z record; travel integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if not _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
    raise exception 'No controlas ese lugar.'; end if;
  if exists(select 1 from wow_fleets where attacker = u.id and node = p_node and state = 'outbound') then
    raise exception 'Ya tienes un ejército en camino a %.', t.name; end if;
  for z in select key, value::int from jsonb_each_text(army) loop
    perform _wow_mkt_sub(u.id, z.key, z.value);
  end loop;
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'outbound', 'throne_rein', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name);
end $$;
grant execute on function public.wow_throne_reinforce(text, integer, jsonb) to anon, authenticated;

create or replace function public.wow_throne_withdraw(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; newg jsonb; z record; left_g int; travel integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if not _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
    raise exception 'No controlas ese lugar.'; end if;
  for z in select key, value::int from jsonb_each_text(army) loop
    if coalesce((t.garrison->>z.key)::int, 0) < z.value then
      raise exception 'No tienes tantas tropas de ese tipo en la guarnición.'; end if;
  end loop;
  newg := t.garrison;
  for z in select key, value::int from jsonb_each_text(army) loop
    left_g := coalesce((newg->>z.key)::int, 0) - z.value;
    if left_g > 0 then
      newg := jsonb_set(newg, array[z.key], to_jsonb(left_g), true);
    else
      newg := newg - z.key;
    end if;
  end loop;
  update wow_thrones set garrison = newg where node = t.node;
  perform _wow_throne_log(t.node, 'withdraw', u.id, u.name, jsonb_build_object('troops', army));
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'returning', 'throne_with', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000,
                            'empty', (newg = '{}'::jsonb), 'target', t.name);
end $$;
grant execute on function public.wow_throne_withdraw(text, integer, jsonb) to anon, authenticated;

create or replace function public.wow_throne_claim(p_token text, p_node integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; travel integer; have numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if not _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
    raise exception 'No controlas ese lugar.'; end if;
  if exists(select 1 from wow_fleets where attacker = u.id and node = p_node and kind = 'throne_claim' and state = 'outbound') then
    raise exception 'Ya tienes una partida en camino a reclamar el tesoro de %.', t.name; end if;
  perform _wow_throne_accrue();
  select coalesce(sum(qty),0) into have from wow_throne_treasure where node = p_node;
  if have <= 0 then raise exception 'No hay tesoro que reclamar todavía.'; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, '{}'::jsonb, '{}'::jsonb, 'outbound', 'throne_claim', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name,
    'ally', _wow_ally_label(t.holder_ally));
end $$;
grant execute on function public.wow_throne_claim(text, integer) to anon, authenticated;

-- ----------------------------------------------------------------
-- 6) Arcon de la alianza: ver, fijar porcentajes, repartir y pagar
-- ----------------------------------------------------------------
create or replace function public.wow_alliance_vault(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a text; islead boolean; tr jsonb; mem jsonb; tot numeric := 0; sm numeric := 0;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  a := u.alliance;
  if a is null then return jsonb_build_object('ok', true, 'vault', '{}'::jsonb, 'members', '[]'::jsonb,
    'is_leader', false, 'sum', 0); end if;
  islead := (u.id = _wow_ally_leader(a));
  select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into tr
    from wow_alliance_vault where alliance_id = a and qty > 0;
  select coalesce(sum(qty),0) into tot from wow_alliance_vault where alliance_id = a;
  select coalesce(sum(pct),0) into sm from wow_alliance_share where alliance_id = a
    and user_id in (select id from wow_users where alliance = a and active);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', w.id, 'name', w.name, 'pct', coalesce(s.pct, 0),
      'me', (w.id = u.id), 'leader', (w.id = _wow_ally_leader(a))) order by w.created), '[]'::jsonb)
    into mem
    from wow_users w
    left join wow_alliance_share s on s.alliance_id = a and s.user_id = w.id
   where w.alliance = a and w.active;
  return jsonb_build_object('ok', true, 'alliance', a, 'is_leader', islead,
    'tag', coalesce((select tag from wow_alliances where id = a), ''),
    'name', coalesce((select name from wow_alliances where id = a), ''),
    'vault', tr, 'total', tot, 'members', mem, 'sum', coalesce(sm,0));
end $$;
grant execute on function public.wow_alliance_vault(text) to anon, authenticated;

create or replace function public.wow_alliance_setshare(p_token text, p_id text, p_pct numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a text; sm numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  a := u.alliance;
  if a is null then raise exception 'No estás en ninguna alianza.'; end if;
  if u.id <> _wow_ally_leader(a) then raise exception 'Solo el líder de la alianza reparte el arcón.'; end if;
  if not exists(select 1 from wow_users w where w.id = p_id and w.alliance = a) then
    raise exception 'Ese reino no está en tu alianza.'; end if;
  if p_pct is null or p_pct < 0 or p_pct > 100 then raise exception 'El porcentaje debe estar entre 0 y 100.'; end if;
  insert into wow_alliance_share(alliance_id, user_id, pct) values (a, p_id, round(p_pct,2))
    on conflict (alliance_id, user_id) do update set pct = excluded.pct;
  select coalesce(sum(pct),0) into sm from wow_alliance_share where alliance_id = a;
  return jsonb_build_object('ok', true, 'id', p_id, 'pct', round(p_pct,2), 'sum', sm);
end $$;
grant execute on function public.wow_alliance_setshare(text, text, numeric) to anon, authenticated;

create or replace function public.wow_alliance_pay(p_token text, p_id text, p_key text, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a text; have numeric; q numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  a := u.alliance;
  if a is null then raise exception 'No estás en ninguna alianza.'; end if;
  if u.id <> _wow_ally_leader(a) then raise exception 'Solo el líder de la alianza reparte el arcón.'; end if;
  if not exists(select 1 from wow_users w where w.id = p_id and w.alliance = a) then
    raise exception 'Ese reino no está en tu alianza.'; end if;
  q := coalesce(p_qty, 0);
  if q <= 0 then raise exception 'Cantidad inválida.'; end if;
  select coalesce(qty,0) into have from wow_alliance_vault where alliance_id = a and key = p_key;
  have := coalesce(have, 0);
  if have <= 0 then raise exception 'No hay % en el arcón.', _wow_res_name(p_key); end if;
  if have < q then raise exception 'Solo hay % de % en el arcón.', have, _wow_res_name(p_key); end if;
  perform _wow_mkt_add(p_id, p_key, q);
  update wow_alliance_vault set qty = qty - q where alliance_id = a and key = p_key;
  perform _wow_event('alliance', '💰 ' || u.name || ' ha repartido ' || trim(to_char(q, 'FM999999990.##')) || ' ' ||
    _wow_res_name(p_key) || ' a ' || (select name from wow_users where id = p_id) || ' del arcón de su alianza.');
  return jsonb_build_object('ok', true, 'id', p_id, 'key', p_key, 'qty', q);
end $$;
grant execute on function public.wow_alliance_pay(text, text, text, numeric) to anon, authenticated;

create or replace function public.wow_alliance_distribute(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; a text; sm numeric; m record; v record; snap jsonb;
  amt numeric; have numeric; paid jsonb; n integer := 0;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  a := u.alliance;
  if a is null then raise exception 'No estás en ninguna alianza.'; end if;
  if u.id <> _wow_ally_leader(a) then raise exception 'Solo el líder de la alianza reparte el arcón.'; end if;
  select coalesce(sum(pct),0) into sm from wow_alliance_share
   where alliance_id = a and user_id in (select id from wow_users where alliance = a and active);
  if sm > 100.1 then raise exception 'Los porcentajes suman %: no pueden pasar de 100.', round(sm,1); end if;
  select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into snap
    from wow_alliance_vault where alliance_id = a and qty > 0;
  if snap = '{}'::jsonb then raise exception 'El arcón de la alianza está vacío.'; end if;
  for m in select w.id, w.name, coalesce(s.pct,0) pct
             from wow_users w left join wow_alliance_share s on s.alliance_id = a and s.user_id = w.id
            where w.alliance = a and w.active and coalesce(s.pct,0) > 0
            order by coalesce(s.pct,0) desc, w.created loop
    paid := '{}'::jsonb;
    for v in select key, (value)::numeric qty from jsonb_each_text(snap) loop
      select coalesce(qty,0) into have from wow_alliance_vault where alliance_id = a and key = v.key for update;
      have := coalesce(have, 0);
      if have > 0 then
        if _wow_mkt_is_troop(v.key) then
          amt := floor(v.qty * m.pct / 100.0);
        else
          amt := round(v.qty * m.pct / 100.0, 2);
        end if;
        if amt > have then amt := have; end if;
        if amt > 0 then
          perform _wow_mkt_add(m.id, v.key, amt);
          update wow_alliance_vault set qty = qty - amt where alliance_id = a and key = v.key;
          paid := paid || jsonb_build_object(v.key, amt);
        end if;
      end if;
    end loop;
    if paid <> '{}'::jsonb then
      n := n + 1;
      perform _wow_event('alliance', '💰 ' || m.name || ' recibe del arcón de la alianza: ' || _wow_res_str(paid) || '.');
    end if;
  end loop;
  delete from wow_alliance_vault where alliance_id = a and qty <= 0.001;
  return jsonb_build_object('ok', true, 'members_paid', n);
end $$;
grant execute on function public.wow_alliance_distribute(text) to anon, authenticated;

-- ----------------------------------------------------------------
-- 7) Los reinos automaticos: refuerzan y reclaman para su alianza,
--    y en guerra atacan los nodos de la alianza enemiga
-- ----------------------------------------------------------------
create or replace function public._wow_bot_act(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  b wow_bots; cfg jsonb; lvl integer; agro integer; base integer;
  ms bigint; tok text; tk text; bk text; cuartel integer; prot numeric; ua text;
  mypts numeric; army jsonb; tgt record; node integer; nx bigint; q integer;
begin
  select * into b from wow_bots where user_id = p_id and active;
  if b.user_id is null then return; end if;
  tok := b.token;
  cfg := _wow_bot_level(b.level);
  lvl := (cfg->>'bld')::int; agro := (cfg->>'agro')::int; base := (cfg->>'min')::int;
  ms := (extract(epoch from now())*1000)::bigint;
  ua := _wow_ally_of(p_id);

  -- 1) producir y terminar lo que tenga en marcha (y marcar last_ms = en linea)
  perform _wow_tick(p_id);

  -- 2) obra: el edificio mas atrasado que pueda pagar
  if not exists (select 1 from wow_queue q0 where q0.owner_id = p_id and q0.kind = 'build') then
    for bk in
      select v.k from (values ('mina'),('aserradero'),('tesoreria'),('almacen'),('cuartel'),
                              ('muralla'),('herreria'),('fortaleza'),('mercado')) v(k)
        left join wow_buildings bb on bb.owner_id = p_id and bb.bkey = v.k
       order by coalesce(bb.level,0) asc, random()
    loop
      begin
        perform wow_build(tok, bk);
        exit;
      exception when others then null;
      end;
    end loop;
  end if;

  -- 3) entrenar: la tropa mas fuerte que su cuartel le permita
  if not exists (select 1 from wow_queue q0 where q0.owner_id = p_id and q0.kind = 'train') then
    select coalesce(max(level),0) into cuartel from wow_buildings where owner_id = p_id and bkey = 'cuartel';
    for tk in select v.t from (values ('dragon',1),('paladin',2),('mago',3),
                                      ('jinete',4),('arquero',5),('soldado',6)) v(t,ord)
               order by v.ord
    loop
      if cuartel >= _wow_treq(tk) then
        q := greatest(5, ((cfg->>'trp')::int) / 3);
        begin
          perform wow_train(tok, tk, q);
          exit;
        exception when others then exit;
        end;
      end if;
    end loop;
  end if;

  -- 4) accion de guerra
  if random()*100 < agro then
    mypts := _wow_points(p_id);
    army := _wow_bot_army(p_id, 0.6);
    if army <> '{}'::jsonb then
      -- a) conquistar una aldea libre que no sea de su alianza (mejor botin, menos conflicto)
      select th.node into node from wow_thrones th
        where th.kind = 'aldea'
          and th.holder is distinct from p_id
          and (th.holder_ally is null or ua is null or th.holder_ally <> ua)
          and coalesce((select sum((x.value)::int) from jsonb_each_text(th.garrison) x), 0) = 0
        order by random() limit 1;
      if node is not null then
        begin perform wow_throne_attack(tok, node, army); exception when others then null; end;
      else
        -- a2) si su alianza esta en guerra, va a por un nodo de la alianza enemiga
        if ua is not null then
          select th.node into node from wow_thrones th
            join wow_ally_wars wr on wr.active and (wr.a = ua or wr.b = ua)
              and th.holder_ally = case when wr.a = ua then wr.b else wr.a end
           where th.holder_ally is not null
           order by random() limit 1;
          if node is not null then
            begin perform wow_throne_attack(tok, node, army); exception when others then null; end;
          end if;
        end if;
      end if;
      if node is null then
        prot := _wow_protect_reino();
        tgt := null;
        -- b) si su alianza esta en guerra, va a por el reino enemigo (asi luchan juntos y suman para la alianza)
        if ua is not null then
          select eu.id into tgt from wow_ally_wars wr
            join wow_users eu on eu.alliance = case when wr.a = ua then wr.b else wr.a end
            where wr.active and (wr.a = ua or wr.b = ua)
              and eu.active and not eu.is_admin and eu.id <> p_id
              and (prot = 0 or (_wow_points(eu.id) >= prot and mypts - _wow_points(eu.id) < prot))
            order by _wow_points(eu.id) asc, random() limit 1;
        end if;
        -- c) si no, al rival mas debil que siga siendo un objetivo valido (nunca de su propia alianza)
        if tgt.id is null then
          select w.id into tgt from wow_users w
            where w.active and not w.is_admin and w.id <> p_id
              and (ua is null or w.alliance is null or w.alliance <> ua)
              and (prot = 0 or (_wow_points(w.id) >= prot and mypts - _wow_points(w.id) < prot))
            order by _wow_points(w.id) asc, random() limit 1;
        end if;
        if tgt.id is not null then
          begin perform wow_attack(tok, tgt.id, army); exception when others then null; end;
        end if;
      end if;
    end if;
  end if;

  -- 5) cobrar el tesoro de lo que controle (suyo o de su alianza: va al arcon)
  if random() < 0.35 then
    select th.node into node from wow_thrones th
      where th.holder = p_id or (ua is not null and th.holder_ally = ua)
      order by random() limit 1;
    if node is not null then
      begin perform wow_throne_claim(tok, node); exception when others then null; end;
    end if;
  end if;

  -- 6) los mas fuertes refuerzan sus nodos y los de su alianza
  if lvl >= 6 and random() < 0.2 then
    select th.node into node from wow_thrones th
      where th.holder = p_id or (ua is not null and th.holder_ally = ua)
      order by random() limit 1;
    if node is not null then
      army := _wow_bot_army(p_id, 0.4);
      if army <> '{}'::jsonb then
        begin perform wow_throne_reinforce(tok, node, army); exception when others then null; end;
      end if;
    end if;
  end if;

  -- 7) cadencia humana: turnos irregulares y, a veces, un descanso largo
  if random() < 0.12 then
    nx := ms + (30*60000 + (random()*90*60000)::bigint)::bigint;   -- 30-120 min fuera
  else
    nx := ms + (base*60000*(0.5 + random()))::bigint;              -- 0.5x - 1.5x
  end if;
  update wow_bots set next_ms = nx, last_act_ms = ms where user_id = p_id;
end $$;
revoke all on function public._wow_bot_act(text) from public, anon, authenticated;
