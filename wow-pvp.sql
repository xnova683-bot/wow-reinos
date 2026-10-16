-- ================================================================
-- REINOS DE AZEROTH - v3 COMBATE POR RONDAS + ESPIONAJE
--   - Envias tropas a atacar (tiempo de viaje por distancia)
--   - Batalla POR RONDAS: contadores de tipo (piedra-papel-tijera),
--     moral, azar controlado, muros y asalto final
--   - Informe detallado ronda a ronda + botin
--   - Espias para reconocer recursos / defensa / tropas
-- ================================================================

-- ---------- limpieza idempotente ----------
drop function if exists public.wow_attack(text, text, jsonb);
drop function if exists public.wow_spy(text, text);
drop function if exists public.wow_fleets(text);
drop function if exists public._wow_resolve();
drop function if exists public._wow_sim(jsonb, jsonb, integer, bigint);
drop function if exists public._wow_sim(jsonb, jsonb, integer, bigint, numeric, numeric, numeric, numeric);
drop function if exists public._wow_atk(text);
drop function if exists public._wow_hp(text);
drop function if exists public._wow_counter(text, text);
drop function if exists public._wow_cargo(text);
drop function if exists public._wow_noise(bigint, bigint);
drop function if exists public._wow_travel(integer, integer);
drop function if exists public._wow_astat(text);
drop function if exists public._wow_dstat(text);

-- ---------- tablas ----------
create table if not exists public.wow_fleets(
  id bigserial primary key,
  attacker text not null references public.wow_users(id) on delete cascade,
  target   text not null,
  troops   jsonb not null default '{}'::jsonb,
  loot     jsonb not null default '{}'::jsonb,
  state    text  not null default 'outbound',
  kind     text  not null default 'attack',
  depart_ms bigint not null default 0,
  arrive_ms bigint not null default 0
);
alter table public.wow_fleets add column if not exists kind text not null default 'attack';
alter table public.wow_fleets add column if not exists leg_start_ms bigint not null default 0;
create table if not exists public.wow_reports(
  id bigserial primary key,
  owner text not null references public.wow_users(id) on delete cascade,
  kind  text not null default '',
  data  jsonb not null default '{}'::jsonb,
  created bigint not null default 0
);
alter table public.wow_fleets  enable row level security;
alter table public.wow_reports enable row level security;

-- ---------- estadisticas de unidad ----------
-- ataque (dano por ronda) y aguante (hp)
create or replace function public._wow_atk(p_key text)
returns integer language sql immutable as $$
  select case p_key when 'soldado' then 10 when 'arquero' then 15
                    when 'jinete' then 20 when 'mago' then 26
                    when 'paladin' then 24 when 'dragon' then 44 else 0 end
$$;
create or replace function public._wow_hp(p_key text)
returns integer language sql immutable as $$
  select case p_key when 'soldado' then 12 when 'arquero' then 8
                    when 'jinete' then 16 when 'mago' then 7
                    when 'paladin' then 26 when 'dragon' then 34 else 1 end
$$;
-- multiplicador de dano: atacante -> defensor (piedra/papel/tijera)
--   6 tipos. Ventajas (2.0) / debilidades (0.5) / espejo o neutral (1.0):
--     soldado > jinete
--     arquero > soldado, mago, dragon
--     jinete  > arquero, paladin
--     mago    > soldado, jinete
--     paladin > mago, dragon
--     dragon  > soldado, jinete, mago
create or replace function public._wow_counter(a text, d text)
returns numeric language sql immutable as $$
  select case
    when a='soldado' then case d when 'arquero' then 0.5 when 'jinete' then 2.0
                                 when 'mago' then 0.5 when 'dragon' then 0.5 else 1.0 end
    when a='arquero' then case d when 'soldado' then 2.0 when 'jinete' then 0.5
                                 when 'mago' then 2.0 when 'dragon' then 2.0 else 1.0 end
    when a='jinete'  then case d when 'soldado' then 0.5 when 'arquero' then 2.0
                                 when 'mago' then 0.5 when 'paladin' then 2.0 when 'dragon' then 0.5 else 1.0 end
    when a='mago'    then case d when 'soldado' then 2.0 when 'arquero' then 0.5
                                 when 'jinete' then 2.0 when 'paladin' then 0.5 when 'dragon' then 0.5 else 1.0 end
    when a='paladin' then case d when 'jinete' then 0.5 when 'mago' then 2.0 when 'dragon' then 2.0 else 1.0 end
    when a='dragon'  then case d when 'soldado' then 2.0 when 'arquero' then 0.5
                                 when 'jinete' then 2.0 when 'mago' then 2.0 when 'paladin' then 0.5 else 1.0 end
    else 1.0 end
$$;
create or replace function public._wow_cargo(p_key text)
returns integer language sql immutable as $$
  select case p_key when 'soldado' then 40 when 'arquero' then 30
                    when 'jinete' then 120 when 'mago' then 60
                    when 'paladin' then 90 when 'dragon' then 240 else 0 end
$$;
create or replace function public._wow_travel(a integer, b integer)
returns integer language sql immutable as $$
  select greatest(20, 15 + 3 * abs(coalesce(a,0) - coalesce(b,0)))
$$;
-- ruido determinista en [-0.5,0.5)
create or replace function public._wow_noise(p_seed bigint, p_salt bigint)
returns numeric language sql immutable as $$
  select ((abs(hashtextextended(coalesce(p_seed,0)::text||':'||coalesce(p_salt,0)::text, 0)) % 1000)::numeric / 1000.0) - 0.5
$$;
revoke all on function public._wow_atk(text) from public, anon, authenticated;
revoke all on function public._wow_hp(text) from public, anon, authenticated;
revoke all on function public._wow_counter(text, text) from public, anon, authenticated;
revoke all on function public._wow_cargo(text) from public, anon, authenticated;
revoke all on function public._wow_travel(integer, integer) from public, anon, authenticated;
revoke all on function public._wow_noise(bigint, bigint) from public, anon, authenticated;

-- ---------- SIMULADOR DE BATALLA (por rondas) ----------
create or replace function public._wow_sim(p_att jsonb, p_def jsonb, p_wall integer, p_seed bigint,
    p_amight numeric default 1, p_dmight numeric default 1, p_atough numeric default 1, p_dtough numeric default 1)
returns jsonb language plpgsql immutable as $$
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

    -- bajas del atacante (dano de cada tipo defensor repartido por hp)
    for i in 1..6 loop
      dmgn := 0;
      for j in 1..6 loop
        dmgn := dmgn + (dPre[j]*atkA[j]) * _wow_counter(keys[j], keys[i]) * (aHP[i]/greatest(aHPtot,1));
      end loop;
      dmgn := dmgn * dmgK * (1 + noiseD*0.2) * mightD / toughA;
      if dmgn > 0 then aCas[i] := aCas[i] + dmgn/hpA[i]; end if;
      aq[i] := greatest(aInit[i] - floor(aCas[i]), 0);
    end loop;
    -- bajas del defensor (reducidas por muralla)
    for j in 1..6 loop
      dmgn := 0;
      for i in 1..6 loop
        dmgn := dmgn + (aPre[i]*atkA[i]) * _wow_counter(keys[i], keys[j]) * (dHP[j]/greatest(dHPtot,1));
      end loop;
      dmgn := dmgn * dmgK * wallF * (1 + noiseA*0.2) * mightA / toughD;
      if dmgn > 0 then dCas[j] := dCas[j] + dmgn/hpA[j]; end if;
      dq[j] := greatest(dInit[j] - floor(dCas[j]), 0);
    end loop;

    afterA := 0; afterD := 0;
    for i in 1..6 loop afterA := afterA + aq[i]; afterD := afterD + dq[i]; end loop;
    lossA := beforeA - afterA; lossD := beforeD - afterD;

    -- moral = fraccion de ejercito que sigue en pie, mas un impulso por el
    -- ultimo choque (una mala ronda desmoraliza, una buena envalentona)
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

  -- quien rompe filas pierde. Si ambos rompen gana quien conserva mas moral;
  -- si se agota el tiempo gana quien conserva mayor proporcion de ejercito.
  -- Los empates los gana el defensor (ventaja de defender).
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

  -- desbandada: la parte que rompe filas pierde la mitad de sus supervivientes
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
end $$;
revoke all on function public._wow_sim(jsonb, jsonb, integer, bigint, numeric, numeric, numeric, numeric) from public, anon, authenticated;

-- ---------- resolucion global de flotas ----------
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
begin
  for f in select * from wow_fleets where state = 'outbound' and arrive_ms <= ms for update loop

    -- ===== mision de espionaje =====
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

    -- ===== batalla por rondas =====
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
    sim := _wow_sim(f.troops, djson, wall, f.id*7919 + (ms/1000),
                    1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort);
    att_wins := (sim->>'winner') = 'attacker';

    -- supervivientes del atacante (sin ceros)
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'a_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;

    -- defensa restante
    for z in select key, value from jsonb_each_text(sim->'d_left') loop
      update wow_troops set qty = (z.value)::int where owner_id = f.target and tkey = z.key;
    end loop;
    delete from wow_troops where owner_id = f.target and qty <= 0;

    -- botin si el atacante gana
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

  -- ---- regreso a casa ----
  for f in select * from wow_fleets where state='returning' and arrive_ms <= ms for update loop
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
      values (f.attacker, 'return', jsonb_build_object('dir','return','who','','win',true,'loot',f.loot,'created',ms), ms);
    delete from wow_fleets where id = f.id;
  end loop;
end $$;
revoke all on function public._wow_resolve() from public, anon, authenticated;

-- ---------- enviar ataque ----------
create or replace function public.wow_attack(p_token text, p_target text, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_users; ms bigint; e record; v integer; travel integer; sent jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  if p_target = u.id then raise exception 'No puedes atacarte a ti mismo.'; end if;
  select * into t from wow_users where id = p_target and active;
  if t.id is null then raise exception 'Ese reino ya no existe.'; end if;
  if t.alliance is not null and t.alliance = u.alliance then
    raise exception 'No puedes atacar a un miembro de tu propia alianza.'; end if;
  if p_troops is null or p_troops = '{}'::jsonb then raise exception 'Elige las tropas a enviar.'; end if;
  sent := '{}'::jsonb;
  for e in select key as kk, value as vv from jsonb_each_text(p_troops) loop
    if e.kk not in ('soldado','arquero','jinete','mago','paladin','dragon') then raise exception 'Tropa no válida.'; end if;
    begin v := (e.vv)::int; exception when others then v := 0; end;
    if v > 0 then
      if (select coalesce(qty,0) from wow_troops where owner_id=u.id and tkey=e.kk) < v then
        raise exception 'No tienes suficientes tropas de ese tipo.'; end if;
      sent := sent || jsonb_build_object(e.kk, v);
    end if;
  end loop;
  if sent = '{}'::jsonb then raise exception 'Elige al menos una tropa.'; end if;
  for e in select key as kk, value as vv from jsonb_each_text(sent) loop
    update wow_troops set qty = qty - (e.vv)::int where owner_id=u.id and tkey=e.kk;
  end loop;
  travel := _wow_travel(u.pos, t.pos);
  ms := (extract(epoch from now())*1000)::bigint;
  insert into wow_fleets(attacker, target, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, t.id, sent, '{}'::jsonb, 'outbound', 'attack', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name);
end $$;
grant execute on function public.wow_attack(text, text, jsonb) to anon, authenticated;

-- ---------- enviar espia ----------
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

-- ---------- flotas + informes ----------
create or replace function public.wow_fleets(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb; ms bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  ms := (extract(epoch from now())*1000)::bigint;
  select jsonb_build_object(
    'now', ms,
    'fleets', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', f.id, 'mine', f.attacker = u.id, 'kind', f.kind,
        'who', (select name from wow_users where id = case when f.attacker = u.id then f.target else f.attacker end),
        'state', f.state, 'troops', f.troops, 'loot', f.loot, 'arrive', f.arrive_ms
      ) order by f.arrive_ms)
      from wow_fleets f where f.attacker = u.id or (f.target = u.id and f.kind <> 'spy')
    ), '[]'),
    'reports', coalesce((
      select jsonb_agg(x.data order by x.id desc)
      from (select id, data from wow_reports where owner = u.id order by id desc limit 20) x
    ), '[]')
  ) into out;
  return out;
end $$;
grant execute on function public.wow_fleets(text) to anon, authenticated;

-- ---------- enganchar resolucion a state / map (con stats de tropa) ----------
create or replace function public.wow_state(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; blds jsonb; trs jsonb; que jsonb; cap numeric; rate jsonb; ms bigint; pts integer;
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
             'atk', _wow_atk(v.t), 'hp', _wow_hp(v.t)) order by v.ord), '[]') into trs
    from (values ('soldado',1),('arquero',2),('jinete',3),('mago',4),('paladin',5),('dragon',6)) v(t,ord)
    left join wow_troops t on t.owner_id = u.id and t.tkey = v.t;
  select jsonb_build_object('kind', q.kind, 'ref', q.ref, 'qty', q.qty, 'unit_ms', q.unit_ms,
           'start', q.start_ms, 'finish', q.finish_ms) into que
    from wow_queue q where q.owner_id = u.id;
  pts := (select coalesce(sum(level),0) from wow_buildings where owner_id = u.id) * 100
       + (select coalesce(sum(qty),0) from wow_troops where owner_id = u.id);
  return jsonb_build_object('id', u.id, 'name', u.name, 'faction', u.faction,
    'gold', u.gold, 'wood', u.wood, 'ore', u.ore, 'capacity', cap, 'rate', rate,
    'buildings', blds, 'troops', trs, 'queue', que, 'points', pts, 'now', ms,
    'alliance', u.alliance,
    'ally_tag', coalesce((select tag from wow_alliances where id = u.alliance), ''));
end $$;
grant execute on function public.wow_state(text) to anon, authenticated;

create or replace function public.wow_map(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', w.id, 'pos', w.pos, 'name', w.name, 'faction', w.faction,
             'alliance', coalesce(al.tag,''), 'points', _wow_points(w.id), 'me', w.id = u.id)
           order by w.pos), '[]') into out
    from wow_users w left join wow_alliances al on al.id = w.alliance
   where w.active;
  return out;
end $$;
grant execute on function public.wow_map(text) to anon, authenticated;

-- ---------- marchas (ejercitos en transito) para el mapa ----------
create or replace function public.wow_marches(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ms bigint; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  ms := (extract(epoch from now())*1000)::bigint;
  select jsonb_build_object('now', ms, 'marches', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', f.id, 'state', f.state, 'kind', f.kind, 'mine', f.attacker = u.id,
      'from', case when f.state = 'outbound' then a.pos else d.pos end,
      'to',   case when f.state = 'outbound' then d.pos else a.pos end,
      'depart', f.leg_start_ms, 'arrive', f.arrive_ms
    ) order by f.arrive_ms)
    from wow_fleets f
    join wow_users a on a.id = f.attacker
    join wow_users d on d.id = f.target
    where f.leg_start_ms > 0 and (
      (f.kind = 'attack' and f.state in ('outbound','returning'))
      or (f.kind = 'spy' and f.state = 'outbound' and f.attacker = u.id)
    )
  ), '[]')) into out;
  return out;
end $$;
grant execute on function public.wow_marches(text) to anon, authenticated;
