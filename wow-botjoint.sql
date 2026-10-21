-- ================================================================
-- ATAQUES CONJUNTOS CON LOS REINOS AUTOMATICOS.
--   Los bots que pertenecen a una alianza:
--   - se unen a las convocatorias abiertas de su alianza aportando tropas
--   - convocan sus propios ataques conjuntos
--   - lanzan la convocatoria cuando ya hay aportes de otros miembros
--   Nada de esto los delata: escriben en el chat igual que un jugador
--   y su participacion solo queda registrada en una tabla privada
--   (wow_bot_joint_log), que los jugadores no pueden leer.
-- ================================================================

create table if not exists wow_bot_joint_log(
  id bigserial primary key,
  op_id bigint,
  user_id text,
  alliance text,
  action text,
  created bigint
);
revoke all on table public.wow_bot_joint_log from public, anon, authenticated;
revoke all on sequence public.wow_bot_joint_log_id_seq from public, anon, authenticated;

-- limpieza de los mensajes que delataban a los bots (una sola vez)
update wow_chat set msg = ltrim(msg, '🤖 ') where msg like '🤖 %';

create or replace function _wow_bot_joint(p_id text) returns void language plpgsql security definer set search_path to 'public' as $$

declare
  b wow_bots; ua text; ms bigint; cfg jsonb; op wow_joint_ops; res jsonb;
  army jsonb; tgt record; node integer; prot numeric; mypts numeric; agro integer;
  others integer; kind text; tgt_id text; nk text; tot integer;
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
  prot := _wow_protect_below();
  mypts := _wow_points(p_id);
  if op.id is not null then
    select count(*) into others from wow_joint_ops_troops t where t.op_id = op.id and t.owner <> p_id;
    if (others > 0 or op.created_ms < ms - 10800000)
       and _wow_target_attack_ok(op.target_kind, op.target_ref, op.target_node, prot, mypts) then
      begin
        perform wow_joint_launch(b.token, op.id);
        insert into wow_bot_joint_log(op_id, user_id, alliance, action, created) values (op.id, p_id, ua, 'launch', ms);
      exception when others then null;
      end;
    end if;
  end if;

  if not exists (select 1 from wow_joint_ops_troops t
                  where t.owner = p_id and t.op_id in (select id from wow_joint_ops where alliance = ua and status = 'open')) then
    select o.* into op from wow_joint_ops o
      where o.alliance = ua and o.status = 'open' and o.deadline_ms > ms + 1800000
        and not exists (select 1 from wow_joint_ops_troops t where t.op_id = o.id and t.owner = p_id)
      order by o.created_ms desc limit 1;
    if op.id is not null and random() < 0.45 + agro::numeric/250
       and _wow_target_attack_ok(op.target_kind, op.target_ref, op.target_node, prot, mypts) then
      army := _wow_bot_army(p_id, 0.5);
      if army <> '{}'::jsonb then
        begin
          perform wow_joint_join(b.token, op.id, army);
          insert into wow_bot_joint_log(op_id, user_id, alliance, action, created) values (op.id, p_id, ua, 'join', ms);
        exception when others then null;
        end;
      end if;
    end if;
  end if;

  if not exists (select 1 from wow_joint_ops where alliance = ua and status = 'open')
     and random() < (agro::numeric/100) * 0.35 then
    mypts := _wow_points(p_id);
    prot := _wow_protect_below();
    kind := null; tgt_id := null; node := null;
    if prot = 0 or mypts >= prot then
      select th.node, th.kind into node, nk from wow_thrones th
        where th.kind = 'aldea' and th.holder is distinct from p_id
          and (th.holder_ally is null or th.holder_ally <> ua)
          and coalesce((select sum((x.value)::int) from jsonb_each_text(th.garrison) x), 0) = 0
          and _wow_target_attack_ok('aldea', null, th.node, prot, mypts)
        order by random() limit 1;
      if node is not null then kind := 'aldea';
      else
        select th.node, th.kind into node, nk from wow_thrones th
          join wow_ally_wars wr on wr.active and (wr.a = ua or wr.b = ua)
            and th.holder_ally = case when wr.a = ua then wr.b else wr.a end
         where th.holder_ally is not null
           and _wow_target_attack_ok('trono', null, th.node, prot, mypts)
         order by random() limit 1;
        if node is not null then kind := nk;
        else
          select eu.id into tgt from wow_ally_wars wr
            join wow_users eu on eu.alliance = case when wr.a = ua then wr.b else wr.a end
            where wr.active and (wr.a = ua or wr.b = ua) and eu.active and not eu.is_admin and eu.id <> p_id
              and (prot = 0 or (_wow_points(eu.id) >= prot and mypts - _wow_points(eu.id) < prot))
            order by _wow_points(eu.id) asc, random() limit 1;
          if tgt.id is null then
            select w.id into tgt from wow_users w
              where w.active and not w.is_admin and w.id <> p_id
                and (ua is null or w.alliance is null or w.alliance <> ua)
                and (prot = 0 or (_wow_points(w.id) >= prot and mypts - _wow_points(w.id) < prot))
              order by _wow_points(w.id) asc, random() limit 1;
          end if;
          if tgt.id is not null then kind := 'reino'; tgt_id := tgt.id; end if;
        end if;
      end if;
    end if;
    if kind is not null then
      begin
        res := wow_joint_open(b.token, kind, tgt_id, node);
        if res is not null and res->>'id' is not null then
          insert into wow_bot_joint_log(op_id, user_id, alliance, action, created) values ((res->>'id')::bigint, p_id, ua, 'open', ms);
          army := _wow_bot_army(p_id, 0.5);
          if army <> '{}'::jsonb then
            perform wow_joint_join(b.token, (res->>'id')::bigint, army);
            insert into wow_bot_joint_log(op_id, user_id, alliance, action, created) values ((res->>'id')::bigint, p_id, ua, 'join', ms);
          end if;
        end if;
      exception when others then null;
      end;
    end if;
  end if;
end ;
$$;
revoke all on function public._wow_bot_joint(text) from public;

-- El tick de bots no puede resetear last_ms: los bots se quedaban sin ingresos.
drop function if exists public.wow_bots_tick(boolean);
create or replace function wow_bots_tick(p_force boolean default false) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare b record; ms bigint; n integer := 0; mx bigint;
begin
  perform _wow_resolve();
  if _wow_bot_auto() = 0 then return jsonb_build_object('ok', true, 'auto', false, 'acted', 0); end if;
  ms := (extract(epoch from now())*1000)::bigint;
  for b in select user_id, level from wow_bots where active and (p_force or next_ms <= ms) loop
    begin
      perform _wow_bot_act(b.user_id);
      perform _wow_bot_market(b.user_id);
      n := n + 1;
    exception when others then
      update wow_bots set next_ms = ms + 60000 where user_id = b.user_id;
    end;
    mx := ms + (((_wow_bot_level(b.level)->>'min')::int * 90000))::bigint;
    update wow_bots set next_ms = least(next_ms, mx) where user_id = b.user_id;
  end loop;
  return jsonb_build_object('ok', true, 'auto', true, 'acted', n);
end ;
$$;
revoke all on function public.wow_bots_tick(boolean) from public;
grant execute on function public.wow_bots_tick(boolean) to anon, authenticated;

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
    prot := _wow_protect_below();
    army := _wow_bot_army(p_id, 0.6);
    if army <> '{}'::jsonb and (prot = 0 or mypts >= prot) then
      select th.node into node from wow_thrones th
        where th.kind = 'aldea'
          and th.holder is distinct from p_id
          and (th.holder_ally is null or ua is null or th.holder_ally <> ua)
          and coalesce((select sum((x.value)::int) from jsonb_each_text(th.garrison) x), 0) = 0
          and _wow_target_attack_ok('aldea', null, th.node, prot, mypts)
        order by random() limit 1;
      if node is not null then
        begin perform wow_throne_attack(tok, node, army); exception when others then null; end;
      else
        if ua is not null then
          select th.node into node from wow_thrones th
            join wow_ally_wars wr on wr.active and (wr.a = ua or wr.b = ua)
              and th.holder_ally = case when wr.a = ua then wr.b else wr.a end
           where th.holder_ally is not null
             and _wow_target_attack_ok('trono', null, th.node, prot, mypts)
           order by random() limit 1;
          if node is not null then
            begin perform wow_throne_attack(tok, node, army); exception when others then null; end;
          end if;
        end if;
      end if;
      if node is null then
        prot := _wow_protect_below();
        tgt := null;
        if ua is not null then
          select eu.id into tgt from wow_ally_wars wr
            join wow_users eu on eu.alliance = case when wr.a = ua then wr.b else wr.a end
            where wr.active and (wr.a = ua or wr.b = ua)
              and eu.active and not eu.is_admin and eu.id <> p_id
              and (prot = 0 or (_wow_points(eu.id) >= prot and mypts - _wow_points(eu.id) < prot))
            order by _wow_points(eu.id) asc, random() limit 1;
        end if;
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

revoke all on function public._wow_bot_act(text) from public;
