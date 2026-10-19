-- ================================================================
-- APENDICE REINOS AUTOMATICOS: reinos controlados por el servidor
--   - Se crean desde el panel de Gestion (nombre + bando + dificultad).
--   - Son indistinguibles de un jugador: juegan por la misma API publica
--     (wow_build / wow_train / wow_attack / wow_throne_*), ocupan su
--     casilla del mapa, salen en el ranking y en el contador en linea.
--   - Nada en el juego revela que son automaticos.
--   - El unico sitio donde figuran es el panel de Gestion (solo admin).
--   - Un job de pg_cron (wow_bots, cada minuto) los hace jugar incluso
--     con nadie conectado.
-- ================================================================

-- tabla interna: que reinos son automaticos (nunca se expone al juego)
create table if not exists public.wow_bots(
  user_id text primary key references public.wow_users(id) on delete cascade,
  level integer not null default 2,
  agro integer not null default 35,
  token text not null default '',
  next_ms bigint not null default 0,
  last_act_ms bigint not null default 0,
  active boolean not null default true,
  created bigint not null default 0
);
alter table public.wow_bots enable row level security;
revoke all on table public.wow_bots from public, anon, authenticated;

insert into public.wow_settings(key, val) values ('bot_auto', '1')
  on conflict (key) do nothing;

-- dificultad -> semilla y caracter del reino
--   bld = nivel de todos los edificios al nacer
--   trp = tropas por tipo al nacer (solo las desbloqueadas por el cuartel)
--   agro = % de probabilidad de atacar en cada turno
--   min = minutos base entre turnos
create or replace function public._wow_bot_level(p_level integer)
returns jsonb language sql immutable as $$
  select case greatest(1, least(5, coalesce(p_level, 2)))
    when 1 then jsonb_build_object('bld',2,'trp',10, 'agro',20,'min',8)
    when 2 then jsonb_build_object('bld',3,'trp',25, 'agro',35,'min',6)
    when 3 then jsonb_build_object('bld',4,'trp',60, 'agro',55,'min',4)
    when 4 then jsonb_build_object('bld',6,'trp',150,'agro',75,'min',3)
    else        jsonb_build_object('bld',8,'trp',300,'agro',90,'min',2)
  end
$$;
revoke all on function public._wow_bot_level(integer) from public, anon, authenticated;

-- interruptor general (lo maneja el admin)
create or replace function public._wow_bot_auto()
returns integer language sql stable security definer set search_path to 'public' as $$
  select case when coalesce((select val from wow_settings where key = 'bot_auto'), '1') = '0' then 0 else 1 end
$$;
revoke all on function public._wow_bot_auto() from public, anon, authenticated;

-- ================================================================
-- panel de Gestion
-- ================================================================

-- crear un reino automatico
-- p_name = nombre del reino (el que se ve); p_king = nombre de usuario/rey (con el que entra);
-- p_alliance = alianza de nacimiento (opcional)
drop function if exists public.wow_admin_bot_create(text, text, text, integer);
create or replace function public.wow_admin_bot_create(p_token text, p_name text, p_faction text, p_level integer,
                                                       p_king text default null, p_alliance text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; nm text; king text; fac text; cfg jsonb; rid jsonb; v_id text;
        v_salt text; v_hash text; tk text; cap numeric; blv integer; trp integer; ms bigint; al text; cnt integer;
begin
  a := _wow_admin(p_token);
  nm := btrim(coalesce(p_name,''));
  king := btrim(coalesce(p_king,''));
  fac := lower(btrim(coalesce(p_faction,'')));
  al := btrim(coalesce(p_alliance,''));
  if length(nm) < 2 then raise exception 'Escribe el nombre del reino.'; end if;
  if king = '' then king := nm; end if;
  if fac not in ('alianza','horda') then raise exception 'Elige Alianza o Horda.'; end if;
  if al <> '' then
    if not exists(select 1 from wow_alliances where id = al) then raise exception 'Esa alianza no existe.'; end if;
    select count(*) into cnt from wow_users w where w.alliance = al;
    if cnt >= 5 then raise exception 'Esa alianza ya está llena (máximo 5 miembros).'; end if;
  end if;
  cfg := _wow_bot_level(p_level);
  blv := (cfg->>'bld')::int; trp := (cfg->>'trp')::int;
  ms := (extract(epoch from now())*1000)::bigint;

  -- se registra como cualquier reino (ocupa casilla, elige continente...)
  v_salt := md5(random()::text || clock_timestamp()::text);
  v_hash := md5(v_salt || 'reino-automatico');
  rid := wow_register(king, nm, fac, v_salt, v_hash, ms);
  v_id := rid->>'id';

  -- semilla: edificios, tropas (solo las que su cuartel permite) y recursos
  insert into wow_buildings(owner_id, bkey, level, finish_ms)
    select v_id, v.k, blv, 0
      from (values ('mina'),('aserradero'),('tesoreria'),('almacen'),('cuartel'),
                   ('herreria'),('fortaleza'),('mercado'),('muralla')) v(k)
    on conflict (owner_id, bkey) do update set level = excluded.level, finish_ms = 0;
  insert into wow_troops(owner_id, tkey, qty)
    select v_id, v.t, trp
      from (values ('soldado'),('arquero'),('jinete'),('mago'),('paladin'),('dragon')) v(t)
     where _wow_treq(v.t) <= blv
    on conflict (owner_id, tkey) do update set qty = excluded.qty;
  cap := _wow_cap(v_id);
  update wow_users set gold = floor(cap*0.6), wood = floor(cap*0.6), ore = floor(cap*0.6), last_ms = ms
    where id = v_id;

  -- sesion propia: juega llamando a la misma API que un jugador
  tk := md5(random()::text || clock_timestamp()::text || v_id);
  insert into wow_sessions(user_id, token, expires) values (v_id, tk, ms + 31536000000);

  insert into wow_bots(user_id, level, agro, token, next_ms, last_act_ms, active, created)
    values (v_id, greatest(1, least(5, coalesce(p_level,2))), (cfg->>'agro')::int, tk, ms, 0, true, ms);

  -- alianza de nacimiento (si se pidio y cabe)
  if al <> '' then update wow_users set alliance = al where id = v_id; end if;

  return jsonb_build_object('ok', true, 'id', v_id, 'king', v_id, 'name', nm, 'faction', fac, 'alliance', nullif(al,''),
    'pos', rid->>'pos', 'level', greatest(1, least(5, coalesce(p_level,2))), 'points', _wow_points(v_id));
end $$;
grant execute on function public.wow_admin_bot_create(text, text, text, integer, text, text) to anon, authenticated;

-- meter (o sacar) reinos automaticos de una alianza, para que luchen juntos
-- p_id vacio = todos los reinos automaticos; p_alliance vacio = dejarlos sin alianza
create or replace function public.wow_admin_bot_ally(p_token text, p_id text, p_alliance text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; r record; al text; cnt integer; hechos integer := 0; llenos integer := 0;
begin
  a := _wow_admin(p_token);
  al := btrim(coalesce(p_alliance,''));
  if al <> '' then
    if not exists(select 1 from wow_alliances where id = al) then raise exception 'Esa alianza no existe.'; end if;
  else
    al := null;
  end if;
  for r in select b.user_id from wow_bots b where coalesce(btrim(p_id),'') = '' or b.user_id = p_id loop
    if al is null then
      update wow_users set alliance = null where id = r.user_id;
      hechos := hechos + 1;
    else
      select count(*) into cnt from wow_users w where w.alliance = al and w.id <> r.user_id;
      if cnt >= 5 then
        llenos := llenos + 1;
      else
        update wow_users set alliance = al where id = r.user_id;
        hechos := hechos + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('ok', true, 'n', hechos, 'llenos', llenos, 'alliance', al);
end $$;
grant execute on function public.wow_admin_bot_ally(text, text, text) to anon, authenticated;

-- cambiar el nombre visible del reino (el nombre de usuario no se toca: es su clave)
create or replace function public.wow_admin_bot_rename(p_token text, p_id text, p_name text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; nm text;
begin
  a := _wow_admin(p_token);
  if not exists(select 1 from wow_bots where user_id = p_id) then raise exception 'Ese reino no es automático.'; end if;
  nm := btrim(coalesce(p_name,''));
  if length(nm) < 2 then raise exception 'Escribe el nombre del reino.'; end if;
  if length(nm) > 20 then raise exception 'El nombre del reino no puede pasar de 20 letras.'; end if;
  if nm ~ '[<>&"''\\]' or nm ~ '[[:cntrl:]]' then
    raise exception 'El nombre del reino solo puede llevar letras, números, espacios y guiones.'; end if;
  update wow_users set name = nm where id = p_id;
  return jsonb_build_object('ok', true, 'name', nm);
end $$;
grant execute on function public.wow_admin_bot_rename(text, text, text) to anon, authenticated;

-- listado de reinos automaticos
create or replace function public.wow_admin_bot_list(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; ms bigint; umin numeric;
begin
  a := _wow_admin(p_token);
  perform _wow_resolve();
  ms := (extract(epoch from now())*1000)::bigint;
  umin := _wow_online_min();
  return jsonb_build_object('now', ms, 'auto', _wow_bot_auto() > 0, 'protect', _wow_protect_below(),
    'bots', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', w.id, 'name', w.name, 'faction', w.faction, 'pos', w.pos, 'level', b.level,
        'alliance', w.alliance, 'atag', (select aa.tag from wow_alliances aa where aa.id = w.alliance),
        'points', _wow_points(w.id),
        'troops', coalesce((select sum(qty) from wow_troops t where t.owner_id = w.id),0),
        'nodes', (select count(*) from wow_thrones th where th.holder = w.id),
        'online', (w.last_ms >= ms - (umin*60000)::bigint),
        'last', w.last_ms, 'next', b.next_ms, 'active', b.active,
        'seed', _wow_bot_level(b.level))
        order by b.created)
      from wow_bots b join wow_users w on w.id = b.user_id
    ), '[]'::jsonb));
end $$;
grant execute on function public.wow_admin_bot_list(text) to anon, authenticated;

-- cambiar dificultad (y su agresividad)
create or replace function public.wow_admin_bot_set(p_token text, p_id text, p_level integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; cfg jsonb; lv integer;
begin
  a := _wow_admin(p_token);
  if not exists(select 1 from wow_bots where user_id = p_id) then raise exception 'Ese reino no es automático.'; end if;
  lv := greatest(1, least(5, coalesce(p_level,2)));
  cfg := _wow_bot_level(lv);
  update wow_bots set level = lv, agro = (cfg->>'agro')::int where user_id = p_id;
  return jsonb_build_object('ok', true, 'level', lv);
end $$;
grant execute on function public.wow_admin_bot_set(text, text, integer) to anon, authenticated;

-- pausar / reanudar (deja de jugar pero el reino sigue existiendo)
create or replace function public.wow_admin_bot_stop(p_token text, p_id text, p_on boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if not exists(select 1 from wow_bots where user_id = p_id) then raise exception 'Ese reino no es automático.'; end if;
  update wow_bots set active = coalesce(p_on, false) where user_id = p_id;
  return jsonb_build_object('ok', true, 'active', coalesce(p_on, false));
end $$;
grant execute on function public.wow_admin_bot_stop(text, text, boolean) to anon, authenticated;

-- borrar el reino automatico (limpia tronos y todo lo suyo)
create or replace function public.wow_admin_bot_del(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if not exists(select 1 from wow_bots where user_id = p_id) then raise exception 'Ese reino no es automático.'; end if;
  perform _wow_delete_kingdom(p_id);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_admin_bot_del(text, text) to anon, authenticated;

-- borrar TODOS los reinos automaticos
create or replace function public.wow_admin_bot_purge(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; r record; n integer := 0;
begin
  a := _wow_admin(p_token);
  for r in select user_id from wow_bots loop
    perform _wow_delete_kingdom(r.user_id);
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'deleted', n);
end $$;
grant execute on function public.wow_admin_bot_purge(text) to anon, authenticated;

-- jugar solos (interruptor general)
create or replace function public.wow_admin_bot_auto(p_token text, p_on boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  insert into wow_settings(key, val) values ('bot_auto', case when coalesce(p_on,false) then '1' else '0' end)
    on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'auto', coalesce(p_on,false));
end $$;
grant execute on function public.wow_admin_bot_auto(text, boolean) to anon, authenticated;

-- que jueguen ahora mismo (ignora la espera de cada uno)
create or replace function public.wow_admin_bot_run(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  return wow_bots_tick(true);
end $$;
grant execute on function public.wow_admin_bot_run(text) to anon, authenticated;

-- ================================================================
-- cerebro
-- ================================================================

-- tropas que manda a una mision: una fraccion de cada tipo que tenga
create or replace function public._wow_bot_army(p_id text, p_frac numeric)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce(jsonb_object_agg(tkey, q), '{}'::jsonb) from (
    select tkey, greatest(1, floor(qty * coalesce(p_frac, 0.6)))::int q
      from wow_troops where owner_id = p_id and qty > 0
  ) s
$$;
revoke all on function public._wow_bot_army(text, numeric) from public, anon, authenticated;

-- un turno de un reino automatico
create or replace function public._wow_bot_act(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  b wow_bots; cfg jsonb; lvl integer; agro integer; base integer;
  ms bigint; tok text; tk text; bk text; cuartel integer; prot numeric; ua text;
  mypts numeric; army jsonb; tgt record; node integer; nx bigint; q integer;
begin
  select * into b from wow_bots where user_id = p_id and active;
  if b.user_id is null then return; end if;
  tok := b.token;
  cfg := _wow_bot_level(b.level);
  lvl := (cfg->>'bld')::int; agro := (cfg->>'agro')::int; base := (cfg->>'min')::int;
  ms := (extract(epoch from now())*1000)::bigint;

  -- 1) producir y terminar lo que tenga en marcha (y marcar last_ms = en linea)
  perform _wow_tick(p_id);

  -- 2) obra: el edificio mas atrasado que pueda pagar
  if not exists (select 1 from wow_queue q0 where q0.owner_id = p_id and q0.kind = 'build') then
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

  -- 3) entrenar: la tropa mas fuerte que su cuartel le permita
  if not exists (select 1 from wow_queue q0 where q0.owner_id = p_id and q0.kind = 'train') then
    select coalesce(max(level),0) into cuartel from wow_buildings where owner_id = p_id and bkey = 'cuartel';
    for tk in select v.t from (values ('dragon',1),('paladin',2),('mago',3),
                                      ('jinete',4),('arquero',5),('soldado',6)) v(t,ord)
               order by v.ord
    loop
      if cuartel >= _wow_treq(tk) then
        q := greatest(5, ((cfg->>'trp')::int) / 3);
        begin
          perform wow_train(tok, tk, q);
          exit;
        exception when others then exit;
        end;
      end if;
    end loop;
  end if;

  -- 4) accion de guerra
  if random()*100 < agro then
    mypts := _wow_points(p_id);
    army := _wow_bot_army(p_id, 0.6);
    if army <> '{}'::jsonb then
      -- a) conquistar una aldea libre (mejor botin, menos conflicto)
      select th.node into node from wow_thrones th
        where th.kind = 'aldea'
          and th.holder is distinct from p_id
          and coalesce((select sum((x.value)::int) from jsonb_each_text(th.garrison) x), 0) = 0
        order by random() limit 1;
      if node is not null then
        begin perform wow_throne_attack(tok, node, army); exception when others then null; end;
      else
        prot := _wow_protect_below();
        select w.alliance into ua from wow_users w where w.id = p_id;
        tgt := null;
        -- b) si su alianza esta en guerra, va a por el enemigo (asi luchan juntos y suman para la alianza)
        if ua is not null then
          select eu.id into tgt from wow_ally_wars wr
            join wow_users eu on eu.alliance = case when wr.a = ua then wr.b else wr.a end
            where wr.active and (wr.a = ua or wr.b = ua)
              and eu.active and not eu.is_admin and eu.id <> p_id
              and (prot = 0 or (_wow_points(eu.id) >= prot and mypts - _wow_points(eu.id) < prot))
            order by _wow_points(eu.id) asc, random() limit 1;
        end if;
        -- c) si no, al rival mas debil que siga siendo un objetivo valido (nunca de su propia alianza)
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

  -- 5) cobrar el tesoro de lo que ya controle
  if random() < 0.35 then
    select th.node into node from wow_thrones th where th.holder = p_id order by random() limit 1;
    if node is not null then
      begin perform wow_throne_claim(tok, node); exception when others then null; end;
    end if;
  end if;

  -- 6) los mas fuertes refuerzan lo que tienen
  if lvl >= 6 and random() < 0.2 then
    select th.node into node from wow_thrones th where th.holder = p_id order by random() limit 1;
    if node is not null then
      army := _wow_bot_army(p_id, 0.4);
      if army <> '{}'::jsonb then
        begin perform wow_throne_reinforce(tok, node, army); exception when others then null; end;
      end if;
    end if;
  end if;

  -- 7) cadencia humana: turnos irregulares y, a veces, un descanso largo
  if random() < 0.12 then
    nx := ms + (30*60000 + (random()*90*60000)::bigint)::bigint;   -- 30-120 min fuera
  else
    nx := ms + (base*60000*(0.5 + random()))::bigint;              -- 0.5x - 1.5x
  end if;
  update wow_bots set next_ms = nx, last_act_ms = ms where user_id = p_id;
end $$;
revoke all on function public._wow_bot_act(text) from public, anon, authenticated;

-- turno global: avanza el mundo y actua sobre los que les toca
create or replace function public.wow_bots_tick(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare b record; ms bigint; n integer := 0;
begin
  perform _wow_resolve();       -- las flotas aterrizan aunque no haya nadie conectado
  if _wow_bot_auto() = 0 then return jsonb_build_object('ok', true, 'auto', false, 'acted', 0); end if;
  ms := (extract(epoch from now())*1000)::bigint;
  for b in select user_id from wow_bots where active and (p_force or next_ms <= ms) loop
    begin
      perform _wow_bot_act(b.user_id);
      n := n + 1;
    exception when others then
      -- un reino con problemas no debe detener a los demas
      update wow_bots set next_ms = ms + 600000 where user_id = b.user_id;
    end;
  end loop;
  return jsonb_build_object('ok', true, 'auto', true, 'acted', n);
end $$;
revoke all on function public.wow_bots_tick(boolean) from public, anon, authenticated;

-- ================================================================
-- que jueguen solos: job de pg_cron cada minuto
-- ================================================================
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule('wow_bots');
    exception when others then null;
    end;
    perform cron.schedule('wow_bots', '* * * * *', 'select public.wow_bots_tick();');
  end if;
end $$;
