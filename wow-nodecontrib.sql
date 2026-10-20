-- ================================================================
-- Apendice: aportes de tropas por jugador en tronos y aldeas
-- (cada uno solo puede retirar lo que aporto)
-- ================================================================

create table if not exists public.wow_node_contrib(
  node integer not null,
  user_id text not null,
  troops jsonb not null default '{}'::jsonb,
  primary key (node, user_id)
);
alter table public.wow_node_contrib enable row level security;
revoke all on table public.wow_node_contrib from anon, authenticated;

create or replace function public._wow_contrib_get(p_node integer, p_uid text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce((select troops from wow_node_contrib where node = p_node and user_id = p_uid), '{}'::jsonb)
$$;
revoke all on function public._wow_contrib_get(integer, text) from public, anon, authenticated;

create or replace function public._wow_contrib_add(p_node integer, p_uid text, p_army jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare m jsonb;
begin
  if p_uid is null or coalesce(p_army, '{}'::jsonb) = '{}'::jsonb then return; end if;
  select coalesce(jsonb_object_agg(key, s), '{}'::jsonb) into m from (
    select key, sum(v) as s from (
      select key, value::int as v from jsonb_each_text(_wow_contrib_get(p_node, p_uid))
      union all
      select key, value::int as v from jsonb_each_text(p_army)
    ) x group by key having sum(v) > 0
  ) y;
  if m = '{}'::jsonb then
    delete from wow_node_contrib where node = p_node and user_id = p_uid;
  else
    insert into wow_node_contrib(node, user_id, troops) values (p_node, p_uid, m)
      on conflict (node, user_id) do update set troops = excluded.troops;
  end if;
end $$;
revoke all on function public._wow_contrib_add(integer, text, jsonb) from public, anon, authenticated;

create or replace function public._wow_contrib_sub(p_node integer, p_uid text, p_army jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare m jsonb;
begin
  if p_uid is null or coalesce(p_army, '{}'::jsonb) = '{}'::jsonb then return; end if;
  select coalesce(jsonb_object_agg(key, s), '{}'::jsonb) into m from (
    select key, sum(v) as s from (
      select key, value::int as v from jsonb_each_text(_wow_contrib_get(p_node, p_uid))
      union all
      select key, -(value::int) as v from jsonb_each_text(p_army)
    ) x group by key having sum(v) > 0
  ) y;
  if m = '{}'::jsonb then
    delete from wow_node_contrib where node = p_node and user_id = p_uid;
  else
    insert into wow_node_contrib(node, user_id, troops) values (p_node, p_uid, m)
      on conflict (node, user_id) do update set troops = excluded.troops;
  end if;
end $$;
revoke all on function public._wow_contrib_sub(integer, text, jsonb) from public, anon, authenticated;

create or replace function public._wow_contrib_set(p_node integer, p_uid text, p_army jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  delete from wow_node_contrib where node = p_node and user_id = p_uid;
  if p_uid is not null and coalesce(p_army, '{}'::jsonb) <> '{}'::jsonb then
    insert into wow_node_contrib(node, user_id, troops) values (p_node, p_uid, p_army);
  end if;
end $$;
revoke all on function public._wow_contrib_set(integer, text, jsonb) from public, anon, authenticated;

create or replace function public._wow_contrib_clear(p_node integer)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  delete from wow_node_contrib where node = p_node;
end $$;
revoke all on function public._wow_contrib_clear(integer) from public, anon, authenticated;

create or replace function public._wow_contrib_scale(p_node integer, p_garrison jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare k text; tot int; nw int; carry int; sh int; c record; big text;
begin
  for k in select key from (
      select jsonb_object_keys(troops) as key from wow_node_contrib where node = p_node
      union
      select jsonb_object_keys(coalesce(p_garrison, '{}'::jsonb)) as key
    ) u loop
    select coalesce(sum(coalesce((troops->>k)::int, 0)), 0) into tot
      from wow_node_contrib where node = p_node;
    nw := coalesce((coalesce(p_garrison, '{}'::jsonb)->>k)::int, 0);
    if tot > 0 and nw < tot then
      carry := nw;
      for c in select user_id, coalesce((troops->>k)::int, 0) as v
                 from wow_node_contrib where node = p_node
                order by coalesce((troops->>k)::int, 0) desc, user_id loop
        if c.v > 0 then
          sh := floor(c.v::numeric * nw / tot);
          if sh > carry then sh := carry; end if;
          if sh > 0 then
            update wow_node_contrib set troops = jsonb_set(troops, array[k], to_jsonb(sh), true)
             where node = p_node and user_id = c.user_id;
          else
            update wow_node_contrib set troops = troops - k
             where node = p_node and user_id = c.user_id;
          end if;
          carry := carry - sh;
        end if;
      end loop;
      if carry > 0 then
        select user_id into big from wow_node_contrib where node = p_node
          order by coalesce((troops->>k)::int, 0) desc, user_id limit 1;
        if big is not null then
          update wow_node_contrib set troops = jsonb_set(troops, array[k],
            to_jsonb(coalesce((troops->>k)::int, 0) + carry), true)
           where node = p_node and user_id = big;
        end if;
      end if;
    end if;
  end loop;
  delete from wow_node_contrib where node = p_node and troops = '{}'::jsonb;
end $$;
revoke all on function public._wow_contrib_scale(integer, jsonb) from public, anon, authenticated;

insert into wow_node_contrib(node, user_id, troops)
select node, holder, garrison from wow_thrones
 where holder is not null and coalesce(garrison, '{}'::jsonb) <> '{}'::jsonb
on conflict (node, user_id) do nothing;

create or replace function public._wow_contrib_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.garrison = '{}'::jsonb or new.holder is distinct from old.holder then
    delete from wow_node_contrib where node = new.node;
  end if;
  return new;
end $$;
revoke all on function public._wow_contrib_guard() from public, anon, authenticated;
drop trigger if exists wow_contrib_guard on public.wow_thrones;
create trigger wow_contrib_guard after update on public.wow_thrones
  for each row execute function public._wow_contrib_guard();

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
      perform _wow_contrib_add(t.node, u.id, f.troops);
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
    perform _wow_contrib_set(t.node, u.id, f.troops);
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
    perform _wow_contrib_set(t.node, u.id, surv);
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
    perform _wow_contrib_scale(t.node, surv);
    perform _wow_throne_log(t.node, 'defended', u.id, u.name, jsonb_build_object('holder', prev));
    perform _wow_event('throne', '🛡️ La guarnición de ' || t.name || ' ha rechazado el ataque de ' || u.name || '.');
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms);
  end if;
  delete from wow_fleets where id = f.id;
end $$;
revoke all on function public._wow_throne_land(bigint) from public, anon, authenticated;

create or replace function public.wow_throne_withdraw(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; newg jsonb; mc jsonb; z record; left_g int; travel integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if not _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
    raise exception 'No controlas ese lugar.'; end if;
  mc := _wow_contrib_get(t.node, u.id);
  for z in select key, value::int from jsonb_each_text(army) loop
    if coalesce((mc->>z.key)::int, 0) < z.value then
      raise exception 'Solo puedes retirar las tropas que aportaste.'; end if;
  end loop;
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
  perform _wow_contrib_sub(t.node, u.id, army);
  perform _wow_throne_log(t.node, 'withdraw', u.id, u.name, jsonb_build_object('troops', army));
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'returning', 'throne_with', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000,
                            'empty', (newg = '{}'::jsonb), 'target', t.name);
end $$;
grant execute on function public.wow_throne_withdraw(text, integer, jsonb) to anon, authenticated;

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
      'faction', fac, 'mycontrib', _wow_contrib_get(t.node, p_uid), 'garrison', coalesce(g,0), 'gdetail', t.garrison, 'since', t.since_ms,
      'mine', _wow_node_mine(t.holder, t.holder_ally, p_uid, ua), 'treasure', tr, 'history', hist);
  end loop;
  return arr;
end $$;
revoke all on function public._wow_fort_info(text, text) from public, anon, authenticated;
