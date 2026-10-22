-- ================================================================
-- APENDICE MADAM DE LA TABERNA: contrato de acompanantes.
--   - wow_tavern_contracts: contrato por reino (owner, until_ms, bonus).
--   - wow_madam_info: estado del contrato, coste y duracion.
--   - wow_madam_hire: cobra 50 CUP y activa/renueva 30 dias.
--   - _wow_madam_bonus: +1 de ataque por tropa si hay contrato activo.
--   - _wow_sim (override): anade el bonus plano de ataque por tropa al
--     atacante (p_abonus) y al defensor (p_dbonus).
--   - _wow_resolve (override): pasa el bonus de cada reino a la simulacion.
-- ================================================================

insert into wow_settings(key,val) values
  ('madam_cost','50'),
  ('madam_days','30'),
  ('madam_bonus','1'),
  ('tavern_share','0'),
  ('tavern_pct_trono','1'),
  ('tavern_pct_aldea','0.3'),
  ('madam_admin_pct','0')
on conflict (key) do nothing;

-- eliminar la version antigua de _wow_sim (8 args) para no dejar sobrecarga
drop function if exists public._wow_sim(jsonb, jsonb, integer, bigint, numeric, numeric, numeric, numeric);

create table if not exists wow_tavern_contracts (
  owner text primary key,
  bonus numeric not null default 0,
  until_ms bigint not null default 0,
  created bigint not null default 0
);

create or replace function public._wow_madam_cost() returns numeric
language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='madam_cost'),50);
$$;

create or replace function public._wow_madam_days() returns numeric
language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='madam_days'),30);
$$;

create or replace function public._wow_madam_bonusth() returns numeric
language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='madam_bonus'),1);
$$;

-- % de lo recaudado en la taberna que va al tesoro de tronos y aldeas
create or replace function public._wow_tavern_share() returns numeric
language sql stable set search_path to 'public' as $$
  select greatest(0, least(100, coalesce((select val::numeric from wow_settings where key='tavern_share'),0)));
$$;

-- % de cada contrato que se le asigna a las fortalezas (tronos)
create or replace function public._wow_tavern_pct_trono() returns numeric
language sql stable set search_path to 'public' as $$
  select greatest(0, least(100, coalesce((select val::numeric from wow_settings where key='tavern_pct_trono'),1)));
$$;

-- % de cada contrato que se le asigna a las aldeas
create or replace function public._wow_tavern_pct_aldea() returns numeric
language sql stable set search_path to 'public' as $$
  select greatest(0, least(100, coalesce((select val::numeric from wow_settings where key='tavern_pct_aldea'),0.3)));
$$;

-- % de cada contrato que se lleva el administrador
create or replace function public._wow_madam_admin_pct() returns numeric
language sql stable set search_path to 'public' as $$
  select greatest(0, least(100, coalesce((select val::numeric from wow_settings where key='madam_admin_pct'),0)));
$$;

-- reparte el resto (p_base) entre los nodos ocupados, proporcional a los %
-- de fortalezas y aldeas (total repartido = p_base; nunca crea CUP).
create or replace function public._wow_tavern_distribute(p_base numeric, p_key text)
returns numeric language plpgsql security definer set search_path to 'public' as $$
declare pt numeric; pa numeric; w numeric; nt integer; na integer; pool_t numeric; pool_a numeric;
        per_t numeric; per_a numeric; tt record; total numeric := 0;
begin
  if coalesce(p_base,0) <= 0 then return 0; end if;
  pt := _wow_tavern_pct_trono();
  pa := _wow_tavern_pct_aldea();
  w := pt + pa;
  if w <= 0 then return 0; end if;
  select count(*) filter (where _wow_node_kind(node) = 'aldea'),
         count(*) filter (where _wow_node_kind(node) <> 'aldea')
    into na, nt from wow_thrones where holder is not null;
  pool_t := round(p_base * pt / w, 2);
  pool_a := round(p_base * pa / w, 2);
  per_t := case when nt > 0 then round(pool_t / nt, 2) else 0 end;
  per_a := case when na > 0 then round(pool_a / na, 2) else 0 end;
  for tt in select node, _wow_node_kind(node) kind from wow_thrones where holder is not null order by node for update loop
    if tt.kind = 'aldea' then
      if per_a > 0 then perform _wow_throne_add(tt.node, p_key, per_a); total := total + per_a; end if;
    else
      if per_t > 0 then perform _wow_throne_add(tt.node, p_key, per_t); total := total + per_t; end if;
    end if;
  end loop;
  return total;
end $$;

-- +1 de ataque por tropa si el reino tiene contrato activo, si no 0
create or replace function public._wow_madam_bonus(p_uid text)
returns numeric language sql stable set search_path to 'public' as $$
  select case
    when p_uid is null then 0
    when exists (select 1 from wow_tavern_contracts c
                  where c.owner = p_uid and c.until_ms > (extract(epoch from now())*1000)::bigint)
      then _wow_madam_bonusth()
    else 0 end;
$$;

-- total de CUP recaudado por la Madam desde siempre
create or replace function public._wow_madam_earned() returns numeric
language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='madam_earned'),0);
$$;

-- estado del contrato del reino
create or replace function public.wow_madam_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; c wow_tavern_contracts; ms bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select * into c from wow_tavern_contracts where owner = u.id;
  return jsonb_build_object('ok', true,
    'cost', _wow_madam_cost(), 'days', _wow_madam_days(), 'bonus', _wow_madam_bonusth(), 'admin_pct', _wow_madam_admin_pct(), 'pct_trono', _wow_tavern_pct_trono(), 'pct_aldea', _wow_tavern_pct_aldea(),
    'cup', u.cup, 'earned', _wow_madam_earned(),
    'active', (c.owner is not null and c.until_ms > ms),
    'until', coalesce(c.until_ms, 0),
    'remain_ms', greatest(0, coalesce(c.until_ms,0) - ms));
end $$;
revoke all on function public.wow_madam_info(text) from public;
grant execute on function public.wow_madam_info(text) to anon, authenticated;

-- contratar / renovar: cobra CUP y asegura 30 dias desde el mayor entre ahora y el fin actual
create or replace function public.wow_madam_hire(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; c wow_tavern_contracts; cost numeric; ms bigint; base bigint; until_ms bigint; repartido numeric; admin_cut numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no contratan.'; end if;
  u := _wow_tick(u.id);
  cost := _wow_madam_cost();
  if coalesce(u.cup,0) < cost then raise exception 'Necesitas % CUP para contratar a la Madam.', cost; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  select * into c from wow_tavern_contracts where owner = u.id for update;
  base := greatest(ms, coalesce(c.until_ms,0));
  until_ms := base + (_wow_madam_days()*86400000)::bigint;
  update wow_users set cup = cup - cost where id = u.id;
  insert into wow_settings(key,val) values ('madam_earned', cost::text)
    on conflict (key) do update set val = (coalesce(wow_settings.val::numeric,0) + cost)::text;
  insert into wow_tavern_contracts(owner, bonus, until_ms, created)
    values (u.id, _wow_madam_bonusth(), until_ms, ms)
    on conflict (owner) do update set bonus = excluded.bonus, until_ms = excluded.until_ms;
  admin_cut := round(cost * _wow_madam_admin_pct() / 100.0, 2);
  if admin_cut > 0 then
    update wow_users set cup = coalesce(cup,0) + admin_cut where is_admin = true;
  end if;
  repartido := _wow_tavern_distribute(cost - admin_cut, 'cup');
  return jsonb_build_object('ok', true, 'cost', cost, 'until', until_ms, 'bonus', _wow_madam_bonusth(),
    'cup', (select cup from wow_users where id=u.id), 'admin_cut', admin_cut, 'shared', repartido);
end $$;
revoke all on function public.wow_madam_hire(text) from public;
grant execute on function public.wow_madam_hire(text) to anon, authenticated;

-- simulacion de batalla (override): +1 de ataque por tropa para atacante y defensor
create or replace function public._wow_sim(p_att jsonb, p_def jsonb, p_wall integer, p_seed bigint, p_amight numeric DEFAULT 1, p_dmight numeric DEFAULT 1, p_atough numeric DEFAULT 1, p_dtough numeric DEFAULT 1, p_abonus numeric DEFAULT 0, p_dbonus numeric DEFAULT 0)
returns jsonb language plpgsql security definer set search_path to 'public' as $$

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
        dmgn := dmgn + (dPre[j]*(atkA[j]+dbon)) * _wow_counter(keys[j], keys[i]) * (aHP[i]/greatest(aHPtot,1));
      end loop;
      dmgn := dmgn * dmgK * (1 + noiseD*0.2) * mightD / toughA;
      if dmgn > 0 then aCas[i] := aCas[i] + dmgn/hpA[i]; end if;
      aq[i] := greatest(aInit[i] - floor(aCas[i]), 0);
    end loop;
    for j in 1..6 loop
      dmgn := 0;
      for i in 1..6 loop
        dmgn := dmgn + (aPre[i]*(atkA[i]+abon)) * _wow_counter(keys[i], keys[j]) * (dHP[j]/greatest(dHPtot,1));
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
    'a_morale',round(morA),'d_morale',round(morD),'a_bonus',abon,'d_bonus',dbon);
end ;
$$;
revoke all on function public._wow_sim(jsonb, jsonb, integer, bigint, numeric, numeric, numeric, numeric, numeric, numeric) from public, anon, authenticated;

-- resolucion de marchas (override): el bonus de la madam entra en la simulacion
create or replace function public._wow_resolve()
returns void language plpgsql security definer set search_path to 'public' as $$

declare
  ms bigint := (extract(epoch from now())*1000)::bigint;
  f wow_fleets; z record; zt wow_users;
  sim jsonb; djson jsonb; surv jsonb; vloot jsonb; cargo numeric;
  lg numeric; lw numeric; lo numeric; rem numeric;
  defg numeric; defw numeric; defo numeric;
  att_wins boolean; wall integer; ret integer;
  a_forge int; a_fort int; d_forge int; d_fort int;
  who text; whoatt text;
  a_bon numeric; d_bon numeric;
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
    sim := _wow_sim(f.troops, djson, wall, f.id*7919 + (ms/1000),
                    1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort, a_bon, d_bon);
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
    ret := _wow_travel((select pos from wow_users where id=f.target),(select pos from wow_users where id=f.attacker));
    update wow_fleets set state='returning', troops=surv, loot=vloot, arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
  end loop;
  for f in select * from wow_fleets where state='returning' and arrive_ms <= ms for update loop
    if f.kind = 'gift' then
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
$$;
revoke all on function public._wow_resolve() from public, anon, authenticated;

-- asalto a trono/aldea (override): el bonus de la madam tambien cuenta
create or replace function public._wow_throne_land(p_fleet_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$

declare
  f wow_fleets; u wow_users; t wow_thrones; ms bigint; z record; r record;
  sim jsonb; surv jsonb; msg jsonb; prev text; ret integer; ually text; lab text;
  a_forge int; a_fort int; d_forge int; d_fort int; d_wall int;
  a_bon numeric; d_bon numeric;
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
  prev := t.holder_name;
  a_forge := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'herreria'), 0);
  a_fort  := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'fortaleza'), 0);
  d_forge := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'herreria'), 0);
  d_fort  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'fortaleza'), 0);
  d_wall  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'muralla'), 0);
  a_bon := _wow_madam_bonus(u.id);
  d_bon := _wow_madam_bonus(t.holder);
  sim := _wow_sim(f.troops, t.garrison, d_wall, (ms/1000) + t.node*131,
                  1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort, a_bon, d_bon);
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
end ;
$$;
revoke all on function public._wow_throne_land(bigint) from public, anon, authenticated;

-- estado del reino (override): incluye atk_bonus para mostrar el +1 en el Cuartel
create or replace function public.wow_state(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare u wow_users; blds jsonb; trs jsonb; que jsonb; cap numeric; rate jsonb; ms bigint; pts integer; abon numeric;
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
  abon := _wow_madam_bonus(u.id);
  pts := (select coalesce(sum(level),0) from wow_buildings where owner_id = u.id) * 100
       + (select coalesce(sum(qty),0) from wow_troops where owner_id = u.id);
  return jsonb_build_object('id', u.id, 'name', u.name, 'faction', u.faction, 'is_admin', u.is_admin,
    'gold', u.gold, 'wood', u.wood, 'ore', u.ore, 'cup', coalesce(u.cup,0), 'capacity', cap, 'rate', rate,
    'prod_mult', (_wow_prod_global() * _wow_prod_clamp(u.prod_mult)),
    'buildings', blds, 'troops', trs, 'queue', que->0, 'queues', que, 'points', pts, 'now', ms, 'atk_bonus', abon,
    'alliance', u.alliance,
    'ally_tag', coalesce((select tag from wow_alliances where id = u.alliance), ''),
    'ally_emblem', _wow_ally_icon(u.alliance),
    'online', _wow_online_count());
end ;
$$;
revoke all on function public.wow_state(text) from public;
grant execute on function public.wow_state(text) to anon, authenticated;

-- ajustes de la taberna: coste, duracion, bonus, % admin, % fortalezas y % aldeas
drop function if exists public.wow_admin_setmadam(text, numeric, numeric, numeric);
drop function if exists public.wow_admin_setmadam(text, numeric, numeric, numeric, numeric);
drop function if exists public.wow_admin_setmadam(text, numeric, numeric, numeric, numeric, numeric);
create or replace function public.wow_admin_setmadam(p_token text, p_cost numeric, p_days numeric, p_bonus numeric, p_admin numeric, p_trono numeric, p_aldea numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if not (p_cost >= 0 and p_cost <= 100000) then raise exception 'El precio debe estar entre 0 y 100.000 CUP.'; end if;
  if not (p_days >= 1 and p_days <= 365) then raise exception 'La duracion debe estar entre 1 y 365 dias.'; end if;
  if not (p_bonus >= 0 and p_bonus <= 100) then raise exception 'El bonus debe estar entre 0 y 100.'; end if;
  if not (p_admin >= 0 and p_admin <= 100) then raise exception 'La ganancia del admin debe estar entre 0 y 100.'; end if;
  if not (p_trono >= 0 and p_trono <= 100) then raise exception 'El porcentaje de fortalezas debe estar entre 0 y 100.'; end if;
  if not (p_aldea >= 0 and p_aldea <= 100) then raise exception 'El porcentaje de aldeas debe estar entre 0 y 100.'; end if;
  insert into wow_settings(key,val) values ('madam_cost', p_cost::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('madam_days', p_days::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('madam_bonus', p_bonus::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('madam_admin_pct', p_admin::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('tavern_pct_trono', p_trono::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('tavern_pct_aldea', p_aldea::text) on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'cost', _wow_madam_cost(), 'days', _wow_madam_days(), 'bonus', _wow_madam_bonusth(), 'admin_pct', _wow_madam_admin_pct(), 'pct_trono', _wow_tavern_pct_trono(), 'pct_aldea', _wow_tavern_pct_aldea());
end $$;
revoke all on function public.wow_admin_setmadam(text, numeric, numeric, numeric, numeric, numeric, numeric) from public;
grant execute on function public.wow_admin_setmadam(text, numeric, numeric, numeric, numeric, numeric, numeric) to anon, authenticated;

-- reinos con contrato de la Madam activo ahora
create or replace function public.wow_admin_madam_contracts(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; ms bigint;
begin
  a := _wow_admin(p_token);
  ms := (extract(epoch from now())*1000)::bigint;
  return jsonb_build_object('ok', true, 'now', ms, 'contracts', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.owner, 'name', u.name, 'faction', u.faction,
      'alliance', coalesce((select tag from wow_alliances where id = u.alliance),''),
      'bonus', c.bonus, 'until', c.until_ms, 'remain_ms', greatest(0, c.until_ms - ms)
    ) order by c.until_ms desc)
    from wow_tavern_contracts c join wow_users u on u.id = c.owner
    where c.until_ms > ms
  ), '[]'));
end $$;
revoke all on function public.wow_admin_madam_contracts(text) from public;
grant execute on function public.wow_admin_madam_contracts(text) to anon, authenticated;

-- lista de reinos para el admin (override): incluye los precios de la taberna
create or replace function public.wow_admin_list(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$

declare a wow_users; out jsonb; ms bigint;
begin
  a := _wow_admin(p_token);
  perform _wow_resolve();
  ms := (extract(epoch from now())*1000)::bigint;
  select jsonb_build_object('now', ms, 'me', a.id, 'prod_mult', _wow_prod_global(), 'madam', jsonb_build_object('cost', _wow_madam_cost(), 'days', _wow_madam_days(), 'bonus', _wow_madam_bonusth(), 'active_n', (select count(*) from wow_tavern_contracts where until_ms > ms), 'earned', _wow_madam_earned(), 'admin_pct', _wow_madam_admin_pct(), 'pct_trono', _wow_tavern_pct_trono(), 'pct_aldea', _wow_tavern_pct_aldea()), 'users', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', w.id, 'name', w.name, 'faction', w.faction, 'pos', w.pos,
      'active', w.active, 'is_admin', w.is_admin,
      'gold', floor(w.gold), 'wood', floor(w.wood), 'ore', floor(w.ore),
      'cup', round(coalesce(w.cup,0), 2),
      'prod_mult', _wow_prod_clamp(w.prod_mult),
      'points', _wow_points(w.id),
      'troops', coalesce((select sum(qty) from wow_troops where owner_id = w.id),0),
      'alliance', coalesce((select tag from wow_alliances where id = w.alliance),''),
      'created', w.created, 'last', w.last_ms
    ) order by w.created)
    from wow_users w
  ), '[]')) into out;
  return out;
end ;
$$;
revoke all on function public.wow_admin_list(text) from public;
grant execute on function public.wow_admin_list(text) to anon, authenticated;
