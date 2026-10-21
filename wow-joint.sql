-- ================================================================
-- ATAQUES CONJUNTOS DE ALIANZA.
--   - wow_joint_ops: convocatoria creada por un miembro de la alianza.
--   - wow_joint_ops_troops: tropas aportadas por cada miembro.
--   - wow_joint_ops_reports: informe de batalla para cada participante.
--   - Reglas: 24h de plazo, tropas no reservadas (se toman al lanzar),
--     una sola batalla con el ejercito unido, botin proporcional a las
--     tropas realmente aportadas y bonus de Madam por participante.
--   - _wow_sim (override): acepta bonus de ataque por tipo de tropa
--     (p_abt / p_dbt) para armies mixtas.
--   - _wow_resolve (override): flotas conjuntas, reparto al volver.
--   - _wow_throne_land (override): conquista de tronos/aldeas por la
--     alianza y reparto del tesoro del nodo.
-- ================================================================

create table if not exists wow_joint_ops (
  id bigserial primary key,
  alliance text not null,
  leader text not null,
  target_kind text not null,
  target_ref text,
  target_node integer,
  status text not null default 'open',
  deadline_ms bigint not null,
  created_ms bigint not null,
  launched_ms bigint default 0
);
create table if not exists wow_joint_ops_troops (
  op_id bigint not null references wow_joint_ops(id) on delete cascade,
  owner text not null,
  troops jsonb not null default '{}'::jsonb,
  joined_ms bigint not null,
  primary key (op_id, owner)
);
create table if not exists wow_joint_ops_reports (
  id bigserial primary key,
  op_id bigint not null references wow_joint_ops(id) on delete cascade,
  owner text not null,
  report jsonb not null,
  created bigint not null
);
create index if not exists wow_joint_ops_troops_op on wow_joint_ops_troops(op_id);
create index if not exists wow_joint_ops_reports_op on wow_joint_ops_reports(op_id);
alter table wow_fleets add column if not exists joint_op bigint;

create or replace function _wow_joint_weight(p_troops jsonb) returns numeric language plpgsql security definer set search_path to 'public' as $$

declare z record; w numeric := 0;
begin
  if p_troops is null or jsonb_typeof(p_troops) <> 'object' then return 0; end if;
  for z in select key, value from jsonb_each_text(p_troops) loop
    w := w + coalesce((z.value)::numeric,0);
  end loop;
  return greatest(w,0);
end ;
$$;
revoke all on function public._wow_joint_weight(jsonb) from public;

create or replace function _wow_joint_tlabel(p_troops jsonb) returns text language plpgsql security definer set search_path to 'public' as $$

declare z record; parts text[] := '{}'; nm text;
begin
  for z in select key, value from jsonb_each_text(p_troops) order by key loop
    if coalesce((z.value)::numeric,0) <= 0 then continue; end if;
    nm := case z.key
      when 'soldado' then 'soldados' when 'arquero' then 'arqueros'
      when 'jinete' then 'jinetes' when 'mago' then 'magos'
      when 'paladin' then 'paladines' when 'dragon' then 'dragones'
      else z.key end;
    parts := parts || (trunc((z.value)::numeric)::int || ' ' || nm);
  end loop;
  if array_length(parts,1) is null then return 'tropas'; end if;
  return array_to_string(parts, ', ');
end ;
$$;
revoke all on function public._wow_joint_tlabel(jsonb) from public;

create or replace function _wow_joint_stats(p_op bigint) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare
  tkeys text[] := array['soldado','arquero','jinete','mago','paladin','dragon'];
  bnum numeric[] := array[0,0,0,0,0,0];
  btot numeric[] := array[0,0,0,0,0,0];
  res numeric[] := array[0,0,0,0,0,0];
  i integer; q numeric; n numeric; tot numeric := 0;
  wm numeric := 0; wt numeric := 0;
  r record;
begin
  if p_op is null then return null; end if;
  for r in select o.owner, o.troops,
      (1 + 0.04*coalesce((select max(level) from wow_buildings b where b.owner_id = o.owner and bkey = 'herreria'),0)) mg,
      (1 + 0.04*coalesce((select max(level) from wow_buildings b where b.owner_id = o.owner and bkey = 'fortaleza'),0)) ft
    from wow_joint_ops_troops o where o.op_id = p_op loop
    n := 0;
    for i in 1..6 loop
      q := coalesce((r.troops->>tkeys[i])::numeric,0);
      n := n + q;
      bnum[i] := bnum[i] + q * _wow_madam_bonus(r.owner);
      btot[i] := btot[i] + q;
    end loop;
    tot := tot + n;
    wm := wm + n * r.mg;
    wt := wt + n * r.ft;
  end loop;
  if tot <= 0 then
    return jsonb_build_object('might',1,'tough',1,'bonus',res,'total',0);
  end if;
  for i in 1..6 loop
    if btot[i] > 0 then res[i] := bnum[i]/btot[i]; end if;
  end loop;
  return jsonb_build_object(
    'might', round(wm/tot, 4),
    'tough', round(wt/tot, 4),
    'bonus', res,
    'total', tot);
end ;
$$;
revoke all on function public._wow_joint_stats(bigint) from public;

create or replace function _wow_joint_bonus(p_op bigint) returns numeric[] language plpgsql security definer set search_path to 'public' as $$

declare
  tkeys text[] := array['soldado','arquero','jinete','mago','paladin','dragon'];
  bnum numeric[] := array[0,0,0,0,0,0];
  btot numeric[] := array[0,0,0,0,0,0];
  res numeric[] := array[0,0,0,0,0,0];
  i integer; r record; q numeric;
begin
  if p_op is null then return null; end if;
  for r in select o.owner, o.troops from wow_joint_ops_troops o where o.op_id = p_op loop
    for i in 1..6 loop
      q := coalesce((r.troops->>tkeys[i])::numeric,0);
      bnum[i] := bnum[i] + q * _wow_madam_bonus(r.owner);
      btot[i] := btot[i] + q;
    end loop;
  end loop;
  for i in 1..6 loop
    if btot[i] > 0 then res[i] := bnum[i]/btot[i]; end if;
  end loop;
  return res;
end ;
$$;
revoke all on function public._wow_joint_bonus(bigint) from public;

create or replace function _wow_joint_split(p_op bigint, p_troops jsonb, p_loot jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare
  tkeys text[] := array['soldado','arquero','jinete','mago','paladin','dragon'];
  lkeys text[] := array['gold','wood','ore','cup'];
  owners text[]; troops_arr jsonb[];
  tw numeric[]; totw numeric[]; acc jsonb[]; sh numeric[];
  n integer; sumw numeric := 0; wsum numeric := 0; best integer; k integer; i integer;
  q numeric; rem numeric; cents numeric; idx integer; res jsonb := '[]'::jsonb;
begin
  if p_op is null then return '[]'::jsonb; end if;
  select array_agg(z.owner), array_agg(z.tr) into owners, troops_arr
    from (select o.owner, o.troops tr from wow_joint_ops_troops o where o.op_id = p_op order by o.owner) z;
  n := coalesce(array_length(owners,1),0);
  if n = 0 then return '[]'::jsonb; end if;
  tw := array_fill(0::numeric, array[n*6]);
  totw := array_fill(0::numeric, array[n]);
  for i in 1..n loop
    for k in 1..6 loop
      tw[(i-1)*6+k] := coalesce((troops_arr[i]->>tkeys[k])::numeric,0);
    end loop;
    for k in 1..6 loop totw[i] := totw[i] + tw[(i-1)*6+k]; end loop;
    sumw := sumw + totw[i];
  end loop;
  if sumw <= 0 then return '[]'::jsonb; end if;
  acc := array_fill('{"troops":{},"loot":{}}'::jsonb, array[n]);
  for k in 1..6 loop
    q := coalesce((p_troops->>tkeys[k])::numeric,0);
    if q > 0 then
      wsum := 0;
      for i in 1..n loop wsum := wsum + tw[(i-1)*6+k]; end loop;
      if wsum > 0 then
        sh := array_fill(0::numeric, array[n]);
        rem := q;
        for i in 1..n loop sh[i] := floor(q*tw[(i-1)*6+k]/wsum); rem := rem - sh[i]; end loop;
        best := 1;
        for i in 1..n loop if tw[(i-1)*6+k] > tw[(best-1)*6+k] then best := i; end if; end loop;
        sh[best] := sh[best] + rem;
        for i in 1..n loop
          if sh[i] > 0 then
            acc[i] := jsonb_set(acc[i], '{troops}',
              (acc[i]->'troops') || jsonb_build_object(tkeys[k], trunc(sh[i])::int), true);
          end if;
        end loop;
      end if;
    end if;
  end loop;
  for k in 1..4 loop
    q := coalesce((p_loot->>lkeys[k])::numeric,0);
    if q > 0 then
      sh := array_fill(0::numeric, array[n]);
      rem := q;
      for i in 1..n loop sh[i] := round(q*totw[i]/sumw, 2); rem := rem - sh[i]; end loop;
      cents := trunc(round(rem*100));
      idx := 1;
      while cents > 0 loop
        sh[idx] := sh[idx] + 0.01;
        cents := cents - 1;
        idx := idx + 1;
        if idx > n then idx := 1; end if;
      end loop;
      for i in 1..n loop
        if sh[i] > 0 then
          acc[i] := jsonb_set(acc[i], '{loot}',
            (acc[i]->'loot') || jsonb_build_object(lkeys[k], sh[i]), true);
        end if;
      end loop;
    end if;
  end loop;
  for i in 1..n loop
    res := res || jsonb_build_object(
      'owner', owners[i],
      'troops', acc[i]->'troops',
      'loot', acc[i]->'loot',
      'w', totw[i],
      'pct', round(totw[i]*100/sumw, 2));
  end loop;
  return res;
end ;
$$;
revoke all on function public._wow_joint_split(bigint,jsonb,jsonb) from public;

drop function if exists public._wow_joint_pay(bigint,jsonb,jsonb,text,boolean,text);
create or replace function _wow_joint_pay(p_op bigint, p_troops jsonb, p_loot jsonb, p_dir text, p_win boolean, p_who text, p_battle jsonb default null) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare
  parts jsonb; r record; z record; ms bigint; nm text;
  troops jsonb; loot jsonb; btl jsonb;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  parts := _wow_joint_split(p_op, p_troops, p_loot);
  for r in select * from jsonb_array_elements(parts) loop
    troops := r.value->'troops';
    loot := r.value->'loot';
    for z in select key, value from jsonb_each_text(troops) loop
      insert into wow_troops(owner_id, tkey, qty) values (r.value->>'owner', z.key, (z.value)::int)
        on conflict (owner_id, tkey) do update set qty = wow_troops.qty + excluded.qty;
    end loop;
    update wow_users set
        gold = least(gold + coalesce((loot->>'gold')::numeric,0), _wow_cap(r.value->>'owner')),
        wood = least(wood + coalesce((loot->>'wood')::numeric,0), _wow_cap(r.value->>'owner')),
        ore  = least(ore  + coalesce((loot->>'ore')::numeric,0), _wow_cap(r.value->>'owner')),
        cup  = coalesce(cup,0) + coalesce((loot->>'cup')::numeric,0)
      where id = r.value->>'owner';
    select name into nm from wow_users where id = r.value->>'owner';
    btl := case when p_battle is null then '{}'::jsonb else jsonb_build_object('battle', p_battle) end;
    if p_dir = 'return' then
      insert into wow_reports(owner, kind, data, created) values
        (r.value->>'owner','return', jsonb_build_object('dir','return','who',coalesce(nm,''),'win',true,
          'loot',loot,'troops',troops,'joint',true,'pct',r.value->'pct','created',ms) || btl, ms);
    else
      insert into wow_reports(owner, kind, data, created) values
        (r.value->>'owner','out', jsonb_build_object('dir','throne','who',coalesce(p_who,''),'win',p_win,
          'loot',loot,'joint',true,'pct',r.value->'pct','created',ms) || btl, ms);
    end if;
    insert into wow_joint_ops_reports(op_id, owner, report, created) values
      (p_op, r.value->>'owner', jsonb_build_object('dir',p_dir,'win',p_win,'loot',loot,
        'troops',troops,'pct',r.value->'pct','created',ms) || btl, ms);
  end loop;
  return parts;
end ;
$$;
revoke all on function public._wow_joint_pay(bigint,jsonb,jsonb,text,boolean,text,jsonb) from public;

create or replace function _wow_joint_settle(p_op bigint, p_troops jsonb, p_loot jsonb) returns void language plpgsql security definer set search_path to 'public' as $$

declare parts jsonb;
begin
  parts := _wow_joint_pay(p_op, p_troops, p_loot, 'return', true, '');
  update wow_joint_ops set status = 'done' where id = p_op;
end ;
$$;
revoke all on function public._wow_joint_settle(bigint,jsonb,jsonb) from public;

create or replace function _wow_joint_throne_loot(p_op bigint, p_node integer, p_node_name text, p_sim jsonb, p_win boolean) returns void language plpgsql security definer set search_path to 'public' as $$

declare ms bigint; tres jsonb := '{}'::jsonb; r record;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  if p_win then
    for r in select key, qty from wow_throne_treasure where node = p_node and qty > 0 for update loop
      tres := tres || jsonb_build_object(r.key, r.qty);
    end loop;
    if tres <> '{}'::jsonb then delete from wow_throne_treasure where node = p_node; end if;
  end if;
  perform _wow_joint_pay(p_op, '{}'::jsonb, tres, 'throne', p_win, coalesce(p_node_name,''), p_sim);
end ;
$$;
revoke all on function public._wow_joint_throne_loot(bigint,integer,text,jsonb,boolean) from public;

create or replace function wow_joint_open(p_token text, p_target_kind text, p_target text, p_node integer) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare u wow_users; t wow_users; th wow_thrones; ms bigint; op_id bigint; tk text; tn text;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'Necesitas una alianza para convocar un ataque conjunto.'; end if;
  tk := lower(coalesce(p_target_kind,''));
  if tk not in ('reino','trono','aldea') then raise exception 'Objetivo inválido.'; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  if tk = 'reino' then
    if p_target is null or coalesce(p_target,'') = '' then raise exception 'Elige el reino objetivo.'; end if;
    select * into t from wow_users where id = p_target and active;
    if t.id is null then raise exception 'Ese reino ya no existe.'; end if;
    if t.id = u.id then raise exception 'No puedes atacarte a ti mismo.'; end if;
    if t.is_admin then raise exception 'No puedes atacar a un administrador.'; end if;
    if t.alliance is not null and t.alliance = u.alliance then raise exception 'No puedes atacar a un miembro de tu propia alianza.'; end if;
    tn := t.name;
  else
    select * into th from wow_thrones where node = p_node;
    if th.node is null then raise exception 'Ese lugar no existe.'; end if;
    if th.holder_ally is not null and th.holder_ally = u.alliance then raise exception 'Ese lugar ya es de tu alianza.'; end if;
    tn := th.name;
  end if;
  insert into wow_joint_ops(alliance, leader, target_kind, target_ref, target_node, status, deadline_ms, created_ms)
    values (u.alliance, u.id, tk,
      case when tk = 'reino' then p_target else null end,
      case when tk = 'reino' then null else p_node end,
      'open', ms + 86400000, ms)
    returning id into op_id;
  insert into wow_chat(alliance, user_id, name, msg, created)
    values (u.alliance, u.id, u.name,
      '⚔️ ' || u.name || ' ha convocado un ataque conjunto contra ' || tn || '. ¡Aportad vuestras tropas!', ms);
  return jsonb_build_object('ok',true,'id',op_id,'target',tn,'deadline',ms + 86400000);
end ;
$$;
revoke all on function public.wow_joint_open(text,text,text,integer) from public;
grant execute on function public.wow_joint_open(text,text,text,integer) to anon, authenticated;

create or replace function wow_joint_join(p_token text, p_op bigint, p_troops jsonb) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare u wow_users; op wow_joint_ops; ms bigint; army jsonb; z record; avail int;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  select * into op from wow_joint_ops where id = p_op;
  if op.id is null then raise exception 'Esa convocatoria no existe.'; end if;
  if op.status <> 'open' then raise exception 'Esta convocatoria ya no está abierta.'; end if;
  if op.deadline_ms <= ms then
    update wow_joint_ops set status = 'expired' where id = op.id and status = 'open';
    raise exception 'La convocatoria ha caducado.';
  end if;
  if u.alliance is null or u.alliance <> op.alliance then raise exception 'Solo los miembros de la alianza pueden aportar tropas.'; end if;
  army := _wow_throne_check(p_troops);
  for z in select key, value::int from jsonb_each_text(army) loop
    select coalesce(qty,0) into avail from wow_troops where owner_id = u.id and tkey = z.key;
    if avail < z.value then raise exception 'No tienes suficientes tropas de ese tipo.'; end if;
  end loop;
  insert into wow_joint_ops_troops(op_id, owner, troops, joined_ms) values (op.id, u.id, army, ms)
    on conflict (op_id, owner) do update set troops = excluded.troops, joined_ms = excluded.joined_ms;
  insert into wow_chat(alliance, user_id, name, msg, created)
    values (op.alliance, u.id, u.name, '🛡️ ' || u.name || ' aporta ' || _wow_joint_tlabel(army) || ' al ataque conjunto.', ms);
  return jsonb_build_object('ok',true,'troops',army);
end ;
$$;
revoke all on function public.wow_joint_join(text,bigint,jsonb) from public;
grant execute on function public.wow_joint_join(text,bigint,jsonb) to anon, authenticated;

create or replace function wow_joint_leave(p_token text, p_op bigint) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare u wow_users; op wow_joint_ops;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select * into op from wow_joint_ops where id = p_op;
  if op.id is null then raise exception 'Esa convocatoria no existe.'; end if;
  if op.status <> 'open' then raise exception 'Esta convocatoria ya no está abierta.'; end if;
  delete from wow_joint_ops_troops where op_id = op.id and owner = u.id;
  return jsonb_build_object('ok',true);
end ;
$$;
revoke all on function public.wow_joint_leave(text,bigint) from public;
grant execute on function public.wow_joint_leave(text,bigint) to anon, authenticated;

create or replace function wow_joint_cancel(p_token text, p_op bigint) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare u wow_users; op wow_joint_ops;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select * into op from wow_joint_ops where id = p_op;
  if op.id is null then raise exception 'Esa convocatoria no existe.'; end if;
  if op.leader <> u.id then raise exception 'Solo quien ha convocado puede cancelar.'; end if;
  if op.status <> 'open' then raise exception 'Esta convocatoria ya no está abierta.'; end if;
  update wow_joint_ops set status = 'cancelled' where id = op.id;
  insert into wow_chat(alliance, user_id, name, msg, created)
    values (op.alliance, u.id, u.name, '⚔️ ' || u.name || ' ha cancelado el ataque conjunto.', (extract(epoch from now())*1000)::bigint);
  return jsonb_build_object('ok',true);
end ;
$$;
revoke all on function public.wow_joint_cancel(text,bigint) from public;
grant execute on function public.wow_joint_cancel(text,bigint) to anon, authenticated;

create or replace function wow_joint_launch(p_token text, p_op bigint) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare
  u wow_users; op wow_joint_ops; t wow_users; th wow_thrones;
  ms bigint; z record; e record;
  sent jsonb; actual jsonb := '{}'::jsonb; comb jsonb := '{}'::jsonb;
  travel integer; avail int; take int; protect numeric; got boolean := false;
  tname text; lab text;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select * into op from wow_joint_ops where id = p_op for update;
  if op.id is null then raise exception 'Esa convocatoria no existe.'; end if;
  if op.leader <> u.id then raise exception 'Solo quien ha convocado puede lanzar el ataque.'; end if;
  if op.status <> 'open' then raise exception 'Esta convocatoria ya no está abierta.'; end if;
  if op.deadline_ms <= ms then
    update wow_joint_ops set status = 'expired' where id = op.id and status = 'open';
    raise exception 'La convocatoria ha caducado.';
  end if;
  if op.target_kind = 'reino' then
    select * into t from wow_users where id = op.target_ref and active;
    if t.id is null then raise exception 'Ese reino ya no existe.'; end if;
    if t.is_admin then raise exception 'No puedes atacar a un administrador.'; end if;
    protect := _wow_protect_below();
    if protect > 0 then
      if _wow_points(t.id) < protect then
        raise exception 'Ese reino está protegido por ser novato (menos de % puntos).', trunc(protect)::int; end if;
      if not u.is_admin and _wow_points(u.id) < protect then
        raise exception 'Estás en protección de novatos: no puedes atacar hasta superar % puntos.', trunc(protect)::int; end if;
      if not u.is_admin and (_wow_points(u.id) - _wow_points(t.id)) >= protect then
        raise exception 'No puedes atacar a un reino mucho más débil: la diferencia de puntos no puede llegar a %.', trunc(protect)::int; end if;
    end if;
    if t.alliance is not null and t.alliance = u.alliance then raise exception 'No puedes atacar a un miembro de tu propia alianza.'; end if;
  else
    select * into th from wow_thrones where node = op.target_node for update;
    if th.node is null then raise exception 'Ese lugar ya no existe.'; end if;
    if th.holder_ally is not null and th.holder_ally = u.alliance then raise exception 'Ese lugar ya es de tu alianza.'; end if;
  end if;
  for e in select o.owner, o.troops from wow_joint_ops_troops o where o.op_id = op.id order by o.owner loop
    perform _wow_tick(e.owner);
    sent := '{}'::jsonb;
    for z in select key, value::int from jsonb_each_text(e.troops) order by key loop
      if z.value <= 0 then continue; end if;
      select coalesce(qty,0) into avail from wow_troops where owner_id = e.owner and tkey = z.key;
      take := least(z.value, avail);
      if take > 0 then
        update wow_troops set qty = qty - take where owner_id = e.owner and tkey = z.key;
        sent := sent || jsonb_build_object(z.key, take);
        comb := comb || jsonb_build_object(z.key, coalesce((comb->>z.key)::int,0) + take);
        got := true;
      end if;
    end loop;
    actual := actual || jsonb_build_object(e.owner, sent);
    update wow_joint_ops_troops set troops = sent where op_id = op.id and owner = e.owner;
  end loop;
  if not got then raise exception 'No hay tropas disponibles para lanzar el ataque.'; end if;
  if op.target_kind = 'reino' then
    travel := _wow_travel(u.pos, t.pos);
    insert into wow_fleets(attacker, target, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms, joint_op)
      values (u.id, t.id, comb, '{}'::jsonb, 'outbound', 'attack', ms, ms + travel*1000, ms, op.id);
    tname := t.name;
  else
    travel := _wow_travel_node(u.pos, th.node);
    insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms, joint_op)
      values (u.id, '', th.node, comb, '{}'::jsonb, 'outbound', 'throne_atk', ms, ms + travel*1000, ms, op.id);
    tname := th.name;
  end if;
  update wow_joint_ops set status = 'launched', launched_ms = ms where id = op.id;
  lab := _wow_ally_label(op.alliance);
  perform _wow_event('alliance', '⚔️ Ataque conjunto de ' || coalesce(nullif(lab,''),'una alianza') || ' contra ' || tname || '.');
  insert into wow_chat(alliance, user_id, name, msg, created)
    values (op.alliance, u.id, u.name,
      '⚔️ ' || u.name || ' ha lanzado el ataque conjunto contra ' || tname || ' con ' || _wow_joint_tlabel(comb) || '.', ms);
  return jsonb_build_object('ok',true,'travel',travel,'arrive',ms + travel*1000,'target',tname,'troops',comb,'parts',actual);
end ;
$$;
revoke all on function public.wow_joint_launch(text,bigint) from public;
grant execute on function public.wow_joint_launch(text,bigint) to anon, authenticated;

create or replace function wow_joint_list(p_token text) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare u wow_users; ms bigint; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', o.id, 'status', o.status, 'leader', o.leader,
      'leader_name', coalesce((select name from wow_users where id = o.leader),''),
      'target_kind', o.target_kind, 'target_ref', o.target_ref, 'target_node', o.target_node,
      'target_name', coalesce((select name from wow_users where id = o.target_ref),(select name from wow_thrones where node = o.target_node),''),
      'deadline', o.deadline_ms, 'created', o.created_ms, 'launched', o.launched_ms,
      'expired', (o.status = 'open' and o.deadline_ms <= ms),
      'parts', coalesce((select jsonb_agg(jsonb_build_object('owner',jt.owner,'name',coalesce(ju.name,''),
            'troops',jt.troops,'total',_wow_joint_weight(jt.troops)) order by _wow_joint_weight(jt.troops) desc, jt.owner)
          from wow_joint_ops_troops jt join wow_users ju on ju.id = jt.owner where jt.op_id = o.id),'[]'),
      'total', coalesce((select sum(_wow_joint_weight(jt.troops)) from wow_joint_ops_troops jt where jt.op_id = o.id),0)
    ) order by o.created_ms desc), '[]')
  into out
  from wow_joint_ops o
  where o.alliance = u.alliance and o.created_ms > ms - 7*86400000;
  return out;
end ;
$$;
revoke all on function public.wow_joint_list(text) from public;
grant execute on function public.wow_joint_list(text) to anon, authenticated;

create or replace function wow_joint_info(p_token text, p_op bigint) returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare u wow_users; op wow_joint_ops; ms bigint; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  select * into op from wow_joint_ops where id = p_op;
  if op.id is null then raise exception 'Esa convocatoria no existe.'; end if;
  if u.alliance is null or u.alliance <> op.alliance then raise exception 'No tienes acceso a esa convocatoria.'; end if;
  select jsonb_build_object(
    'id', op.id, 'status', op.status, 'leader', op.leader,
    'leader_name', coalesce((select name from wow_users where id = op.leader),''),
    'alliance', op.alliance,
    'target_kind', op.target_kind, 'target_ref', op.target_ref, 'target_node', op.target_node,
    'target_name', coalesce((select name from wow_users where id = op.target_ref),(select name from wow_thrones where node = op.target_node),''),
    'deadline', op.deadline_ms, 'created', op.created_ms, 'launched', op.launched_ms,
    'expired', (op.status = 'open' and op.deadline_ms <= ms),
    'parts', coalesce((select jsonb_agg(jsonb_build_object('owner',jt.owner,'name',coalesce(ju.name,''),
          'troops',jt.troops,'total',_wow_joint_weight(jt.troops)) order by _wow_joint_weight(jt.troops) desc, jt.owner)
        from wow_joint_ops_troops jt join wow_users ju on ju.id = jt.owner where jt.op_id = op.id),'[]'),
    'total', coalesce((select sum(_wow_joint_weight(jt.troops)) from wow_joint_ops_troops jt where jt.op_id = op.id),0),
    'reports', coalesce((select jsonb_agg(jsonb_build_object('owner',jr.owner,'name',coalesce(ju.name,''),
          'report',jr.report,'created',jr.created) order by jr.created)
        from wow_joint_ops_reports jr join wow_users ju on ju.id = jr.owner where jr.op_id = op.id),'[]')
  ) into out;
  return out;
end ;
$$;
revoke all on function public.wow_joint_info(text,bigint) from public;
grant execute on function public.wow_joint_info(text,bigint) to anon, authenticated;

-- ------------------------------------------------------------
-- _wow_sim: se reemplaza la version de 10 argumentos por una de 12
-- para poder aplicar un bonus de ataque distinto por tipo de tropa.
-- ------------------------------------------------------------
drop function if exists _wow_sim(jsonb,jsonb,integer,bigint,numeric,numeric,numeric,numeric,numeric,numeric);
create or replace function _wow_sim(p_att jsonb, p_def jsonb, p_wall integer, p_seed bigint,
  p_amight numeric default 1, p_dmight numeric default 1, p_atough numeric default 1, p_dtough numeric default 1,
  p_abonus numeric default 0, p_dbonus numeric default 0, p_abt numeric[] default null, p_dbt numeric[] default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$

declare
  keys text[] := array['soldado','arquero','jinete','mago','paladin','dragon'];
  hpA  numeric[] := array[12,8,16,7,26,34];
  atkA numeric[] := array[10,15,20,26,24,44];
  aq numeric[]; dq numeric[]; aPre numeric[]; dPre numeric[];
  aInit numeric[]; dInit numeric[]; aCas numeric[]; dCas numeric[];
  aHP numeric[]; dHP numeric[];
  i integer; j integer; r integer; maxR integer := 20;
  aHPtot numeric; dHPtot numeric; aTot0 numeric; dTot0 numeric;
  beforeA numeric; beforeD numeric; afterA numeric; afterD numeric;
  lossA numeric; lossD numeric;
  morA numeric := 100; morD numeric := 100;
  rounds jsonb := '[]'::jsonb;
  wallF numeric; dmgn numeric;
  dmgK numeric := 0.16;
  mightA numeric := greatest(coalesce(p_amight,1),0.1);
  mightD numeric := greatest(coalesce(p_dmight,1),0.1);
  toughA numeric := greatest(coalesce(p_atough,1),0.1);
  toughD numeric := greatest(coalesce(p_dtough,1),0.1);
  noiseA numeric; noiseD numeric;
  abon numeric := greatest(coalesce(p_abonus,0),0);
  dbon numeric := greatest(coalesce(p_dbonus,0),0);
  abt numeric[] := p_abt;
  dbt numeric[] := p_dbt;
  routA boolean := false; routD boolean := false;
  winner text; rout text := null;
  astart jsonb := '{}'::jsonb; dstart jsonb := '{}'::jsonb;
  aleft jsonb := '{}'::jsonb; dleft jsonb := '{}'::jsonb;
  aloss jsonb := '{}'::jsonb; dloss jsonb := '{}'::jsonb;
begin
  wallF := 1 - least(0.5, greatest(coalesce(p_wall,0),0) * 0.07);
  aTot0 := 0; dTot0 := 0;
  for i in 1..6 loop
    aq[i] := greatest(coalesce((p_att->>keys[i])::numeric,0),0);
    dq[i] := greatest(coalesce((p_def->>keys[i])::numeric,0),0);
    aInit[i] := aq[i]; dInit[i] := dq[i];
    aCas[i] := 0; dCas[i] := 0;
    aTot0 := aTot0 + aInit[i]; dTot0 := dTot0 + dInit[i];
  end loop;
  for r in 1..maxR loop
    for i in 1..6 loop aPre[i] := aq[i]; dPre[i] := dq[i]; end loop;
    aHPtot := 0; dHPtot := 0;
    for i in 1..6 loop
      aHP[i] := aPre[i]*hpA[i]; dHP[i] := dPre[i]*hpA[i];
      aHPtot := aHPtot + aHP[i]; dHPtot := dHPtot + dHP[i];
    end loop;
    exit when aHPtot <= 0 or dHPtot <= 0;
    beforeA := 0; beforeD := 0;
    for i in 1..6 loop beforeA := beforeA + aPre[i]; beforeD := beforeD + dPre[i]; end loop;
    noiseA := _wow_noise(p_seed, r*2);
    noiseD := _wow_noise(p_seed, r*2+1);
    for i in 1..6 loop
      dmgn := 0;
      for j in 1..6 loop
        dmgn := dmgn + (dPre[j]*(atkA[j]+coalesce(dbt[j], dbon))) * _wow_counter(keys[j], keys[i]) * (aHP[i]/greatest(aHPtot,1));
      end loop;
      dmgn := dmgn * dmgK * (1 + noiseD*0.2) * mightD / toughA;
      if dmgn > 0 then aCas[i] := aCas[i] + dmgn/hpA[i]; end if;
      aq[i] := greatest(aInit[i] - floor(aCas[i]), 0);
    end loop;
    for j in 1..6 loop
      dmgn := 0;
      for i in 1..6 loop
        dmgn := dmgn + (aPre[i]*(atkA[i]+coalesce(abt[i], abon))) * _wow_counter(keys[i], keys[j]) * (dHP[j]/greatest(dHPtot,1));
      end loop;
      dmgn := dmgn * dmgK * wallF * (1 + noiseA*0.2) * mightA / toughD;
      if dmgn > 0 then dCas[j] := dCas[j] + dmgn/hpA[j]; end if;
      dq[j] := greatest(dInit[j] - floor(dCas[j]), 0);
    end loop;
    afterA := 0; afterD := 0;
    for i in 1..6 loop afterA := afterA + aq[i]; afterD := afterD + dq[i]; end loop;
    lossA := beforeA - afterA; lossD := beforeD - afterD;
    morA := 100 * afterA / greatest(aTot0,1) + (lossD/greatest(beforeD,1) - lossA/greatest(beforeA,1))*20;
    morD := 100 * afterD / greatest(dTot0,1) + (lossA/greatest(beforeA,1) - lossD/greatest(beforeD,1))*20;
    morA := greatest(0, least(100, morA));
    morD := greatest(0, least(100, morD));
    rounds := rounds || jsonb_build_object('r',r,'aLoss',round(lossA),'dLoss',round(lossD),
                 'aLeft',round(afterA),'dLeft',round(afterD),'aMor',round(morA),'dMor',round(morD));
    exit when afterA <= 0 or afterD <= 0;
    if morA <= 15 then routA := true; end if;
    if morD <= 15 then routD := true; end if;
    exit when routA or routD;
  end loop;
  afterA := 0; afterD := 0;
  for i in 1..6 loop afterA := afterA + aq[i]; afterD := afterD + dq[i]; end loop;
  if routD and not routA then winner := 'attacker';
  elsif routA and not routD then winner := 'defender';
  elsif routA and routD then
    if morA > morD then winner := 'attacker'; else winner := 'defender'; end if;
  elsif afterD <= 0 and afterA > 0 then winner := 'attacker';
  elsif afterA <= 0 and afterD > 0 then winner := 'defender';
  elsif (afterA/greatest(aTot0,1)) > (afterD/greatest(dTot0,1)) then winner := 'attacker';
  else winner := 'defender'; end if;
  rout := null;
  if routA and routD then rout := 'both';
  elsif routA then rout := 'attacker';
  elsif routD then rout := 'defender';
  end if;
  if winner = 'attacker' and routD then
    for j in 1..6 loop dCas[j] := dCas[j] + dq[j]*0.5; dq[j] := greatest(dInit[j]-floor(dCas[j]),0); end loop;
  elsif winner = 'defender' and routA then
    for i in 1..6 loop aCas[i] := aCas[i] + aq[i]*0.5; aq[i] := greatest(aInit[i]-floor(aCas[i]),0); end loop;
  end if;
  for i in 1..6 loop
    astart := astart || jsonb_build_object(keys[i], floor(aInit[i]));
    dstart := dstart || jsonb_build_object(keys[i], floor(dInit[i]));
    aleft  := aleft  || jsonb_build_object(keys[i], floor(aq[i]));
    dleft  := dleft  || jsonb_build_object(keys[i], floor(dq[i]));
    aloss  := aloss  || jsonb_build_object(keys[i], floor(aInit[i])-floor(aq[i]));
    dloss  := dloss  || jsonb_build_object(keys[i], floor(dInit[i])-floor(dq[i]));
  end loop;
  return jsonb_build_object('winner',winner,'rout',rout,'rounds',rounds,
    'a_start',astart,'d_start',dstart,'a_left',aleft,'d_left',dleft,'a_loss',aloss,'d_loss',dloss,
    'a_morale',round(morA),'d_morale',round(morD));
end ;
$fn$;
revoke all on function public._wow_sim(jsonb,jsonb,integer,bigint,numeric,numeric,numeric,numeric,numeric,numeric,numeric[],numeric[]) from public;

-- ------------------------------------------------------------
-- _wow_resolve con soporte de flotas conjuntas.
-- ------------------------------------------------------------
create or replace function _wow_resolve() returns void language plpgsql security definer set search_path to 'public' as $fn$

declare
  ms bigint := (extract(epoch from now())*1000)::bigint;
  f wow_fleets; z record; zt wow_users;
  sim jsonb; djson jsonb; surv jsonb; vloot jsonb; cargo numeric;
  lg numeric; lw numeric; lo numeric; rem numeric;
  defg numeric; defw numeric; defo numeric;
  att_wins boolean; wall integer; ret integer;
  a_forge int; a_fort int; d_forge int; d_fort int;
  who text; whoatt text;
  a_bon numeric; d_bon numeric; a_bon_arr numeric[]; jst jsonb; jparts record;
begin
  for f in select * from wow_fleets where state = 'outbound' and arrive_ms <= ms for update loop
    if f.kind = 'gift' then
      select * into zt from wow_users where id = f.target;
      if zt.id is not null then
        perform _wow_tick(f.target);
        update wow_users set
            gold = least(gold + coalesce((f.loot->>'gold')::numeric,0), _wow_cap(f.target)),
            wood = least(wood + coalesce((f.loot->>'wood')::numeric,0), _wow_cap(f.target)),
            ore  = least(ore  + coalesce((f.loot->>'ore')::numeric,0), _wow_cap(f.target))
          where id = f.target;
        insert into wow_reports(owner, kind, data, created)
          values (f.target, 'gift_in', jsonb_build_object('dir','gift_in',
            'who',(select name from wow_users where id = f.attacker),
            'gold',coalesce((f.loot->>'gold')::numeric,0),'wood',coalesce((f.loot->>'wood')::numeric,0),
            'ore',coalesce((f.loot->>'ore')::numeric,0),'created',ms), ms);
      end if;
      ret := _wow_travel((select pos from wow_users where id=f.target),(select pos from wow_users where id=f.attacker));
      update wow_fleets set state='returning', loot='{}'::jsonb, arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
      continue;
    end if;
    if f.kind in ('throne_atk','throne_rein','throne_claim') then
      perform _wow_throne_land(f.id);
      continue;
    end if;
    if f.kind = 'spy' then
      select * into zt from wow_users where id = f.target;
      if zt.id is null then
        insert into wow_reports(owner, kind, data, created)
          values (f.attacker, 'spy', jsonb_build_object('dir','spy','who','(reino destruido)','success',false,'created',ms), ms);
        delete from wow_fleets where id = f.id;
        continue;
      end if;
      zt := _wow_tick(f.target);
      if random() >= least(0.6, (select coalesce(max(level),0) from wow_buildings where owner_id=f.target and bkey='muralla') * 0.08) then
        insert into wow_reports(owner, kind, data, created)
          values (f.attacker, 'spy', jsonb_build_object('dir','spy','who',zt.name,'success',true,
            'gold',zt.gold,'wood',zt.wood,'ore',zt.ore,'capacity',_wow_cap(f.target),
            'buildings', coalesce((select jsonb_agg(jsonb_build_object('key',v.k,'level',coalesce(b.level,0)) order by v.ord)
              from (values ('mina',1),('aserradero',2),('tesoreria',3),('almacen',4),('cuartel',5),
                           ('herreria',6),('fortaleza',7),('mercado',8),('muralla',9)) v(k,ord)
              left join wow_buildings b on b.owner_id=f.target and b.bkey=v.k),'[]'),
            'troops', coalesce((select jsonb_agg(jsonb_build_object('key',v.t,'qty',coalesce(t.qty,0)) order by v.ord)
              from (values ('soldado',1),('arquero',2),('jinete',3),('mago',4),('paladin',5),('dragon',6)) v(t,ord)
              left join wow_troops t on t.owner_id=f.target and t.tkey=v.t),'[]'),
            'points', _wow_points(f.target),'created',ms), ms);
      else
        insert into wow_reports(owner, kind, data, created)
          values (f.attacker, 'spy', jsonb_build_object('dir','spy','who',zt.name,'success',false,'created',ms), ms);
        insert into wow_reports(owner, kind, data, created)
          values (f.target, 'spy_in', jsonb_build_object('dir','spy_in','who',(select name from wow_users where id=f.attacker),'created',ms), ms);
      end if;
      delete from wow_fleets where id = f.id;
      continue;
    end if;
    perform _wow_tick(f.attacker);
    zt := _wow_tick(f.target);
    djson := '{}'::jsonb;
    for z in select tkey, qty from wow_troops where owner_id = f.target and qty > 0 loop
      djson := djson || jsonb_build_object(z.tkey, z.qty);
    end loop;
    wall := coalesce((select max(level) from wow_buildings where owner_id = f.target and bkey='muralla'), 0);
    a_forge := coalesce((select max(level) from wow_buildings where owner_id = f.attacker and bkey='herreria'), 0);
    a_fort  := coalesce((select max(level) from wow_buildings where owner_id = f.attacker and bkey='fortaleza'), 0);
    d_forge := coalesce((select max(level) from wow_buildings where owner_id = f.target and bkey='herreria'), 0);
    d_fort  := coalesce((select max(level) from wow_buildings where owner_id = f.target and bkey='fortaleza'), 0);
    a_bon := _wow_madam_bonus(f.attacker);
    d_bon := _wow_madam_bonus(f.target);
    a_bon_arr := null; jst := null;
    if f.joint_op is not null then
      jst := _wow_joint_stats(f.joint_op);
      a_bon_arr := _wow_joint_bonus(f.joint_op);
    end if;
    if jst is not null then
      sim := _wow_sim(f.troops, djson, wall, f.id*7919 + (ms/1000),
                      (jst->>'might')::numeric, 1 + 0.04*d_forge,
                      (jst->>'tough')::numeric, 1 + 0.04*d_fort, a_bon, d_bon, a_bon_arr, null);
    else
      sim := _wow_sim(f.troops, djson, wall, f.id*7919 + (ms/1000),
                      1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort, a_bon, d_bon);
    end if;
    att_wins := (sim->>'winner') = 'attacker';
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'a_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    for z in select key, value from jsonb_each_text(sim->'d_left') loop
      update wow_troops set qty = (z.value)::int where owner_id = f.target and tkey = z.key;
    end loop;
    delete from wow_troops where owner_id = f.target and qty <= 0;
    vloot := '{}'::jsonb;
    if att_wins then
      select coalesce(sum((x.v)::int * _wow_cargo(x.k)),0) into cargo from jsonb_each_text(surv) x(k,v);
      select gold, wood, ore into defg, defw, defo from wow_users where id = f.target;
      lg := least(floor(coalesce(defg,0)*0.5), cargo); rem := cargo - lg;
      lw := least(floor(coalesce(defw,0)*0.5), rem); rem := rem - lw;
      lo := least(floor(coalesce(defo,0)*0.5), rem);
      if lg > 0 or lw > 0 or lo > 0 then
        update wow_users set gold = gold - lg, wood = wood - lw, ore = ore - lo where id = f.target;
        vloot := jsonb_build_object('gold',lg,'wood',lw,'ore',lo);
      end if;
    end if;
    who := zt.name;
    whoatt := (select name from wow_users where id = f.attacker);
    insert into wow_reports(owner, kind, data, created) values
      (f.attacker,'out', jsonb_build_object('dir','out','who',who,'win',att_wins,'battle',sim,'loot',vloot,'created',ms), ms),
      (f.target,'in',   jsonb_build_object('dir','in','who',whoatt,'win',att_wins,'battle',sim,'loot',vloot,'created',ms), ms);
    if f.joint_op is not null then
      for jparts in select o.owner, u.name from wow_joint_ops_troops o join wow_users u on u.id = o.owner where o.op_id = f.joint_op loop
        if jparts.owner <> f.attacker then
          insert into wow_reports(owner, kind, data, created) values
            (jparts.owner,'out', jsonb_build_object('dir','out','who',who,'win',att_wins,'battle',sim,'loot','{}'::jsonb,'joint',true,'created',ms), ms);
          insert into wow_joint_ops_reports(op_id, owner, report, created)
            values (f.joint_op, jparts.owner, jsonb_build_object('dir','out','who',who,'win',att_wins,'created',ms), ms);
        end if;
      end loop;
    end if;
    ret := _wow_travel((select pos from wow_users where id=f.target),(select pos from wow_users where id=f.attacker));
    update wow_fleets set state='returning', troops=surv, loot=vloot, arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
  end loop;
  for f in select * from wow_fleets where state='returning' and arrive_ms <= ms for update loop
    if f.kind = 'gift' then
      delete from wow_fleets where id = f.id;
      continue;
    end if;
    if f.joint_op is not null then
      perform _wow_joint_settle(f.joint_op, f.troops, f.loot);
      delete from wow_fleets where id = f.id;
      continue;
    end if;
    perform _wow_tick(f.attacker);
    for z in select key, value from jsonb_each_text(f.troops) loop
      insert into wow_troops(owner_id, tkey, qty) values (f.attacker, z.key, (z.value)::int)
        on conflict (owner_id, tkey) do update set qty = wow_troops.qty + excluded.qty;
    end loop;
    update wow_users set
        gold = least(gold + coalesce((f.loot->>'gold')::numeric,0), _wow_cap(f.attacker)),
        wood = least(wood + coalesce((f.loot->>'wood')::numeric,0), _wow_cap(f.attacker)),
        ore  = least(ore  + coalesce((f.loot->>'ore')::numeric,0), _wow_cap(f.attacker))
      where id = f.attacker;
    insert into wow_reports(owner, kind, data, created)
      values (f.attacker, 'return', jsonb_build_object('dir','return',
        'who', coalesce((select name from wow_thrones th where th.node = f.node), ''),
        'win',true,'loot',f.loot,'created',ms), ms);
    delete from wow_fleets where id = f.id;
  end loop;
end ;
$fn$;
revoke all on function public._wow_resolve() from public;

-- ------------------------------------------------------------
-- _wow_throne_land con soporte de conquistas conjuntas.
-- ------------------------------------------------------------
create or replace function _wow_throne_land(p_fleet_id bigint) returns void language plpgsql security definer set search_path to 'public' as $fn$

declare
  f wow_fleets; u wow_users; t wow_thrones; ms bigint; z record; r record;
  sim jsonb; surv jsonb; msg jsonb; prev text; ret integer; ually text; lab text;
  a_forge int; a_fort int; d_forge int; d_fort int; d_wall int;
  a_bon numeric; d_bon numeric; a_bon_arr numeric[]; jst jsonb;
  asurv jsonb; jp record;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  select * into f from wow_fleets where id = p_fleet_id;
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
  if t.node is null then
    ret := _wow_travel_node(u.pos, _wow_pos_node(u.pos));
    update wow_fleets set state = 'returning', arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who','','win',false,
        'note','El objetivo ya no existe: tus tropas vuelven a casa.','created',ms), ms);
    return;
  end if;
  if coalesce(t.holder,'') = '' or t.garrison = '{}'::jsonb then
    ually := u.alliance;
    update wow_thrones set holder = u.id, holder_name = u.name, holder_ally = ually,
      since_ms = ms, garrison = f.troops, accrue_ms = ms where node = t.node;
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
    perform _wow_event('throne', (case when t.kind = 'aldea' then '🛖 ' else '🏯 ' end) || u.name || ' ha ocupado ' || t.name ||
      (case when ually is not null then ' en nombre de ' || coalesce(nullif(lab,''),'su alianza') else '' end) || '.');
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',true,'battle',null,
        'ally', lab, 'created',ms), ms);
    if f.joint_op is not null then
      perform _wow_joint_throne_loot(f.joint_op, t.node, t.name, null, true);
      update wow_joint_ops set status = 'done' where id = f.joint_op;
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
  asurv := '{}'::jsonb;
  for z in select key, value from jsonb_each_text(sim->'a_left') loop
    if (z.value)::int > 0 then asurv := asurv || jsonb_build_object(z.key, (z.value)::int); end if;
  end loop;
  if (sim->>'winner') = 'attacker' then
    ually := u.alliance;
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'a_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    update wow_thrones set holder = u.id, holder_name = u.name, holder_ally = ually,
      since_ms = ms, garrison = surv, accrue_ms = ms where node = t.node;
    delete from wow_node_contrib where node = t.node;
    if f.joint_op is not null then
      for jp in select * from jsonb_array_elements(_wow_joint_split(f.joint_op, surv, '{}'::jsonb)) loop
        perform _wow_contrib_add(t.node, jp.value->>'owner', jp.value->'troops');
      end loop;
    else
      perform _wow_contrib_set(t.node, u.id, surv);
    end if;
    perform _wow_throne_log(t.node, 'conquest', u.id, u.name, jsonb_build_object('from', prev));
    lab := _wow_ally_label(ually);
    perform _wow_event('throne', (case when t.kind = 'aldea' then '🏘️ ' else '👑 ' end) || u.name || ' ha conquistado ' || t.name ||
      ' (antes de ' || coalesce(prev, 'nadie') || ')' ||
      (case when ually is not null then ', en nombre de ' || coalesce(nullif(lab,''),'su alianza') else '' end) || '.');
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',true,'from',u.name,'battle',sim,'ally',lab,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',true,'from',u.name,'battle',sim,'created',ms), ms);
    if f.joint_op is not null then
      perform _wow_joint_throne_loot(f.joint_op, t.node, t.name, sim, true);
      update wow_joint_ops set status = 'done' where id = f.joint_op;
    end if;
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
    if f.joint_op is not null then
      perform _wow_joint_throne_loot(f.joint_op, t.node, t.name, sim, false);
      update wow_joint_ops set status = 'done' where id = f.joint_op;
      ret := _wow_travel_node(u.pos, coalesce(f.node, _wow_pos_node(u.pos)));
      update wow_fleets set state = 'returning', troops = asurv, loot = '{}'::jsonb,
        arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
      return;
    end if;
  end if;
  delete from wow_fleets where id = f.id;
end ;
$fn$;
revoke all on function public._wow_throne_land(bigint) from public;
