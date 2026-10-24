-- Arreglar ataques conjuntos a tronos/fortalezas/aldeas
-- Las tropas deben repartirse correctamente entre participantes

create or replace function public._wow_throne_land(p_fleet_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $fn$
declare
  f wow_fleets; u wow_users; t wow_thrones; ms bigint; z record; r record;
  sim jsonb; surv jsonb; msg jsonb; prev text; ret integer; ually text; lab text;
  a_forge int; a_fort int; d_forge int; d_fort int; d_wall int;
  a_bon numeric; d_bon numeric; a_bon_arr numeric[]; jst jsonb;
  asurv_all jsonb := '{}'::jsonb;
  jp record;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  select * into f from wow_fleets where id = p_fleet_id for update;
  if f.id is null then return; end if;
  select * into u from wow_users where id = f.attacker;
  if u.id is null then delete from wow_fleets where id = f.id; return; end if;
  select * into t from wow_thrones where node = f.node for update;
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
      if t.holder_ally is not null then
        lab := _wow_ally_label(t.holder_ally);
        perform _wow_event('alliance', '🏛️ ' || u.name || ' ha llevado el tesoro de ' || t.name || ' al arcón de ' || coalesce(nullif(lab,''), 'su alianza') || '.');
        insert into wow_reports(owner, kind, data, created)
          values (u.id, 'out', jsonb_build_object('dir','vault','who',coalesce(t.name,''),'win',true,'loot',msg,'ally',lab,'created',ms), ms);
        delete from wow_fleets where id = f.id;
        return;
      end if;
    end if;
    ret := _wow_travel_node(u.pos, coalesce(f.node, _wow_pos_node(u.pos)));
    update wow_fleets set state = 'returning', loot = msg, arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
    return;
  end if;
  if f.kind = 'throne_rein' then
    if t.node is not null and _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
      surv := t.garrison;
      for z in select key, value::int from jsonb_each_text(f.troops) loop
        surv := jsonb_set(surv, array[z.key], to_jsonb(coalesce((surv->>z.key)::int,0) + z.value), true);
      end loop;
      update wow_thrones set garrison = surv where node = t.node;
      if f.joint_op is not null then
        for jp in select * from jsonb_array_elements(_wow_joint_split(f.joint_op, f.troops, '{}'::jsonb)) loop
          perform _wow_contrib_add(t.node, jp.value->>'owner', jp.value->'troops');
        end loop;
      else
        perform _wow_contrib_add(t.node, u.id, f.troops);
      end if;
      perform _wow_throne_log(t.node, 'reinforce', u.id, u.name, jsonb_build_object('troops', f.troops));
      perform _wow_event('throne', '🛡️ ' || u.name || ' ha reforzado ' || t.name || '.');
      insert into wow_reports(owner, kind, data, created)
        values (u.id, 'out', jsonb_build_object('dir','throne_rein','who',coalesce(t.name,''),'win',true,'created',ms), ms);
      if f.joint_op is not null then
        perform _wow_joint_settle(f.joint_op, '{}'::jsonb, '{}'::jsonb);
      end if;
      delete from wow_fleets where id = f.id;
      return;
    else
      ret := _wow_travel_node(u.pos, coalesce(f.node, _wow_pos_node(u.pos)));
      if f.joint_op is not null then
        update wow_fleets set state = 'returning', troops = f.troops, loot = '{}'::jsonb, arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
      else
        update wow_fleets set state = 'returning', arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
      end if;
      insert into wow_reports(owner, kind, data, created)
        values (u.id, 'out', jsonb_build_object('dir','throne_rein','who',coalesce(t.name,''),'win',false,'note','Ya no controlabas ese lugar: tus tropas vuelven a casa.','created',ms), ms);
      return;
    end if;
  end if;
  if t.node is null then
    ret := _wow_travel_node(u.pos, _wow_pos_node(u.pos));
    update wow_fleets set state = 'returning', troops = f.troops, arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who','','win',false,'note','El objetivo ya no existe: tus tropas vuelven a casa.','created',ms), ms);
    return;
  end if;
  if coalesce(t.holder,'') = '' or t.garrison = '{}'::jsonb then
    ually := u.alliance;
    update wow_thrones set holder = u.id, holder_name = u.name, holder_ally = ually, since_ms = ms, garrison = f.troops, accrue_ms = ms where node = t.node;
    delete from wow_node_contrib where node = t.node;
    if f.joint_op is not null then
      for jp in select * from jsonb_array_elements(_wow_joint_split(f.joint_op, f.troops, '{}'::jsonb)) loop
        perform _wow_contrib_add(t.node, jp.value->>'owner', jp.value->'troops');
      end loop;
    else
      perform _wow_contrib_set(t.node, u.id, f.troops);
    end if;
    perform _wow_throne_log(t.node, 'take', u.id, u.name, jsonb_build_object('garrison', f.troops));
    lab := _wow_ally_label(ually);
    perform _wow_event('throne', (case when t.kind = 'aldea' then '🛖 ' else '🏯 ' end) || u.name || ' ha ocupado ' || t.name || (case when ually is not null then ' en nombre de ' || coalesce(nullif(lab,''),'su alianza') else '' end) || '.');
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',true,'battle',null,'ally', lab, 'created',ms), ms);
    if f.joint_op is not null then
      perform _wow_joint_throne_loot(f.joint_op, t.node, t.name, null, true);
      update wow_joint_ops set status = 'done' where id = f.joint_op;
      for jp in select * from jsonb_array_elements(_wow_joint_split(f.joint_op, f.troops, '{}'::jsonb)) loop
        if jp.value->>'owner' <> u.id then
          insert into wow_reports(owner, kind, data, created)
            values (jp.value->>'owner','out', jsonb_build_object('dir','throne','who',t.name,'win',true,'joint',true,'created',ms), ms);
        end if;
      end loop;
    end if;
    delete from wow_fleets where id = f.id;
    return;
  end if;
  prev := t.holder_name;
  a_forge := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'herreria'), 0);
  a_fort  := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'fortaleza'), 0);
  d_forge := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'herreria'), 0);
  d_fort  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'fortaleza'), 0);
  d_wall  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'muralla'), 0);
  a_bon := _wow_madam_bonus(u.id);
  d_bon := _wow_madam_bonus(t.holder);
  a_bon_arr := null; jst := null;
  if f.joint_op is not null then
    jst := _wow_joint_stats(f.joint_op);
    a_bon_arr := _wow_joint_bonus(f.joint_op);
  end if;
  if jst is not null then
    sim := _wow_sim(f.troops, t.garrison, d_wall, (ms/1000) + t.node*131,
                    (jst->>'might')::numeric, 1 + 0.04*d_forge,
                    (jst->>'tough')::numeric, 1 + 0.04*d_fort, a_bon, d_bon, a_bon_arr, null);
  else
    sim := _wow_sim(f.troops, t.garrison, d_wall, (ms/1000) + t.node*131,
                    1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort, a_bon, d_bon);
  end if;
  if (sim->>'winner') = 'attacker' then
    ually := u.alliance;
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'a_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    update wow_thrones set holder = u.id, holder_name = u.name, holder_ally = ually, since_ms = ms, garrison = surv, accrue_ms = ms where node = t.node;
    delete from wow_node_contrib where node = t.node;
    if f.joint_op is not null then
      for jp in select * from jsonb_array_elements(_wow_joint_split(f.joint_op, surv, '{}'::jsonb)) loop
        perform _wow_contrib_add(t.node, jp.value->>'owner', jp.value->'troops');
      end loop;
      for jp in select * from jsonb_array_elements(_wow_joint_split(f.joint_op, surv, '{}'::jsonb)) loop
        if jp.value->>'owner' <> u.id then
          insert into wow_reports(owner, kind, data, created)
            values (jp.value->>'owner','out', jsonb_build_object('dir','throne','who',t.name,'win',true,'battle',sim,'joint',true,'created',ms), ms);
        end if;
      end loop;
    else
      perform _wow_contrib_set(t.node, u.id, surv);
    end if;
    perform _wow_throne_log(t.node, 'conquest', u.id, u.name, jsonb_build_object('from', prev));
    lab := _wow_ally_label(ually);
    perform _wow_event('throne', (case when t.kind = 'aldea' then '🏘️ ' else '👑 ' end) || u.name || ' ha conquistado ' || t.name || ' (antes de ' || coalesce(prev, 'nadie') || ')' || (case when ually is not null then ', en nombre de ' || coalesce(nullif(lab,''),'su alianza') else '' end) || '.');
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',true,'from',u.name,'battle',sim,'ally',lab,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',true,'from',u.name,'battle',sim,'created',ms), ms);
    if f.joint_op is not null then
      perform _wow_joint_throne_loot(f.joint_op, t.node, t.name, sim, true);
      update wow_joint_ops set status = 'done' where id = f.joint_op;
    end if;
    delete from wow_fleets where id = f.id;
    return;
  else
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'d_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    update wow_thrones set garrison = surv where node = t.node;
    if f.joint_op is not null then
      delete from wow_node_contrib where node = t.node;
      for jp in select * from jsonb_array_elements(_wow_joint_split(f.joint_op, '{}'::jsonb, '{}'::jsonb)) loop
        -- mantener contrib anterior? mejor recalcular desde nuevo garrison no aplica; mantenemos reparto base
      end loop;
      perform _wow_contrib_scale(t.node, surv);
    else
      perform _wow_contrib_scale(t.node, surv);
    end if;
    perform _wow_throne_log(t.node, 'defended', u.id, u.name, jsonb_build_object('holder', prev));
    perform _wow_event('throne', '🛡️ La guarnición de ' || t.name || ' ha rechazado el ataque de ' || u.name || '.');
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms);
    if f.joint_op is not null then
      perform _wow_joint_throne_loot(f.joint_op, t.node, t.name, sim, false);
      for z in select key, value from jsonb_each_text(sim->'a_left') loop
        if (z.value)::int > 0 then asurv_all := asurv_all || jsonb_build_object(z.key, (z.value)::int); end if;
      end loop;
      ret := _wow_travel_node(u.pos, coalesce(f.node, _wow_pos_node(u.pos)));
      update wow_fleets set state = 'returning', troops = asurv_all, loot = '{}'::jsonb, arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
      update wow_joint_ops set status = 'done' where id = f.joint_op;
      return;
    end if;
    ret := _wow_travel_node(u.pos, (select pos from wow_users where id = t.holder));
    update wow_fleets set state = 'returning', troops = '{}'::jsonb, loot = '{}'::jsonb, arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
    return;
  end if;
end $fn$;
revoke all on function public._wow_throne_land(bigint) from public;
