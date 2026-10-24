-- ================================================================
-- BOTS v2 - FASE 3+4
--   (3) Ataques conjuntos solo si la fuerza combinada gana
--   (4) Retirada defensiva: si un ejército enemigo va a derrotar sus tropas
--       en tronos/aldeas/castillo, intenta evacuar con wow_throne_withdraw
-- ================================================================

-- comprobar si una alianza puede ganar contra un objetivo con sus tropas listas
create or replace function public._wow_bot_joint_will_win(p_alliance text, p_kind text, p_ref text, p_node integer)
returns boolean language plpgsql security definer set search_path to 'public' as $function$
declare
  ua text := p_alliance;
  comb jsonb := '{}'::jsonb;
  r record; z record; ev jsonb;
  seed bigint := (extract(epoch from now())*1000)::bigint;
begin
  if ua is null then return false; end if;
  for r in
    select b.user_id, b.token from wow_bots b
      join wow_users u on u.id = b.user_id
     where u.alliance = ua and b.active
  loop
    select _wow_bot_army(r.user_id, 0.6) into comb;
    -- merge
    for z in select key, value from jsonb_each_text(comb) loop
      comb := comb || jsonb_build_object(z.key, coalesce((comb->>z.key)::int,0) + (z.value)::int);
    end loop;
  end loop;
  if comb = '{}'::jsonb then return false; end if;
  -- simulación simplificada contra objetivo (niebla ligera)
  if p_kind = 'reino' and p_ref is not null then
    ev := _wow_bot_sim_kingdom((select leader from wow_joint_ops where alliance = ua and status='open' limit 1), p_ref, comb, false, 0.08);
    return coalesce(ev->>'win','false') = 'true';
  end if;
  if p_node is not null then
    ev := _wow_bot_sim_node((select leader from wow_joint_ops where alliance = ua and status='open' limit 1), p_node, comb, 0.08);
    return coalesce(ev->>'win','false') = 'true';
  end if;
  return false;
exception when others then return false;
end $function$;
revoke all on function public._wow_bot_joint_will_win(text, text, text, integer) from public, anon, authenticated;

-- parchear _wow_bot_joint: solo convocar/lanzar si gana combinado
create or replace function public._wow_bot_joint(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare
  b wow_bots; ua text; ms bigint; cfg jsonb; op wow_joint_ops; res jsonb;
  army jsonb; tgt record; node integer; prot numeric; mypts numeric; agro integer;
  others integer; kind text; tgt_id text; nk text; tot integer; ev jsonb;
begin
  select * into b from wow_bots where user_id = p_id and active;
  if b.user_id is null then return; end if;
  ua := _wow_ally_of(p_id);
  if ua is null then return; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  cfg := _wow_bot_level(b.level);
  agro := (cfg->>'agro')::int;
  select coalesce(sum(qty),0)::int into tot from wow_troops where owner_id = p_id;
  if tot < 10 then return; end if;

  select o.* into op from wow_joint_ops o
    where o.alliance = ua and o.leader = p_id and o.status = 'open' and o.deadline_ms > ms
    order by o.created_ms asc limit 1;
  prot := _wow_protect_reino();
  mypts := _wow_points(p_id);
  if op.id is not null then
    select count(*) into others from wow_joint_ops_troops t where t.op_id = op.id and t.owner <> p_id;
    if (others > 0 or op.created_ms < ms - 7200000)
       and _wow_target_attack_ok(op.target_kind, op.target_ref, op.target_node, mypts)
       and _wow_joint_bot_safe(op.target_kind, op.target_ref, op.target_node)
       and _wow_bot_joint_will_win(ua, op.target_kind, op.target_ref, op.target_node) then
      begin
        perform wow_joint_launch(b.token, op.id);
        perform _wow_bot_log(p_id, 'joint_launch', jsonb_build_object('op', op.id));
        insert into wow_bot_joint_log(op_id, user_id, alliance, action, created) values (op.id, p_id, ua, 'launch', ms);
      exception when others then null;
      end;
    end if;
  end if;

  if not exists (select 1 from wow_joint_ops_troops t
                  where t.op_id in (select id from wow_joint_ops where alliance = ua and status = 'open') and t.owner = p_id) then
    select o.* into op from wow_joint_ops o
      where o.alliance = ua and o.status = 'open' and o.deadline_ms > ms + 1800000
        and not exists (select 1 from wow_joint_ops_troops t where t.op_id = o.id and t.owner = p_id)
      order by o.created_ms desc limit 1;
    if op.id is not null and random() < 0.5 + (b.teamwork::numeric/200)
       and _wow_target_attack_ok(op.target_kind, op.target_ref, op.target_node, mypts)
       and _wow_joint_bot_safe(op.target_kind, op.target_ref, op.target_node)
       and _wow_bot_joint_will_win(ua, op.target_kind, op.target_ref, op.target_node) then
      army := _wow_bot_army(p_id, 0.55);
      if army <> '{}'::jsonb then
        begin
          perform wow_joint_join(b.token, op.id, army);
          perform _wow_bot_log(p_id, 'joint_join', jsonb_build_object('op', op.id));
          insert into wow_bot_joint_log(op_id, user_id, alliance, action, created) values (op.id, p_id, ua, 'join', ms);
        exception when others then null;
        end;
      end if;
    end if;
  end if;

  if not exists (select 1 from wow_joint_ops where alliance = ua and status = 'open')
     and random() < (agro::numeric/100) * (b.teamwork::numeric/100) * 0.4 then
    mypts := _wow_points(p_id);
    prot := _wow_protect_reino();
    kind := null; tgt_id := null; node := null;
    if prot = 0 or mypts >= prot then
      -- buscar objetivo enemigo fuerte pero vencible en conjunto
      for tgt in
        select th.node, th.kind, th.holder from wow_thrones th
          where th.kind in ('trono','fortaleza')
            and coalesce(th.holder,'') <> ''
            and th.holder <> p_id
            and not exists (select 1 from wow_bots bb where bb.user_id = th.holder)
            and (th.holder_ally is null or th.holder_ally <> ua)
            and _wow_target_attack_ok('trono', null, th.node, mypts)
          order by random() limit 4
      loop
        if _wow_bot_joint_will_win(ua, tgt.kind, null, tgt.node) then
          kind := tgt.kind; node := tgt.node; exit;
        end if;
      end loop;
      if kind is null then
        for tgt in
          select w.id from wow_users w
            where w.active and not w.is_admin and w.id <> p_id
              and not exists (select 1 from wow_bots bb where bb.user_id = w.id)
              and (ua is null or w.alliance is null or w.alliance <> ua)
              and _wow_target_attack_ok('reino', w.id, null, mypts)
            order by _wow_points(w.id) desc, random() limit 4
        loop
          if _wow_bot_joint_will_win(ua, 'reino', tgt.id, null) then
            kind := 'reino'; tgt_id := tgt.id; exit;
          end if;
        end loop;
      end if;
    end if;
    if kind is not null then
      begin
        res := wow_joint_open(b.token, kind, tgt_id, node);
        if res is not null and res->>'id' is not null then
          perform _wow_bot_log(p_id, 'joint_open', jsonb_build_object('op', res->>'id', 'kind', kind));
          insert into wow_bot_joint_log(op_id, user_id, alliance, action, created) values ((res->>'id')::bigint, p_id, ua, 'open', ms);
          army := _wow_bot_army(p_id, 0.6);
          if army <> '{}'::jsonb then
            perform wow_joint_join(b.token, (res->>'id')::bigint, army);
            insert into wow_bot_joint_log(op_id, user_id, alliance, action, created) values ((res->>'id')::bigint, p_id, ua, 'join', ms);
          end if;
        end if;
      exception when others then null;
      end;
    end if;
  end if;
end $function$;
revoke all on function public._wow_bot_joint(text) from public, anon, authenticated;
grant execute on function public._wow_bot_joint(text) to anon, authenticated;

-- ================================================================
-- DEFENSA: retirada ante ataques entrantes
-- ================================================================
create or replace function public._wow_bot_defend(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare
  b wow_bots; ua text; ms bigint; f wow_fleets; trow wow_thrones;
  g jsonb := '{}'::jsonb; z record; army jsonb; ev jsonb;
  tok text; total_g int := 0;
begin
  select * into b from wow_bots where user_id = p_id and active;
  if b.user_id is null then return; end if;
  if coalesce(b.defense_aware,50) < 20 then return; end if;
  tok := b.token; ua := _wow_ally_of(p_id); ms := (extract(epoch from now())*1000)::bigint;
  perform _wow_tick(p_id);

  -- flotas que van a atacar castillo/reino propio o sus tronos
  for f in
    select * from wow_fleets fl
      where fl.state = 'outbound'
        and fl.arrive_ms > ms and fl.arrive_ms < ms + 1800000
        and (
          (fl.kind = 'attack' and fl.target = p_id) or
          (fl.kind in ('throne_atk') and exists (select 1 from wow_thrones th where th.node = fl.node and (th.holder = p_id or (ua is not null and th.holder_ally = ua))))
        )
      order by fl.arrive_ms asc
  loop
    if f.kind = 'throne_atk' and f.node is not null then
      select * into trow from wow_thrones where node = f.node;
      if trow.node is not null then
        select coalesce(sum((value)::int),0) into total_g from jsonb_each_text(trow.garrison);
        if total_g >= 5 then
          army := trow.garrison;
          ev := _wow_bot_sim_node(p_id, f.node, army, 0.05);
          if coalesce(ev->>'win','true') = 'false' or coalesce((ev->>'loss_pct')::int,0) > 40 then
            -- retirar todo menos 0? retirar 60% a casa
            g := '{}'::jsonb;
            for z in select key, value from jsonb_each_text(trow.garrison) loop
              g := g || jsonb_build_object(z.key, greatest(1, floor((z.value)::int * 0.6)));
            end loop;
            begin
              perform wow_throne_withdraw(tok, f.node, g);
              perform _wow_bot_log(p_id, 'defend_withdraw', jsonb_build_object('node', f.node, 'troops', g));
            exception when others then null;
            end;
          end if;
        end if;
      end if;
    end if;
    -- para castillo propio con ataque directo: no hay función pública para "vaciar" fácil; solo log
    if f.kind = 'attack' and f.target = p_id then
      perform _wow_bot_log(p_id, 'incoming_attack', jsonb_build_object('from', f.attacker, 'arrive', f.arrive_ms));
    end if;
  end loop;
end $function$;
revoke all on function public._wow_bot_defend(text) from public, anon, authenticated;

-- integrar en _wow_bot_act
create or replace function public._wow_bot_act(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $function$
declare
  b wow_bots; cfg jsonb; lvl integer; agro integer; base integer;
  ms bigint; tok text; tk text; bk text; cuartel integer; prot numeric; ua text; tc jsonb;
  mypts numeric; army jsonb; tgt record; node integer; nx bigint; q integer;
  ev jsonb; tgt_id text; fog numeric; fought boolean;
begin
  select * into b from wow_bots where user_id = p_id and active;
  if b.user_id is null then return; end if;
  tok := b.token;
  cfg := _wow_bot_level(b.level);
  lvl := (cfg->>'bld')::int; agro := (cfg->>'agro')::int; base := (cfg->>'min')::int;
  ms := (extract(epoch from now())*1000)::bigint;
  ua := _wow_ally_of(p_id);
  perform _wow_tick(p_id);
  perform _wow_bot_joint(p_id);
  perform _wow_bot_defend(p_id);

  if not exists (select 1 from wow_queue q0 where q0.owner_id = p_id and q0.kind = 'train') then
    select coalesce(max(level),0) into cuartel from wow_buildings where owner_id = p_id and bkey = 'cuartel';
    for tk in select v.t from (values ('dragon',1),('paladin',2),('mago',3),('jinete',4),('arquero',5),('soldado',6)) v(t,ord)
               order by v.ord loop
      if cuartel >= _wow_treq(tk) then
        tc := _wow_tcost(tk);
        q := least(greatest(1, ((cfg->>'trp')::int) / 3),
                   greatest(1, floor(least(
                     coalesce((select gold from wow_users where id = p_id), 0) / nullif((tc->>'gold')::numeric,0),
                     coalesce((select wood from wow_users where id = p_id), 0) / nullif((tc->>'wood')::numeric,0),
                     coalesce((select ore  from wow_users where id = p_id), 0) / nullif((tc->>'ore')::numeric,0)
                   )))::int);
        begin perform wow_train(tok, tk, q); exit; exception when others then exit; end;
      end if;
    end loop;
  end if;

  if not exists (select 1 from wow_queue q0 where q0.owner_id = p_id and q0.kind = 'build')
     and (select coalesce(sum(qty),0) from wow_troops where owner_id = p_id) >= 25 then
    for bk in select v.k from (values ('mina'),('aserradero'),('tesoreria'),('almacen'),('cuartel'),('muralla'),('herreria'),('fortaleza'),('mercado')) v(k)
               left join wow_buildings bb on bb.owner_id = p_id and bb.bkey = v.k
               order by coalesce(bb.level,0) asc, random() loop
      begin perform wow_build(tok, bk); exit; exception when others then null; end;
    end loop;
  end if;

  if random()*100 < agro and (select coalesce(sum(qty),0) from wow_troops where owner_id = p_id) >= 20 then
    mypts := _wow_points(p_id);
    prot := _wow_protect_reino();
    fog := greatest(0.02, 0.16 - 0.02 * lvl);
    army := _wow_bot_army(p_id, 0.8);
    if army <> '{}'::jsonb and (prot = 0 or mypts >= prot) then
      fought := false;

      select th.node into node from wow_thrones th
        where th.kind = 'aldea' and coalesce(th.holder,'') = '' and _wow_target_attack_ok('aldea', null, th.node, mypts)
        order by random() limit 1;
      if node is not null then
        begin perform wow_throne_attack(tok, node, army); perform _wow_bot_log(p_id, 'node_attack', jsonb_build_object('node',node,'kind','aldea','free',true)); fought := true; exception when others then null; end;
      end if;

      if not fought and random()*100 < b.spy_rate and ms - b.scout_ms > 21600000 then
        select w.id into tgt_id from wow_users w
          where w.active and not w.is_admin and w.id <> p_id and not exists (select 1 from wow_bots bb where bb.user_id = w.id)
            and (ua is null or w.alliance is null or w.alliance <> ua) and _wow_target_attack_ok('reino', w.id, null, mypts)
          order by random() limit 1;
        if tgt_id is not null then
          begin perform wow_spy(tok, tgt_id); update wow_bots set scout_ms = ms where user_id = p_id; exception when others then null; end;
        end if;
      end if;

      if not fought then
        for tgt in select w.id from wow_users w
                    where w.active and not w.is_admin and w.id <> p_id and not exists (select 1 from wow_bots bb where bb.user_id = w.id)
                      and (ua is null or w.alliance is null or w.alliance <> ua) and _wow_target_attack_ok('reino', w.id, null, mypts)
                    order by _wow_points(w.id) asc, random() limit 6 loop
          ev := _wow_bot_sim_kingdom(p_id, tgt.id, army, false, fog);
          if coalesce(ev->>'ok','false')='true' and ev->>'win'='true' and _wow_bot_loss_ok(p_id, coalesce((ev->>'loss_pct')::int,100)) then
            begin perform wow_attack(tok, tgt.id, army); perform _wow_bot_log(p_id, 'attack', jsonb_build_object('target',tgt.id,'loss',(ev->>'loss_pct')::int)); fought := true; exception when others then null; end; exit;
          end if;
        end loop;
      end if;

      if not fought then
        for tgt in select th.node, th.kind from wow_thrones th
                    where th.kind in ('trono','fortaleza') and coalesce(th.holder,'') <> '' and th.holder <> p_id
                      and not exists (select 1 from wow_bots bb where bb.user_id = th.holder)
                      and (th.holder_ally is null or ua is null or th.holder_ally <> ua)
                      and _wow_target_attack_ok('trono', null, th.node, mypts)
                    order by random() limit 4 loop
          ev := _wow_bot_sim_node(p_id, tgt.node, army, fog);
          if coalesce(ev->>'ok','false')='true' and ev->>'win'='true' and _wow_bot_loss_ok(p_id, coalesce((ev->>'loss_pct')::int,100)) then
            begin perform wow_throne_attack(tok, tgt.node, army); perform _wow_bot_log(p_id, 'node_attack', jsonb_build_object('node',tgt.node,'kind',tgt.kind,'loss',(ev->>'loss_pct')::int)); fought := true; exception when others then null; end; exit;
          end if;
        end loop;
      end if;
    end if;
  end if;

  if random() < 0.35 then
    select th.node into node from wow_thrones th
      where th.holder = p_id or (ua is not null and th.holder_ally = ua)
      order by random() limit 1;
    if node is not null then begin perform wow_throne_claim(tok, node); exception when others then null; end; end if;
  end if;

  if lvl >= 6 and random() < 0.2 then
    select th.node into node from wow_thrones th
      where th.holder = p_id or (ua is not null and th.holder_ally = ua)
      order by random() limit 1;
    if node is not null then
      army := _wow_bot_army(p_id, 0.4);
      if army <> '{}'::jsonb then begin perform wow_throne_reinforce(tok, node, army); exception when others then null; end; end if;
    end if;
  end if;

  if random() < 0.12 then nx := ms + (30*60000 + (random()*90*60000)::bigint)::bigint;
  else nx := ms + (base*60000*(0.5 + random()))::bigint; end if;
  update wow_bots set next_ms = nx, last_act_ms = ms where user_id = p_id;
end $function$;
revoke all on function public._wow_bot_act(text) from public, anon, authenticated;
grant execute on function public._wow_bot_act(text) to anon, authenticated;

create or replace function public.wow_bots_tick(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare b record; ms bigint; n integer := 0;
begin
  perform _wow_resolve();
  if _wow_bot_auto() = 0 then return jsonb_build_object('ok', true, 'auto', false, 'acted', 0); end if;
  ms := (extract(epoch from now())*1000)::bigint;
  for b in select user_id from wow_bots where active and (p_force or next_ms <= ms) loop
    begin
      perform _wow_bot_act(b.user_id);
      n := n + 1;
    exception when others then
      update wow_bots set next_ms = ms + 600000 where user_id = b.user_id;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'auto', true, 'acted', n);
end $function$;
revoke all on function public.wow_bots_tick(boolean) from public, anon, authenticated;
grant execute on function public.wow_bots_tick(boolean) to anon, authenticated;
