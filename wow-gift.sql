-- ================================================================
-- APENDICE CARAVANA DE ALIADOS: envio de recursos a un companero de
-- alianza con un carruaje que viaja de ida y vuelta.
--   - wow_ally_gift: envia recursos (oro/madera/mineral) a un aliado.
--     Se cobran al enviar. Solo aliados, nunca a uno mismo.
--   - _wow_resolve (override): al llegar el carruaje entrega los
--     recursos al aliado (lo que no quepa en su almacen se pierde) y
--     vuelve a casa; al volver, el carruaje desaparece sin devolver
--     nada (los recursos ya se entregaron).
-- ================================================================

-- enviar recursos a un aliado
create or replace function public.wow_ally_gift(p_token text, p_target text, p_gold numeric, p_wood numeric, p_ore numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_users; g numeric; w numeric; o numeric; travel integer; ms bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  select * into t from wow_users where id = p_target and active;
  if t.id is null then raise exception 'Ese reino ya no existe.'; end if;
  if t.id = u.id then raise exception 'No puedes enviarte recursos a ti mismo.'; end if;
  if u.alliance is null or t.alliance is null or u.alliance <> t.alliance then
    raise exception 'Solo puedes enviar recursos a un aliado.'; end if;
  g := floor(greatest(coalesce(p_gold,0),0));
  w := floor(greatest(coalesce(p_wood,0),0));
  o := floor(greatest(coalesce(p_ore,0),0));
  if g + w + o <= 0 then raise exception 'Elige cuánto quieres enviar.'; end if;
  if g > u.gold or w > u.wood or o > u.ore then
    raise exception 'No tienes tantos recursos.'; end if;
  update wow_users set gold = gold - g, wood = wood - w, ore = ore - o where id = u.id;
  travel := _wow_travel(u.pos, t.pos);
  ms := (extract(epoch from now())*1000)::bigint;
  insert into wow_fleets(attacker, target, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, t.id, '{}'::jsonb, jsonb_build_object('gold',g,'wood',w,'ore',o), 'outbound', 'gift', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name);
end $$;
revoke all on function public.wow_ally_gift(text, text, numeric, numeric, numeric) from public;
grant execute on function public.wow_ally_gift(text, text, numeric, numeric, numeric) to anon, authenticated;

-- resolucion de marchas: anade el carruaje de recursos
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
    sim := _wow_sim(f.troops, djson, wall, f.id*7919 + (ms/1000),
                    1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort);
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
end $$;
revoke all on function public._wow_resolve() from public, anon, authenticated;
