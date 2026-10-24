CREATE OR REPLACE FUNCTION public._wow_bot_act(p_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if not exists (select 1 from wow_queue q0 where q0.owner_id = p_id and q0.kind = 'train') then
    select coalesce(max(level),0) into cuartel from wow_buildings where owner_id = p_id and bkey = 'cuartel';
    for tk in select v.t from (values ('dragon',1),('paladin',2),('mago',3),
                                      ('jinete',4),('arquero',5),('soldado',6)) v(t,ord)
               order by v.ord
    loop
      if cuartel >= _wow_treq(tk) then
        tc := _wow_tcost(tk);
        q := least(greatest(1, ((cfg->>'trp')::int) / 3),
                   greatest(1, floor(least(
                     coalesce((select gold from wow_users where id = p_id), 0) / nullif((tc->>'gold')::numeric, 0),
                     coalesce((select wood from wow_users where id = p_id), 0) / nullif((tc->>'wood')::numeric, 0),
                     coalesce((select ore  from wow_users where id = p_id), 0) / nullif((tc->>'ore')::numeric, 0)
                   )))::int);
        begin
          perform wow_train(tok, tk, q);
          exit;
        exception when others then exit;
        end;
      end if;
    end loop;
  end if;
  if not exists (select 1 from wow_queue q0 where q0.owner_id = p_id and q0.kind = 'build')
     and (select coalesce(sum(qty),0) from wow_troops where owner_id = p_id) >= 25 then
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
  if random()*100 < agro and (select coalesce(sum(qty),0) from wow_troops where owner_id = p_id) >= 20 then
    mypts := _wow_points(p_id);
    prot := _wow_protect_reino();
    fog := greatest(0.02, 0.16 - 0.02 * lvl);
    army := _wow_bot_army(p_id, 0.8);
    if army <> '{}'::jsonb and (prot = 0 or mypts >= prot) then
      fought := false;

      -- a) aldeas libres: botin facil y sin conflicto
      select th.node into node from wow_thrones th
        where th.kind = 'aldea'
          and coalesce(th.holder,'') = ''
          and _wow_target_attack_ok('aldea', null, th.node, mypts)
        order by random() limit 1;
      if node is not null then
        begin
          perform wow_throne_attack(tok, node, army);
          perform _wow_bot_log(p_id, 'node_attack', jsonb_build_object('node', node, 'kind', 'aldea', 'free', true));
          fought := true;
        exception when others then null; end;
      end if;

      -- b) espionaje ocasional (informacion imperfecta)
      if not fought and random()*100 < b.spy_rate and ms - b.scout_ms > 21600000 then
        select w.id into tgt_id from wow_users w
          where w.active and not w.is_admin and w.id <> p_id
            and not exists (select 1 from wow_bots bb where bb.user_id = w.id)
            and (ua is null or w.alliance is null or w.alliance <> ua)
            and _wow_target_attack_ok('reino', w.id, null, mypts)
          order by random() limit 1;
        if tgt_id is not null then
          begin
            perform wow_spy(tok, tgt_id);
            update wow_bots set scout_ms = ms where user_id = p_id;
          exception when others then null; end;
        end if;
      end if;

      -- c) reinos: solo con victoria simulada y bajas asumibles. Nunca bots ni aliados.
      if not fought then
        for tgt in
          select w.id as id from wow_users w
            where w.active and not w.is_admin and w.id <> p_id
              and not exists (select 1 from wow_bots bb where bb.user_id = w.id)
              and (ua is null or w.alliance is null or w.alliance <> ua)
              and _wow_target_attack_ok('reino', w.id, null, mypts)
            order by _wow_points(w.id) asc, random()
            limit 6
        loop
          ev := _wow_bot_sim_kingdom(p_id, tgt.id, army, false, fog);
          if coalesce(ev->>'ok','false') = 'true'
             and ev->>'win' = 'true'
             and _wow_bot_loss_ok(p_id, coalesce((ev->>'loss_pct')::int, 100)) then
            begin
              perform wow_attack(tok, tgt.id, army);
              perform _wow_bot_log(p_id, 'attack', jsonb_build_object('target', tgt.id, 'loss', (ev->>'loss_pct')::int));
              fought := true;
            exception when others then null; end;
            exit;
          end if;
        end loop;
      end if;

      -- d) plazas enemigas (tronos/fortalezas), nunca de bots ni aliados
      if not fought then
        for tgt in
          select th.node as node, th.kind as kind from wow_thrones th
            where th.kind in ('trono','fortaleza')
              and coalesce(th.holder,'') <> ''
              and th.holder <> p_id
              and not exists (select 1 from wow_bots bb where bb.user_id = th.holder)
              and (th.holder_ally is null or ua is null or th.holder_ally <> ua)
              and _wow_target_attack_ok('trono', null, th.node, mypts)
            order by random() limit 4
        loop
          ev := _wow_bot_sim_node(p_id, tgt.node, army, fog);
          if coalesce(ev->>'ok','false') = 'true'
             and ev->>'win' = 'true'
             and _wow_bot_loss_ok(p_id, coalesce((ev->>'loss_pct')::int, 100)) then
            begin
              perform wow_throne_attack(tok, tgt.node, army);
              perform _wow_bot_log(p_id, 'node_attack', jsonb_build_object('node', tgt.node, 'kind', tgt.kind, 'loss', (ev->>'loss_pct')::int));
              fought := true;
            exception when others then null; end;
            exit;
          end if;
        end loop;
      end if;
    end if;
  end if;
  if random() < 0.35 then
    select th.node into node from wow_thrones th
      where th.holder = p_id or (ua is not null and th.holder_ally = ua)
      order by random() limit 1;
    if node is not null then
      begin perform wow_throne_claim(tok, node); exception when others then null; end;
    end if;
  end if;
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
  if random() < 0.12 then
    nx := ms + (30*60000 + (random()*90*60000)::bigint)::bigint;   -- 30-120 min fuera
  else
    nx := ms + (base*60000*(0.5 + random()))::bigint;              -- 0.5x - 1.5x
  end if;
  update wow_bots set next_ms = nx, last_act_ms = ms where user_id = p_id;
end $function$;


-- wow_spy se habia quedado sin definir en v3: lo restauramos.
create or replace function public.wow_spy(p_token text, p_target text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_users; ms bigint; travel integer; cost numeric := 150;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  if p_target = u.id then raise exception 'No puedes espiar tu propio reino.'; end if;
  select * into t from wow_users where id = p_target and active;
  if t.id is null then raise exception 'Ese reino ya no existe.'; end if;
  if t.is_admin then raise exception 'No puedes espiar a un administrador.'; end if;
  if t.alliance is not null and t.alliance = u.alliance then
    raise exception 'No puedes espiar a un miembro de tu alianza.'; end if;
  if u.gold < cost then raise exception 'Necesitas % de oro para enviar un espía.', cost; end if;
  update wow_users set gold = gold - cost where id = u.id;
  travel := _wow_travel(u.pos, t.pos);
  ms := (extract(epoch from now())*1000)::bigint;
  insert into wow_fleets(attacker, target, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, t.id, '{}'::jsonb, '{}'::jsonb, 'outbound', 'spy', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'cost', cost, 'target', t.name);
end $$;
grant execute on function public.wow_spy(text, text) to anon, authenticated;
