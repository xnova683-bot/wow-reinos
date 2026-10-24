
create or replace function public._wow_joint_bot_safe(p_kind text, p_ref text, p_node integer)
returns boolean language plpgsql stable security definer set search_path to 'public' as $$
declare h text;
begin
  if p_kind = 'reino' then
    if p_ref is null then return false; end if;
    return not _wow_bot_is_bot(p_ref);
  end if;
  if p_node is null then return true; end if;
  select holder into h from wow_thrones where node = p_node;
  return not coalesce(_wow_bot_is_bot(h), false);
end $$;
revoke all on function public._wow_joint_bot_safe(text, text, integer) from public, anon, authenticated;

CREATE OR REPLACE FUNCTION public._wow_bot_joint(p_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  prot := _wow_protect_reino();
  mypts := _wow_points(p_id);
  if op.id is not null then
    select count(*) into others from wow_joint_ops_troops t where t.op_id = op.id and t.owner <> p_id;
    if (others > 0 or op.created_ms < ms - 10800000)
       and _wow_target_attack_ok(op.target_kind, op.target_ref, op.target_node, mypts)
       and _wow_joint_bot_safe(op.target_kind, op.target_ref, op.target_node) then
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
       and _wow_target_attack_ok(op.target_kind, op.target_ref, op.target_node, mypts)
       and _wow_joint_bot_safe(op.target_kind, op.target_ref, op.target_node) then
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
    prot := _wow_protect_reino();
    kind := null; tgt_id := null; node := null;
    if prot = 0 or mypts >= prot then
      select th.node, th.kind into node, nk from wow_thrones th
        where th.kind = 'aldea' and th.holder is distinct from p_id
          and (th.holder_ally is null or th.holder_ally <> ua)
          and not exists (select 1 from wow_bots bb where bb.user_id = th.holder)
          and coalesce((select sum((x.value)::int) from jsonb_each_text(th.garrison) x), 0) = 0
          and _wow_target_attack_ok('aldea', null, th.node, mypts)
        order by random() limit 1;
      if node is not null then kind := 'aldea';
      else
        select th.node, th.kind into node, nk from wow_thrones th
          join wow_ally_wars wr on wr.active and (wr.a = ua or wr.b = ua)
            and th.holder_ally = case when wr.a = ua then wr.b else wr.a end
         where th.holder_ally is not null
           and not exists (select 1 from wow_bots bb where bb.user_id = th.holder)
           and _wow_target_attack_ok('trono', null, th.node, mypts)
         order by random() limit 1;
        if node is not null then kind := nk;
        else
          select eu.id into tgt from wow_ally_wars wr
            join wow_users eu on eu.alliance = case when wr.a = ua then wr.b else wr.a end
            where wr.active and (wr.a = ua or wr.b = ua) and eu.active and not eu.is_admin and eu.id <> p_id
              and not exists (select 1 from wow_bots bb where bb.user_id = eu.id)
              and (prot = 0 or (_wow_points(eu.id) >= prot and mypts - _wow_points(eu.id) < prot))
            order by _wow_points(eu.id) asc, random() limit 1;
          if tgt.id is null then
            select w.id into tgt from wow_users w
              where w.active and not w.is_admin and w.id <> p_id
                and not exists (select 1 from wow_bots bb where bb.user_id = w.id)
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
$function$

