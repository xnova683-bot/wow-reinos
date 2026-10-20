-- ================================================================
-- REINOS DE AZEROTH (tema WoW, estilo Xnova/OGame)
--   - Cada jugador es un reino con recursos que suben solos
--   - Edificios mejorable con temporizador (cola de construcción)
--   - Tropas que se entrenan con cola
--   - Ranking de todos los reinos (multijugador; ataques en la v2)
-- Recursos: Oro, Madera, Mineral. Facción: Alianza / Horda.
-- ================================================================

-- ---------- empezar de cero ----------
drop function if exists public._wow_key(text);
drop function if exists public._wow_sess(text);
drop function if exists public._wow_bcost(text, integer);
drop function if exists public._wow_btime(text, integer);
drop function if exists public._wow_bprod(text, integer);
drop function if exists public._wow_cap(text);
drop function if exists public._wow_rate(text);
drop function if exists public._wow_tcost(text);
drop function if exists public._wow_ttime(text);
drop function if exists public._wow_tick(text);
drop function if exists public.wow_register(text, text, text, text, bigint);
drop function if exists public.wow_register(text, text, text, text, text, bigint);
drop function if exists public.wow_login(text, text);
drop function if exists public.wow_logout(text);
drop function if exists public.wow_check(text);
drop function if exists public.wow_state(text);
drop function if exists public.wow_build(text, text);
drop function if exists public.wow_train(text, text, integer);
drop function if exists public.wow_leaderboard(text);
drop function if exists public.wow_map(text);
drop function if exists public.wow_alliance_create(text, text, text, text);
drop function if exists public.wow_alliance_join(text, text);
drop function if exists public.wow_alliance_leave(text);
drop function if exists public.wow_alliance_list(text);
drop function if exists public.wow_alliance_info(text, text);
drop function if exists public.wow_chat_send(text, text);
drop function if exists public.wow_chat(text, bigint);
drop function if exists public.wow_buildings(text);
drop table if exists public.wow_chat cascade;
drop table if exists public.wow_alliances cascade;
drop table if exists public.wow_queue cascade;
drop table if exists public.wow_troops cascade;
drop table if exists public.wow_buildings cascade;
drop table if exists public.wow_sessions cascade;
drop table if exists public.wow_reports cascade;
drop table if exists public.wow_fleets cascade;
drop table if exists public.wow_users cascade;

-- ---------- tablas ----------
create table public.wow_users(
  id text primary key,
  name text not null,
  name_key text not null unique,
  faction text not null default 'alianza',
  salt text not null,
  hash text not null,
  active boolean not null default true,
  created bigint not null default 0,
  last_ms bigint not null default 0,
  gold numeric(16,2) not null default 500,
  wood numeric(16,2) not null default 500,
  ore numeric(16,2) not null default 500,
  cup numeric(16,2) not null default 0,
  pos integer not null default 0,
  alliance text
);
create table public.wow_sessions(
  id bigserial primary key,
  user_id text not null references public.wow_users(id) on delete cascade,
  token text not null unique,
  expires bigint not null default 0
);
create table public.wow_buildings(
  owner_id text not null references public.wow_users(id) on delete cascade,
  bkey text not null,
  level integer not null default 0,
  finish_ms bigint not null default 0,
  primary key (owner_id, bkey)
);
create table public.wow_troops(
  owner_id text not null references public.wow_users(id) on delete cascade,
  tkey text not null,
  qty integer not null default 0,
  primary key (owner_id, tkey)
);
create table public.wow_queue(
  owner_id text not null references public.wow_users(id) on delete cascade,
  kind text not null default '',
  ref text not null default '',
  qty integer not null default 0,
  unit_ms bigint not null default 0,
  start_ms bigint not null default 0,
  finish_ms bigint not null default 0,
  primary key (owner_id, kind));
create table public.wow_alliances(
  id text primary key,
  name text not null,
  tag text not null,
  leader text not null,
  created bigint not null default 0,
  descr text not null default ''
);
create table public.wow_chat(
  id bigserial primary key,
  alliance text not null references public.wow_alliances(id) on delete cascade,
  user_id text not null,
  name text not null,
  msg text not null,
  created bigint not null default 0
);

alter table public.wow_users enable row level security;
alter table public.wow_sessions enable row level security;
alter table public.wow_buildings enable row level security;
alter table public.wow_troops enable row level security;
alter table public.wow_queue enable row level security;
alter table public.wow_alliances enable row level security;
alter table public.wow_chat enable row level security;

-- ---------- utilidades ----------
create or replace function public._wow_key(p_name text)
returns text
language sql immutable as $$
  select lower(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'))
$$;

create or replace function public._wow_sess(p_token text)
returns wow_users
language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  select u2.* into u from wow_sessions s join wow_users u2 on u2.id = s.user_id
   where s.token = p_token and s.expires > (extract(epoch from now())*1000)::bigint and u2.active
   limit 1;
  return u;
end $$;

revoke all on function public._wow_key(text) from public, anon, authenticated;
revoke all on function public._wow_sess(text) from public, anon, authenticated;

-- ---------- configuración del juego ----------
-- costo del siguiente nivel de un edificio (factor 1.55 por nivel)
create or replace function public._wow_bcost(p_key text, p_level integer)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'gold', round((case p_key
      when 'mina' then 0 when 'aserradero' then 0 when 'tesoreria' then 80
      when 'almacen' then 50 when 'cuartel' then 70 when 'muralla' then 90 else 0 end) * power(1.55, p_level)),
    'wood', round((case p_key
      when 'mina' then 40 when 'aserradero' then 60 when 'tesoreria' then 60
      when 'almacen' then 50 when 'cuartel' then 70 when 'muralla' then 60 else 0 end) * power(1.55, p_level)),
    'ore',  round((case p_key
      when 'mina' then 60 when 'aserradero' then 40 when 'tesoreria' then 40
      when 'almacen' then 50 when 'cuartel' then 50 when 'muralla' then 80 else 0 end) * power(1.55, p_level)))
$$;

-- segundos que tarda subir de nivel (factor 1.4 por nivel)
create or replace function public._wow_btime(p_key text, p_level integer)
returns integer language sql immutable as $$
  select greatest(round((case p_key
    when 'mina' then 20 when 'aserradero' then 20 when 'tesoreria' then 25
    when 'almacen' then 30 when 'cuartel' then 35 when 'muralla' then 40 else 30 end) * power(1.4, p_level)), 1)
$$;

-- por hora: oro (tesorería), madera (aserradero), mineral (mina) / capacidad (almacén)
create or replace function public._wow_bprod(p_key text, p_level integer)
returns numeric language sql immutable as $$
  select case when p_key = 'almacen' then 2000 + 1500 * p_level
              when p_key in ('mina','aserradero','tesoreria') then 30 + 25 * p_level
              else 0 end
$$;

create or replace function public._wow_cap(p_owner text)
returns numeric language plpgsql security definer set search_path to 'public' as $$
declare lv integer;
begin
  select coalesce(max(level),0) into lv from wow_buildings where owner_id = p_owner and bkey = 'almacen';
  return 2000 + 1500 * lv;
end $$;

create or replace function public._wow_rate(p_owner text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare g integer; w integer; o integer;
begin
  select coalesce(max(case when bkey='tesoreria' then level end),0),
         coalesce(max(case when bkey='aserradero' then level end),0),
         coalesce(max(case when bkey='mina' then level end),0)
    into g,w,o from wow_buildings where owner_id = p_owner;
  return jsonb_build_object('gold', 30+25*g, 'wood', 30+25*w, 'ore', 30+25*o, 'cup', 0);
end $$;

-- costo por unidad de tropa
create or replace function public._wow_tcost(p_key text)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'gold', (case p_key when 'soldado' then 40 when 'arquero' then 50 when 'jinete' then 80 when 'mago' then 120 else 0 end),
    'wood', (case p_key when 'soldado' then 20 when 'arquero' then 40 when 'jinete' then 30 when 'mago' then 20 else 0 end),
    'ore',  (case p_key when 'soldado' then 30 when 'arquero' then 20 when 'jinete' then 60 when 'mago' then 100 else 0 end))
$$;

-- segundos por unidad entrenada
create or replace function public._wow_ttime(p_key text)
returns integer language sql immutable as $$
  select case p_key when 'soldado' then 6 when 'arquero' then 8 when 'jinete' then 12 when 'mago' then 18 else 10 end
$$;

revoke all on function public._wow_bcost(text, integer) from public, anon, authenticated;
revoke all on function public._wow_btime(text, integer) from public, anon, authenticated;
revoke all on function public._wow_bprod(text, integer) from public, anon, authenticated;
revoke all on function public._wow_cap(text) from public, anon, authenticated;
revoke all on function public._wow_rate(text) from public, anon, authenticated;
revoke all on function public._wow_tcost(text) from public, anon, authenticated;
revoke all on function public._wow_ttime(text) from public, anon, authenticated;

-- ---------- avance del tiempo (recursos + cola) ----------
create or replace function public._wow_tick(p_owner text)
returns wow_users
language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ms bigint; el numeric; cap numeric; rate jsonb; q wow_queue; done integer;
begin
  select * into u from wow_users where id = p_owner for update;
  if u.id is null then return u; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  el := greatest(ms - u.last_ms, 0)::numeric;

  if exists (select 1 from wow_queue where owner_id = p_owner and kind = 'build' and finish_ms <= ms) then
    update wow_buildings set level = level + 1, finish_ms = 0
     where owner_id = p_owner and bkey = (select ref from wow_queue where owner_id = p_owner and kind = 'build');
    delete from wow_queue where owner_id = p_owner and kind = 'build';
  end if;
  select * into q from wow_queue where owner_id = p_owner and kind = 'train';
  if q is not null and q.owner_id is not null and q.unit_ms > 0 then
    done := least(q.qty, floor((ms - q.start_ms) / q.unit_ms));
    if done > 0 then
      insert into wow_troops(owner_id, tkey, qty) values (p_owner, q.ref, done)
        on conflict (owner_id, tkey) do update set qty = wow_troops.qty + excluded.qty;
      update wow_queue set qty = qty - done, start_ms = start_ms + done * unit_ms
       where owner_id = p_owner and kind = 'train';
      delete from wow_queue where owner_id = p_owner and kind = 'train' and qty <= 0;
    end if;
  end if;

  select * into q from wow_queue where owner_id = p_owner;
  rate := _wow_rate(p_owner);
  cap := _wow_cap(p_owner);
  update wow_users set
      gold = least(u.gold + el/3600000.0 * (rate->>'gold')::numeric, cap),
      wood = least(u.wood + el/3600000.0 * (rate->>'wood')::numeric, cap),
      ore  = least(u.ore  + el/3600000.0 * (rate->>'ore')::numeric, cap),
      last_ms = ms
    where id = p_owner returning * into u;
  return u;
end $$;

revoke all on function public._wow_tick(text) from public, anon, authenticated;

-- ---------- cuenta ----------
create or replace function public.wow_register(p_name text, p_realm text, p_faction text, p_salt text, p_hash text, p_now bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare vname text; vrealm text; vkey text; vfac text;
begin
  vname := btrim(coalesce(p_name,'')); vkey := _wow_key(vname); vrealm := btrim(coalesce(p_realm,''));
  if length(vkey) < 2 then raise exception 'Escribe un nombre de rey (así entrarás después).'; end if;
  if length(vrealm) < 2 then raise exception 'Escribe el nombre de tu reino.'; end if;
  vfac := lower(btrim(coalesce(p_faction,'')));
  if vfac not in ('alianza','horda') then raise exception 'Elige Alianza o Horda.'; end if;
  if coalesce(p_salt,'') = '' or coalesce(p_hash,'') = '' then raise exception 'Faltan datos de seguridad.'; end if;
  if exists(select 1 from wow_users where name_key = vkey) then
    raise exception 'Ese nombre de rey ya está en uso. Prueba con otro.'; end if;
  insert into wow_users (id, name, name_key, faction, salt, hash, active, created, last_ms, gold, wood, ore, pos, alliance)
  values (vkey, vrealm, vkey, vfac, p_salt, p_hash, true, p_now, p_now, 500, 500, 500,
          (select coalesce(max(pos), -1) + 1 from wow_users), null);
  return jsonb_build_object('ok', true, 'id', vkey);
end $$;

create or replace function public.wow_login(p_name text, p_hash text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; tok text; exp bigint;
begin
  select * into u from wow_users where name_key = _wow_key(p_name) limit 1;
  if u.id is null or u.hash <> p_hash or not u.active then
    raise exception 'Nombre o contraseña incorrectos.'; end if;
  tok := md5(random()::text || clock_timestamp()::text);
  exp := (extract(epoch from now())*1000)::bigint + 30::bigint * 86400000;
  delete from wow_sessions where user_id = u.id;
  insert into wow_sessions (user_id, token, expires) values (u.id, tok, exp);
  return jsonb_build_object('ok', true, 'id', u.id, 'name', u.name, 'faction', u.faction, 'token', tok, 'expires', exp);
end $$;

create or replace function public.wow_logout(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
begin
  delete from wow_sessions where token = p_token;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.wow_check(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then return null; end if;
  return jsonb_build_object('id', u.id, 'name', u.name, 'faction', u.faction);
end $$;

grant execute on function public.wow_register(text, text, text, text, text, bigint) to anon, authenticated;
grant execute on function public.wow_login(text, text) to anon, authenticated;
grant execute on function public.wow_logout(text) to anon, authenticated;
grant execute on function public.wow_check(text) to anon, authenticated;

-- ---------- estado del reino ----------
create or replace function public.wow_state(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; blds jsonb; trs jsonb; que jsonb; cap numeric; rate jsonb; ms bigint; pts integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  cap := _wow_cap(u.id); rate := _wow_rate(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select coalesce(jsonb_agg(jsonb_build_object('key', v.k, 'level', coalesce(b.level,0),
             'cost', _wow_bcost(v.k, coalesce(b.level,0)), 'time', _wow_btime(v.k, coalesce(b.level,0)),
             'prod', _wow_bprod(v.k, coalesce(b.level,0))) order by v.ord), '[]') into blds
    from (values ('mina',1),('aserradero',2),('tesoreria',3),('almacen',4),('cuartel',5),('muralla',6)) v(k,ord)
    left join wow_buildings b on b.owner_id = u.id and b.bkey = v.k;
  select coalesce(jsonb_agg(jsonb_build_object('key', v.t, 'qty', coalesce(t.qty,0),
             'cost', _wow_tcost(v.t), 'time', _wow_ttime(v.t)) order by v.ord), '[]') into trs
    from (values ('soldado',1),('arquero',2),('jinete',3),('mago',4)) v(t,ord)
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

-- ---------- construir ----------
create or replace function public.wow_build(p_token text, p_key text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; lvl integer; c jsonb; t integer; ms bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  if exists(select 1 from wow_queue where owner_id = u.id) then
    raise exception 'Ya tienes algo en construcción.'; end if;
  if coalesce(p_key,'') not in ('mina','aserradero','tesoreria','almacen','cuartel','muralla') then
    raise exception 'Edificio no válido.'; end if;
  select coalesce(max(level),0) into lvl from wow_buildings where owner_id = u.id and bkey = p_key;
  c := _wow_bcost(p_key, lvl);
  if u.gold < (c->>'gold')::numeric then raise exception 'No tienes suficiente Oro.'; end if;
  if u.wood < (c->>'wood')::numeric then raise exception 'No tienes suficiente Madera.'; end if;
  if u.ore < (c->>'ore')::numeric then raise exception 'No tienes suficiente Mineral.'; end if;
  update wow_users set gold = gold - (c->>'gold')::numeric, wood = wood - (c->>'wood')::numeric,
         ore = ore - (c->>'ore')::numeric where id = u.id;
  t := _wow_btime(p_key, lvl);
  ms := (extract(epoch from now())*1000)::bigint;
  insert into wow_buildings (owner_id, bkey, level, finish_ms) values (u.id, p_key, lvl, ms + t*1000)
    on conflict (owner_id, bkey) do update set level = excluded.level, finish_ms = excluded.finish_ms;
  insert into wow_queue (owner_id, kind, ref, qty, unit_ms, start_ms, finish_ms)
    values (u.id, 'build', p_key, 0, 0, ms, ms + t*1000);
  return jsonb_build_object('ok', true, 'key', p_key, 'finish', ms + t*1000);
end $$;

grant execute on function public.wow_build(text, text) to anon, authenticated;

-- ---------- entrenar tropas ----------
create or replace function public.wow_train(p_token text, p_key text, p_qty integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; c jsonb; qty integer; um bigint; ms bigint; lv integer; tg numeric; tw numeric; tro numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  if exists(select 1 from wow_queue where owner_id = u.id) then
    raise exception 'Ya estás entrenando o construyendo algo.'; end if;
  if coalesce(p_key,'') not in ('soldado','arquero','jinete','mago') then raise exception 'Tropa no válida.'; end if;
  select coalesce(max(level),0) into lv from wow_buildings where owner_id = u.id and bkey = 'cuartel';
  if lv < 1 then raise exception 'Necesitas al menos un Cuartel para entrenar tropas.'; end if;
  qty := greatest(coalesce(p_qty,0), 0);
  if qty < 1 then raise exception 'Escribe cuántas tropas entrenar.'; end if;
  if qty > 100000 then raise exception 'Máximo 100.000 tropas a la vez.'; end if;
  c := _wow_tcost(p_key);
  tg := (c->>'gold')::numeric * qty; tw := (c->>'wood')::numeric * qty; tro := (c->>'ore')::numeric * qty;
  if u.gold < tg then raise exception 'No tienes suficiente Oro.'; end if;
  if u.wood < tw then raise exception 'No tienes suficiente Madera.'; end if;
  if u.ore < tro then raise exception 'No tienes suficiente Mineral.'; end if;
  update wow_users set gold = gold - tg, wood = wood - tw, ore = ore - tro where id = u.id;
  um := _wow_ttime(p_key)::bigint * 1000;
  ms := (extract(epoch from now())*1000)::bigint;
  insert into wow_queue (owner_id, kind, ref, qty, unit_ms, start_ms, finish_ms)
    values (u.id, 'train', p_key, qty, um, ms, ms + qty*um);
  return jsonb_build_object('ok', true, 'key', p_key, 'qty', qty, 'finish', ms + qty*um);
end $$;

grant execute on function public.wow_train(text, text, integer) to anon, authenticated;

-- ---------- ranking ----------
create or replace function public.wow_leaderboard(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'name', s.name, 'faction', s.faction, 'points', s.lsum*100 + s.tsum,
             'level_sum', s.lsum, 'troops', s.tsum, 'created', s.created,
             'alliance', s.atag, 'me', s.id = u.id) order by s.lsum*100 + s.tsum desc, s.created), '[]') into out
    from (
      select w.id, w.name, w.faction, w.created, coalesce(al.tag,'') atag,
             coalesce((select sum(b.level) from wow_buildings b where b.owner_id = w.id),0) lsum,
             coalesce((select sum(t.qty) from wow_troops t where t.owner_id = w.id),0) tsum
        from wow_users w left join wow_alliances al on al.id = w.alliance where w.active
    ) s;
  return out;
end $$;

grant execute on function public.wow_leaderboard(text) to anon, authenticated;

-- ---------- salt del nombre (para que el frontend calcule el hash) ----------
create or replace function public.wow_salt(p_name text)
returns text language plpgsql security definer set search_path to 'public' as $$
declare s text;
begin
  select salt into s from wow_users where name_key = _wow_key(p_name) limit 1;
  return coalesce(s, '');
end $$;
grant execute on function public.wow_salt(text) to anon, authenticated;

-- ---------- cambiar contraseña ----------
create or replace function public.wow_change_password(p_token text, p_salt text, p_hash text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if coalesce(p_salt,'') = '' or coalesce(p_hash,'') = '' then raise exception 'Faltan datos de seguridad.'; end if;
  update wow_users set salt = p_salt, hash = p_hash where id = u.id;
  delete from wow_sessions where user_id = u.id and token <> p_token;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_change_password(text, text, text) to anon, authenticated;

-- ================================================================
-- MAPA DE REINOS + ALIANZAS + CHAT
-- ================================================================
create or replace function public._wow_points(p_owner text)
returns integer language sql security definer set search_path to 'public' as $$
  select (select coalesce(sum(level),0) from wow_buildings where owner_id = p_owner) * 100
       + (select coalesce(sum(qty),0) from wow_troops where owner_id = p_owner)
$$;
revoke all on function public._wow_points(text) from public, anon, authenticated;

-- ---------- mapa: todos los reinos con su posición ----------
create or replace function public.wow_map(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'pos', w.pos, 'name', w.name, 'faction', w.faction,
             'alliance', coalesce(al.tag,''), 'points', _wow_points(w.id), 'me', w.id = u.id)
           order by w.pos), '[]') into out
    from wow_users w left join wow_alliances al on al.id = w.alliance
   where w.active;
  return out;
end $$;
grant execute on function public.wow_map(text) to anon, authenticated;

-- ---------- crear alianza ----------
create or replace function public.wow_alliance_create(p_token text, p_name text, p_tag text, p_descr text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; vname text; vkey text; vtag text;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is not null then raise exception 'Ya estás en una alianza. Sal de la actual primero.'; end if;
  vname := btrim(coalesce(p_name,''));
  if length(vname) < 3 then raise exception 'El nombre de la alianza debe tener al menos 3 letras.'; end if;
  vtag := upper(regexp_replace(btrim(coalesce(p_tag,'')), '[^A-Za-z0-9]', '', 'g'));
  if length(vtag) < 2 or length(vtag) > 5 then raise exception 'La etiqueta debe tener entre 2 y 5 letras o números.'; end if;
  vkey := _wow_key(vname);
  if exists(select 1 from wow_alliances where id = vkey) then
    raise exception 'Ya existe una alianza con ese nombre.'; end if;
  insert into wow_alliances (id, name, tag, leader, created, descr)
  values (vkey, vname, vtag, u.id, (extract(epoch from now())*1000)::bigint, left(coalesce(p_descr,''), 200));
  update wow_users set alliance = vkey where id = u.id;
  return jsonb_build_object('ok', true, 'id', vkey, 'tag', vtag);
end $$;
grant execute on function public.wow_alliance_create(text, text, text, text) to anon, authenticated;

-- ---------- unirse ----------
create or replace function public.wow_alliance_join(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is not null then raise exception 'Ya estás en una alianza. Sal de la actual primero.'; end if;
  if not exists(select 1 from wow_alliances where id = p_id) then
    raise exception 'Esa alianza ya no existe.'; end if;
  update wow_users set alliance = p_id where id = u.id;
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;
grant execute on function public.wow_alliance_join(text, text) to anon, authenticated;

-- ---------- salir ----------
create or replace function public.wow_alliance_leave(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; vlea text; vnext text; vcnt integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'No estás en ninguna alianza.'; end if;
  select leader into vlea from wow_alliances where id = u.alliance;
  if vlea = u.id then
    select count(*) into vcnt from wow_users where alliance = u.alliance and id <> u.id;
    if vcnt = 0 then
      delete from wow_alliances where id = u.alliance;
    else
      select id into vnext from wow_users where alliance = u.alliance and id <> u.id order by created limit 1;
      update wow_alliances set leader = vnext where id = u.alliance;
    end if;
  end if;
  update wow_users set alliance = null where id = u.id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_alliance_leave(text) to anon, authenticated;

-- ---------- listar alianzas ----------
create or replace function public.wow_alliance_list(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', a.id, 'name', a.name, 'tag', a.tag, 'descr', a.descr,
             'members', (select count(*) from wow_users w where w.alliance = a.id),
             'points', (select coalesce(sum(_wow_points(w.id)),0) from wow_users w where w.alliance = a.id),
             'mine', a.id = u.alliance)
           order by (select coalesce(sum(_wow_points(w.id)),0) from wow_users w where w.alliance = a.id) desc, a.created), '[]') into out
    from wow_alliances a;
  return out;
end $$;
grant execute on function public.wow_alliance_list(text) to anon, authenticated;

-- ---------- info de una alianza ----------
create or replace function public.wow_alliance_info(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a wow_alliances; mem jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select * into a from wow_alliances where id = p_id;
  if a.id is null then raise exception 'Esa alianza ya no existe.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'name', w.name, 'faction', w.faction, 'points', _wow_points(w.id),
             'leader', w.id = a.leader, 'me', w.id = u.id)
           order by (w.id = a.leader) desc, w.created), '[]') into mem
    from wow_users w where w.alliance = a.id;
  return jsonb_build_object('id', a.id, 'name', a.name, 'tag', a.tag, 'descr', a.descr,
    'leader', (select name from wow_users where id = a.leader),
    'members', mem, 'is_member', u.alliance = a.id);
end $$;
grant execute on function public.wow_alliance_info(text, text) to anon, authenticated;

-- ---------- chat de alianza ----------
create or replace function public.wow_chat_send(p_token text, p_msg text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; vmsg text;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'Entra a una alianza para usar el chat.'; end if;
  vmsg := btrim(coalesce(p_msg,''));
  if vmsg = '' then raise exception 'Escribe un mensaje.'; end if;
  if length(vmsg) > 300 then vmsg := left(vmsg, 300); end if;
  insert into wow_chat (alliance, user_id, name, msg, created)
  values (u.alliance, u.id, u.name, vmsg, (extract(epoch from now())*1000)::bigint);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_chat_send(text, text) to anon, authenticated;

create or replace function public.wow_chat(p_token text, p_since bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then return '[]'::jsonb; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'name', c.name, 'msg', c.msg, 'created', c.created, 'me', c.user_id = u.id) order by c.id), '[]') into out
    from (select * from wow_chat where alliance = u.alliance
           and (coalesce(p_since,0) = 0 or created > coalesce(p_since,0))
           order by id desc limit 60) c;
  return out;
end $$;
grant execute on function public.wow_chat(text, bigint) to anon, authenticated;

-- ================================================================
-- APENDICE PvP v3: COMBATE POR RONDAS (contadores + moral) + ESPIONAJE
--   (generado desde wow-pvp.sql)
-- ================================================================
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
alter table public.wow_fleets add column if not exists node integer;
alter table public.wow_users add column if not exists is_admin boolean not null default false;
alter table public.wow_users add column if not exists cup numeric(16,2) not null default 0;
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
-- mapa 2400x2400 con 4 continentes: coordenadas de cada casilla de castillo
-- (mismas constantes que el frontend: 20 slots x 4 continentes, escala 0.72/0.60)
create or replace function public._wow_slot(p integer)
returns double precision[] language sql immutable as $$
  select case p
    when 0 then '{-500,-380}'::double precision[]
    when 1 then '{-180,-520}'   when 2 then '{140,-490}'   when 3 then '{430,-430}'
    when 4 then '{600,-170}'    when 5 then '{620,120}'    when 6 then '{470,380}'
    when 7 then '{200,520}'     when 8 then '{-90,560}'    when 9 then '{-380,500}'
    when 10 then '{-600,250}'   when 11 then '{-620,-80}'  when 12 then '{-360,-150}'
    when 13 then '{-140,-300}'  when 14 then '{120,-220}'  when 15 then '{350,-120}'
    when 16 then '{330,170}'    when 17 then '{60,250}'    when 18 then '{-260,200}'
    when 19 then '{250,-320}'
    else null end
$$;
create or replace function public._wow_pos_xy(p_pos integer)
returns double precision[] language plpgsql immutable as $$
declare p integer; s double precision[]; ctr double precision[];
begin
  p := ((coalesce(p_pos, 0) % 80) + 80) % 80;   /* igual que el frontend: modulo 80 */
  ctr := (case p / 20 when 0 then '{600,600}' when 1 then '{600,1800}'
                      when 2 then '{1800,600}' else '{1800,1800}' end)::double precision[];
  s := _wow_slot(p % 20);
  return array[ctr[1] + s[1] * 0.72, ctr[2] + s[2] * 0.60];
end $$;
/* ---- nodos del mapa (0..99): mismas coordenadas que el frontend ---- */
create or replace function public._wow_node_ctr(p_c integer)
returns double precision[] language sql immutable as $$
  select case p_c when 0 then '{600,600}'::double precision[] when 1 then '{600,1800}'
                  when 2 then '{1800,600}' else '{1800,1800}' end
$$;
create or replace function public._wow_node_base(p_c integer)
returns integer language sql immutable as $$
  select case p_c when 0 then 0 when 1 then 21 when 2 then 50 else 75 end
$$;
create or replace function public._wow_node_cont(p_node integer)
returns integer language sql immutable as $$
  select case
    when p_node between 42 and 45 then 0
    when p_node between 46 and 49 then 1
    when p_node between 71 and 74 then 2
    when p_node between 96 and 99 then 3
    when p_node >= 75 then 3
    when p_node >= 50 then 2
    when p_node >= 21 then 1
    else 0 end
$$;
/* aldeas: indice 0..15 -> desplazamiento local respecto al centro */
create or replace function public._wow_node_ald(p_i integer)
returns double precision[] language sql immutable as $$
  select case p_i % 4 when 0 then '{-560,-560}'::double precision[] when 1 then '{560,-560}'
                      when 2 then '{560,560}' else '{-560,560}' end
$$;
create or replace function public._wow_node_xy(p_node integer)
returns double precision[] language plpgsql immutable as $$
declare
  c integer; off integer; ctr double precision[]; s double precision[]; a double precision[];
  ai integer; ald integer[] := array[42,43,44,45,46,47,48,49,71,72,73,74,96,97,98,99];
begin
  c := _wow_node_cont(p_node);
  off := p_node - _wow_node_base(c);
  ctr := _wow_node_ctr(c);
  if off = 0 then return ctr; end if;                 /* trono: centro del continente */
  ai := array_position(ald, p_node);
  if ai is not null then                               /* aldea */
    a := _wow_node_ald(ai - 1);
    return array[ctr[1] + a[1] * 0.72, ctr[2] + a[2] * 0.60];
  end if;
  s := _wow_slot(off - 1);                             /* castillo */
  return array[ctr[1] + s[1] * 0.72, ctr[2] + s[2] * 0.60];
end $$;
/* pos de reino -> nodo de su castillo (igual que mapPosNode del frontend) */
create or replace function public._wow_pos_node(p_pos integer)
returns integer language sql immutable as $$
  select _wow_node_base((((coalesce(p_pos,0) % 80) + 80) % 80) / 20)
       + (((coalesce(p_pos,0) % 80) + 80) % 80) % 20 + 1
$$;
/* segundos de viaje entre la casilla de un reino y un nodo del mapa */
create or replace function public._wow_travel_node(p_pos integer, p_node integer)
returns integer language sql immutable as $$
  select greatest(20, 15 + round(sqrt(power(x1[1] - x2[1], 2) + power(x1[2] - x2[2], 2)) / 20.0)::integer)
  from (select _wow_pos_xy(p_pos) as x1, _wow_node_xy(p_node) as x2) t
$$;
create or replace function public._wow_travel(a integer, b integer)
returns integer language sql immutable as $$
  select _wow_travel_node(a, _wow_pos_node(b))
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
revoke all on function public._wow_travel_node(integer, integer) from public, anon, authenticated;
revoke all on function public._wow_pos_node(integer) from public, anon, authenticated;
revoke all on function public._wow_node_xy(integer) from public, anon, authenticated;
revoke all on function public._wow_node_ald(integer) from public, anon, authenticated;
revoke all on function public._wow_node_cont(integer) from public, anon, authenticated;
revoke all on function public._wow_node_base(integer) from public, anon, authenticated;
revoke all on function public._wow_node_ctr(integer) from public, anon, authenticated;
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

    -- ===== ejercito contra un trono/aldea: la accion ocurre al llegar =====
    if f.kind in ('throne_atk','throne_rein','throne_claim') then
      perform _wow_throne_land(f.id);
      continue;
    end if;

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
      values (f.attacker, 'return', jsonb_build_object('dir','return',
        'who', coalesce((select name from wow_thrones th where th.node = f.node), ''),
        'win',true,'loot',f.loot,'created',ms), ms);
    delete from wow_fleets where id = f.id;
  end loop;
end $$;
revoke all on function public._wow_resolve() from public, anon, authenticated;

-- ---------- enviar ataque ----------
create or replace function public.wow_attack(p_token text, p_target text, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_users; ms bigint; e record; v integer; travel integer; sent jsonb; protect numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  if p_target = u.id then raise exception 'No puedes atacarte a ti mismo.'; end if;
  select * into t from wow_users where id = p_target and active;
  if t.id is null then raise exception 'Ese reino ya no existe.'; end if;
  protect := _wow_protect_below();
  if protect > 0 then
    if _wow_points(t.id) < protect then
      raise exception 'Ese reino está protegido por ser novato (menos de % puntos).', trunc(protect)::int; end if;
    if not u.is_admin and _wow_points(u.id) < protect then
      raise exception 'Estás en protección de novatos: no puedes atacar hasta superar % puntos.', trunc(protect)::int; end if;
    if not u.is_admin and (_wow_points(u.id) - _wow_points(t.id)) >= protect then
      raise exception 'No puedes atacar a un reino mucho más débil: la diferencia de puntos no puede llegar a %.', trunc(protect)::int; end if;
  end if;
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
        'id', f.id, 'mine', f.attacker = u.id, 'kind', f.kind, 'node', f.node,
        'who', coalesce((select name from wow_thrones th where th.node = f.node),
                        (select name from wow_users where id = case when f.attacker = u.id then f.target else f.attacker end)),
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
             'atk', _wow_atk(v.t), 'hp', _wow_hp(v.t), 'req', _wow_treq(v.t)) order by v.ord), '[]') into trs
    from (values ('soldado',1),('arquero',2),('jinete',3),('mago',4),('paladin',5),('dragon',6)) v(t,ord)
    left join wow_troops t on t.owner_id = u.id and t.tkey = v.t;
  select coalesce(jsonb_agg(jsonb_build_object('kind', q.kind, 'ref', q.ref, 'qty', q.qty, 'unit_ms', q.unit_ms,
           'start', q.start_ms, 'finish', q.finish_ms) order by q.kind), '[]') into que
    from wow_queue q where q.owner_id = u.id;
  pts := (select coalesce(sum(level),0) from wow_buildings where owner_id = u.id) * 100
       + (select coalesce(sum(qty),0) from wow_troops where owner_id = u.id);
  return jsonb_build_object('id', u.id, 'name', u.name, 'faction', u.faction, 'is_admin', u.is_admin,
    'gold', u.gold, 'wood', u.wood, 'ore', u.ore, 'cup', coalesce(u.cup,0), 'capacity', cap, 'rate', rate,
    'buildings', blds, 'troops', trs, 'queue', que->0, 'queues', que, 'points', pts, 'now', ms,
    'alliance', u.alliance,
    'ally_tag', coalesce((select tag from wow_alliances where id = u.alliance), ''),
    'online', _wow_online_count());
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
      'id', f.id, 'state', f.state, 'kind', f.kind, 'mine', (f.attacker = u.id),
      'from_node', case when f.node is not null and f.state <> 'outbound' then f.node
                        when f.node is not null then _wow_pos_node(a.pos)
                        when f.state = 'outbound' then _wow_pos_node(a.pos)
                        else _wow_pos_node(coalesce(d.pos, a.pos)) end,
      'to_node',   case when f.node is not null and f.state <> 'outbound' then _wow_pos_node(a.pos)
                        when f.node is not null then f.node
                        when f.state = 'outbound' then _wow_pos_node(coalesce(d.pos, a.pos))
                        else _wow_pos_node(a.pos) end,
      'attacker', a.name, 'throne', (select name from wow_thrones th where th.node = f.node),
      'target', coalesce((select name from wow_thrones th where th.node = f.node), d.name),
      'from', case when f.node is not null then null
                   when f.state = 'outbound' then a.pos else coalesce(d.pos, a.pos) end,
      'to',   case when f.node is not null then null
                   when f.state = 'outbound' then coalesce(d.pos, a.pos) else a.pos end,
      'depart', f.leg_start_ms, 'arrive', f.arrive_ms
    ) order by f.arrive_ms)
    from wow_fleets f
    join wow_users a on a.id = f.attacker
    left join wow_users d on d.id = f.target
    where f.leg_start_ms > 0
  ), '[]')) into out;
  return out;
end $$;
grant execute on function public.wow_marches(text) to anon, authenticated;

-- ================================================================
-- APENDICE CONTENIDO v4: EDIFICIOS Y TROPAS NUEVAS (economia)
--   (generado desde wow-content.sql)
-- ================================================================
-- ================================================================
--  REINOS DE AZEROTH - CONTENIDO v4 (edificios y tropas nuevas)
--  Se aplica DESPUES de wow-schema.sql (base) y wow-pvp.sql.
--  - Edificios nuevos: herreria (dano), fortaleza (aguante), mercado (produccion)
--  - Tropas nuevas:    paladin, dragon
--  - Reemplaza la configuracion economica y la validacion de build/train.
-- ================================================================

-- ---------- costo de edificios ----------
create or replace function public._wow_bcost(p_key text, p_level integer)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'gold', round((case p_key
      when 'mina' then 0 when 'aserradero' then 0 when 'tesoreria' then 80
      when 'almacen' then 50 when 'cuartel' then 70 when 'muralla' then 90
      when 'herreria' then 120 when 'fortaleza' then 110 when 'mercado' then 130
      else 0 end) * power(1.55, p_level)),
    'wood', round((case p_key
      when 'mina' then 40 when 'aserradero' then 60 when 'tesoreria' then 60
      when 'almacen' then 50 when 'cuartel' then 70 when 'muralla' then 60
      when 'herreria' then 90 when 'fortaleza' then 140 when 'mercado' then 100
      else 0 end) * power(1.55, p_level)),
    'ore',  round((case p_key
      when 'mina' then 60 when 'aserradero' then 40 when 'tesoreria' then 40
      when 'almacen' then 50 when 'cuartel' then 50 when 'muralla' then 80
      when 'herreria' then 170 when 'fortaleza' then 130 when 'mercado' then 60
      else 0 end) * power(1.55, p_level)))
$$;

-- ---------- tiempo de edificios (segundos, factor 1.4 por nivel) ----------
create or replace function public._wow_btime(p_key text, p_level integer)
returns integer language sql immutable as $$
  select greatest(round((case p_key
    when 'mina' then 20 when 'aserradero' then 20 when 'tesoreria' then 25
    when 'almacen' then 30 when 'cuartel' then 35 when 'muralla' then 40
    when 'herreria' then 45 when 'fortaleza' then 50 when 'mercado' then 40
    else 30 end) * power(1.4, p_level)), 1)
$$;

-- ---------- produccion / bonus mostrado ----------
--   produccion: oro/madera/mineral por hora; almacen: capacidad
--   herreria/fortaleza/mercado: % de bonus por nivel (para mostrar en la UI)
create or replace function public._wow_bprod(p_key text, p_level integer)
returns numeric language sql immutable as $$
  select case when p_key = 'almacen' then 2000 + 1500 * p_level
              when p_key = 'herreria' then 4 * p_level
              when p_key = 'fortaleza' then 4 * p_level
              when p_key = 'mercado' then 5 * p_level
              when p_key in ('mina','aserradero','tesoreria') then 30 + 25 * p_level
              else 0 end
$$;

-- ---------- produccion por hora (con bonus del mercado) ----------
create or replace function public._wow_rate(p_owner text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare g integer; w integer; o integer; mk integer; mult numeric;
begin
  select coalesce(max(case when bkey='tesoreria' then level end),0),
         coalesce(max(case when bkey='aserradero' then level end),0),
         coalesce(max(case when bkey='mina' then level end),0),
         coalesce(max(case when bkey='mercado' then level end),0)
    into g,w,o,mk from wow_buildings where owner_id = p_owner;
  mult := 1 + 0.05 * mk;
  return jsonb_build_object('gold', round((30+25*g)*mult),
                            'wood', round((30+25*w)*mult),
                            'ore',  round((30+25*o)*mult));
end $$;

-- ---------- costo por unidad de tropa ----------
create or replace function public._wow_tcost(p_key text)
returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'gold', (case p_key when 'soldado' then 40 when 'arquero' then 50 when 'jinete' then 80
                         when 'mago' then 120 when 'paladin' then 240 when 'dragon' then 500 else 0 end),
    'wood', (case p_key when 'soldado' then 20 when 'arquero' then 40 when 'jinete' then 30
                         when 'mago' then 20 when 'paladin' then 80 when 'dragon' then 120 else 0 end),
    'ore',  (case p_key when 'soldado' then 30 when 'arquero' then 20 when 'jinete' then 60
                         when 'mago' then 100 when 'paladin' then 200 when 'dragon' then 420 else 0 end))
$$;

-- ---------- segundos por unidad entrenada ----------
create or replace function public._wow_ttime(p_key text)
returns integer language sql immutable as $$
  select case p_key when 'soldado' then 6 when 'arquero' then 8 when 'jinete' then 12
                    when 'mago' then 18 when 'paladin' then 28 when 'dragon' then 55 else 10 end
$$;

-- ---------- nivel de cuartel requerido por tropa (una nueva cada 2 niveles) ----------
create or replace function public._wow_treq(p_key text)
returns integer language sql immutable as $$
  select case p_key
    when 'soldado' then 1 when 'arquero' then 3 when 'jinete' then 5
    when 'mago' then 7 when 'paladin' then 9 when 'dragon' then 11
    else 1 end
$$;
revoke all on function public._wow_treq(text) from public, anon, authenticated;

revoke all on function public._wow_bcost(text, integer) from public, anon, authenticated;
revoke all on function public._wow_btime(text, integer) from public, anon, authenticated;
revoke all on function public._wow_bprod(text, integer) from public, anon, authenticated;
revoke all on function public._wow_rate(text) from public, anon, authenticated;
revoke all on function public._wow_tcost(text) from public, anon, authenticated;
revoke all on function public._wow_ttime(text) from public, anon, authenticated;

-- ---------- construir (con nuevos edificios) ----------
create or replace function public.wow_build(p_token text, p_key text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; lvl integer; c jsonb; t integer; ms bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  if exists(select 1 from wow_queue where owner_id = u.id and kind = 'build') then
    raise exception 'Ya estás construyendo un edificio.'; end if;
  if coalesce(p_key,'') not in ('mina','aserradero','tesoreria','almacen','cuartel','muralla',
                                'herreria','fortaleza','mercado') then
    raise exception 'Edificio no válido.'; end if;
  select coalesce(max(level),0) into lvl from wow_buildings where owner_id = u.id and bkey = p_key;
  c := _wow_bcost(p_key, lvl);
  if u.gold < (c->>'gold')::numeric then raise exception 'No tienes suficiente Oro.'; end if;
  if u.wood < (c->>'wood')::numeric then raise exception 'No tienes suficiente Madera.'; end if;
  if u.ore < (c->>'ore')::numeric then raise exception 'No tienes suficiente Mineral.'; end if;
  update wow_users set gold = gold - (c->>'gold')::numeric, wood = wood - (c->>'wood')::numeric,
         ore = ore - (c->>'ore')::numeric where id = u.id;
  t := _wow_btime(p_key, lvl);
  ms := (extract(epoch from now())*1000)::bigint;
  insert into wow_buildings (owner_id, bkey, level, finish_ms) values (u.id, p_key, lvl, ms + t*1000)
    on conflict (owner_id, bkey) do update set level = excluded.level, finish_ms = excluded.finish_ms;
  insert into wow_queue (owner_id, kind, ref, qty, unit_ms, start_ms, finish_ms)
    values (u.id, 'build', p_key, 0, 0, ms, ms + t*1000);
  return jsonb_build_object('ok', true, 'key', p_key, 'finish', ms + t*1000);
end $$;

grant execute on function public.wow_build(text, text) to anon, authenticated;

-- ---------- entrenar tropas (con nuevas tropas) ----------
create or replace function public.wow_train(p_token text, p_key text, p_qty integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; c jsonb; qty integer; um bigint; ms bigint; lv integer; tg numeric; tw numeric; tro numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  if exists(select 1 from wow_queue where owner_id = u.id and kind = 'train') then
    raise exception 'Ya estás entrenando tropas.'; end if;
  if coalesce(p_key,'') not in ('soldado','arquero','jinete','mago','paladin','dragon') then
    raise exception 'Tropa no válida.'; end if;
  select coalesce(max(level),0) into lv from wow_buildings where owner_id = u.id and bkey = 'cuartel';
  if lv < _wow_treq(p_key) then
    raise exception 'Necesitas Cuartel nivel % para entrenar %.', _wow_treq(p_key), p_key; end if;
  qty := greatest(coalesce(p_qty,0), 0);
  if qty < 1 then raise exception 'Escribe cuántas tropas entrenar.'; end if;
  if qty > 100000 then raise exception 'Máximo 100.000 tropas a la vez.'; end if;
  c := _wow_tcost(p_key);
  tg := (c->>'gold')::numeric * qty; tw := (c->>'wood')::numeric * qty; tro := (c->>'ore')::numeric * qty;
  if u.gold < tg then raise exception 'No tienes suficiente Oro.'; end if;
  if u.wood < tw then raise exception 'No tienes suficiente Madera.'; end if;
  if u.ore < tro then raise exception 'No tienes suficiente Mineral.'; end if;
  update wow_users set gold = gold - tg, wood = wood - tw, ore = ore - tro where id = u.id;
  um := _wow_ttime(p_key)::bigint * 1000;
  ms := (extract(epoch from now())*1000)::bigint;
  insert into wow_queue (owner_id, kind, ref, qty, unit_ms, start_ms, finish_ms)
    values (u.id, 'train', p_key, qty, um, ms, ms + qty*um);
  return jsonb_build_object('ok', true, 'key', p_key, 'qty', qty, 'finish', ms + qty*um);
end $$;

grant execute on function public.wow_train(text, text, integer) to anon, authenticated;

-- ================================================================
-- APENDICE ADMIN: PANEL DE GESTION (generado desde wow-admin.sql)
-- ================================================================
-- ================================================================
-- APENDICE ADMIN: panel "Gestion" (solo cuentas con is_admin = true)
--   Listar reinos, dar recursos/tropas, banear, borrar,
--   resetear contrasena y dar/quitar admin.
-- ================================================================

-- guard: devuelve el usuario admin o lanza error
create or replace function public._wow_admin(p_token text)
returns wow_users language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  return u;
end $$;
revoke all on function public._wow_admin(text) from public, anon, authenticated;

-- token -> es admin? (para el arranque del juego)
create or replace function public.wow_check(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then return null; end if;
  return jsonb_build_object('id', u.id, 'name', u.name, 'faction', u.faction, 'is_admin', u.is_admin);
end $$;
grant execute on function public.wow_check(text) to anon, authenticated;

-- proteccion de novatos: por debajo de N puntos no se puede atacar ni ser atacado
create or replace function public._wow_protect_below()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = 'protect_below'), 1000)
$$;
revoke all on function public._wow_protect_below() from public, anon, authenticated;

create or replace function public.wow_protect_info()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('points', _wow_protect_below())
$$;
grant execute on function public.wow_protect_info() to anon, authenticated;

-- ajustar umbral de proteccion de novatos (solo admin)
create or replace function public.wow_admin_setprotect(p_token text, p_pts numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if p_pts is null or p_pts < 0 or p_pts > 1000000 then
    raise exception 'La protección debe estar entre 0 y 1.000.000 puntos.'; end if;
  insert into wow_settings(key, val) values ('protect_below', p_pts::text)
    on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'points', p_pts);
end $$;
grant execute on function public.wow_admin_setprotect(text, numeric) to anon, authenticated;

-- listado de todos los reinos
create or replace function public.wow_admin_list(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; out jsonb; ms bigint;
begin
  a := _wow_admin(p_token);
  perform _wow_resolve();
  ms := (extract(epoch from now())*1000)::bigint;
  select jsonb_build_object('now', ms, 'me', a.id, 'users', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', w.id, 'name', w.name, 'faction', w.faction, 'pos', w.pos,
      'active', w.active, 'is_admin', w.is_admin,
      'gold', floor(w.gold), 'wood', floor(w.wood), 'ore', floor(w.ore),
      'cup', round(coalesce(w.cup,0), 2),
      'points', _wow_points(w.id),
      'troops', coalesce((select sum(qty) from wow_troops where owner_id = w.id),0),
      'alliance', coalesce((select tag from wow_alliances where id = w.alliance),''),
      'created', w.created, 'last', w.last_ms
    ) order by w.created)
    from wow_users w
  ), '[]')) into out;
  return out;
end $$;
grant execute on function public.wow_admin_list(text) to anon, authenticated;

-- dar/quitar recursos (valores negativos restan; no baja de 0)
create or replace function public.wow_admin_grant(p_token text, p_id text, p_gold numeric, p_wood numeric, p_ore numeric, p_cup numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if not exists(select 1 from wow_users where id = p_id) then raise exception 'Ese reino ya no existe.'; end if;
  update wow_users set
      gold = greatest(0, gold + coalesce(p_gold,0)),
      wood = greatest(0, wood + coalesce(p_wood,0)),
      ore  = greatest(0, ore  + coalesce(p_ore,0)),
      cup  = greatest(0, coalesce(cup,0) + coalesce(p_cup,0))
    where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_admin_grant(text, text, numeric, numeric, numeric, numeric) to anon, authenticated;

-- dar/quitar tropas de un tipo (qty puede ser negativo; no baja de 0)
create or replace function public.wow_admin_troops(p_token text, p_id text, p_key text, p_qty integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if p_key not in ('soldado','arquero','jinete','mago','paladin','dragon') then raise exception 'Tropa no válida.'; end if;
  if not exists(select 1 from wow_users where id = p_id) then raise exception 'Ese reino ya no existe.'; end if;
  insert into wow_troops(owner_id, tkey, qty) values(p_id, p_key, 0)
    on conflict (owner_id, tkey) do nothing;
  update wow_troops set qty = greatest(0, qty + coalesce(p_qty,0)) where owner_id = p_id and tkey = p_key;
  delete from wow_troops where owner_id = p_id and tkey = p_key and qty <= 0;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_admin_troops(text, text, text, integer) to anon, authenticated;

-- banear / reactivar
create or replace function public.wow_admin_ban(p_token text, p_id text, p_active boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if p_id = a.id then raise exception 'No puedes banearte a ti mismo.'; end if;
  if not exists(select 1 from wow_users where id = p_id) then raise exception 'Ese reino ya no existe.'; end if;
  update wow_users set active = coalesce(p_active, true) where id = p_id;
  if not coalesce(p_active, true) then delete from wow_sessions where user_id = p_id; end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_admin_ban(text, text, boolean) to anon, authenticated;

-- borra un reino y deja neutrales los tronos/aldeas que tuviera
-- (las demas tablas caen solas por on delete cascade)
create or replace function public._wow_delete_kingdom(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  update wow_thrones set holder = null, holder_name = '', since_ms = 0, garrison = '{}'::jsonb
    where holder = p_id;
  delete from wow_users where id = p_id;
end $$;
revoke all on function public._wow_delete_kingdom(text) from public, anon, authenticated;

-- borrar cuenta (cascade limpia todo)
create or replace function public.wow_admin_delete(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if p_id = a.id then raise exception 'No puedes borrar tu propia cuenta de administrador.'; end if;
  if not exists(select 1 from wow_users where id = p_id) then raise exception 'Ese reino ya no existe.'; end if;
  perform _wow_delete_kingdom(p_id);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_admin_delete(text, text) to anon, authenticated;

-- resetear contrasena (salt+hash calculados en el navegador)
create or replace function public.wow_admin_setpw(p_token text, p_id text, p_salt text, p_hash text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if coalesce(p_salt,'') = '' or coalesce(p_hash,'') = '' then raise exception 'Faltan datos de seguridad.'; end if;
  if not exists(select 1 from wow_users where id = p_id) then raise exception 'Ese reino ya no existe.'; end if;
  update wow_users set salt = p_salt, hash = p_hash where id = p_id;
  delete from wow_sessions where user_id = p_id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_admin_setpw(text, text, text, text) to anon, authenticated;

-- dar/quitar permisos de admin
create or replace function public.wow_admin_setadmin(p_token text, p_id text, p_admin boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if p_id = a.id and not coalesce(p_admin, false) then raise exception 'No puedes quitarte el admin a ti mismo.'; end if;
  if not exists(select 1 from wow_users where id = p_id) then raise exception 'Ese reino ya no existe.'; end if;
  update wow_users set is_admin = coalesce(p_admin, false) where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_admin_setadmin(text, text, boolean) to anon, authenticated;

-- ================================================================
-- La cuenta de administracion NO participa en el juego:
--   sin castillo en el mapa, fuera del ranking y no atacable/espiable.
--   (redifine wow_map / wow_leaderboard / wow_attack / wow_spy)
-- ================================================================
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
   where w.active and not w.is_admin;
  return out;
end $$;
grant execute on function public.wow_map(text) to anon, authenticated;

create or replace function public.wow_leaderboard(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'name', s.name, 'faction', s.faction, 'points', s.lsum*100 + s.tsum,
             'level_sum', s.lsum, 'troops', s.tsum, 'created', s.created,
             'alliance', s.atag, 'me', s.id = u.id) order by s.lsum*100 + s.tsum desc, s.created), '[]') into out
    from (
      select w.id, w.name, w.faction, w.created, coalesce(al.tag,'') atag,
             coalesce((select sum(b.level) from wow_buildings b where b.owner_id = w.id),0) lsum,
             coalesce((select sum(t.qty) from wow_troops t where t.owner_id = w.id),0) tsum
        from wow_users w left join wow_alliances al on al.id = w.alliance where w.active and not w.is_admin
    ) s;
  return out;
end $$;
grant execute on function public.wow_leaderboard(text) to anon, authenticated;

create or replace function public.wow_attack(p_token text, p_target text, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_users; ms bigint; e record; v integer; travel integer; sent jsonb; protect numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  if p_target = u.id then raise exception 'No puedes atacarte a ti mismo.'; end if;
  select * into t from wow_users where id = p_target and active;
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


-- ---- edificios de un reino (solo admin): leer y cambiar niveles ----
create or replace function public.wow_admin_blds(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; arr jsonb := '[]'::jsonb; k text; lv integer; fms bigint;
begin
  a := _wow_admin(p_token);
  if not exists(select 1 from wow_users where id = p_id) then raise exception 'Ese reino ya no existe.'; end if;
  foreach k in array array['mina','aserradero','tesoreria','almacen','cuartel','herreria','fortaleza','mercado','muralla']
  loop
    lv := 0; fms := 0;
    select level, finish_ms into lv, fms from wow_buildings where owner_id = p_id and bkey = k;
    arr := arr || jsonb_build_object('key', k, 'level', coalesce(lv,0), 'finish', coalesce(fms,0));
  end loop;
  return jsonb_build_object('ok', true, 'id', p_id, 'blds', arr,
    'now', (extract(epoch from now())*1000)::bigint);
end $$;
grant execute on function public.wow_admin_blds(text, text) to anon, authenticated;

create or replace function public.wow_admin_setbld(p_token text, p_id text, p_key text, p_level integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; lvl integer;
begin
  a := _wow_admin(p_token);
  if p_key not in ('mina','aserradero','tesoreria','almacen','cuartel','herreria','fortaleza','mercado','muralla') then
    raise exception 'Edificio no válido.'; end if;
  if p_level is null or p_level < 0 or p_level > 20 then
    raise exception 'El nivel debe estar entre 0 y 20.'; end if;
  if not exists(select 1 from wow_users where id = p_id) then raise exception 'Ese reino ya no existe.'; end if;
  if p_level = 0 then
    delete from wow_buildings where owner_id = p_id and bkey = p_key;
    return jsonb_build_object('ok', true, 'key', p_key, 'level', 0);
  end if;
  select coalesce(max(level),0) into lvl from wow_buildings where owner_id = p_id and bkey = p_key;
  insert into wow_buildings(owner_id, bkey, level, finish_ms) values (p_id, p_key, p_level, 0)
    on conflict (owner_id, bkey) do update set level = excluded.level, finish_ms = 0;
  return jsonb_build_object('ok', true, 'key', p_key, 'level', p_level, 'was', lvl);
end $$;
grant execute on function public.wow_admin_setbld(text, text, text, integer) to anon, authenticated;

-- ================================================================
-- APENDICE MERCADO: COMPRA/VENTA DE RECURSOS Y TROPAS CON CUP
--   (generado desde wow-market.sql)
-- ================================================================
-- APENDICE MERCADO v2: MERCADO ENTRE JUGADORES
--   - Ofertas con precio libre: el jugador da X y pide Y.
--   - Aceptacion PARCIAL permitida.
--   - Comision configurable por el admin (por defecto 20%): se
--     descuenta de lo que RECIBE el vendedor y se destruye.
--   - El admin NO comercia (solo asigna CUP y ajusta la comision).
--   - Las ofertas caducan en 1 dia (se devuelve lo reservado).
-- Objetos: gold, wood, ore, cup, soldado, arquero, jinete, mago,
--          paladin, dragon.
-- ================================================================

-- ---- quitar la tienda instantanea anterior ----
drop function if exists public.wow_market_sell_troop(text, text, integer);
drop function if exists public.wow_market_buy_troop(text, text, integer);
drop function if exists public.wow_market_sell_resource(text, text, numeric);
drop function if exists public.wow_market_buy_resource(text, text, numeric);

-- ---- tablas ----
create table if not exists public.wow_settings(
  key text primary key,
  val text not null default ''
);
insert into public.wow_settings(key, val) values ('market_fee', '20')
  on conflict (key) do nothing;

create table if not exists public.wow_market_offers(
  id bigserial primary key,
  seller text not null references public.wow_users(id) on delete cascade,
  seller_name text not null default '',
  give_key text not null,
  give_qty numeric(16,2) not null default 0,
  give_left numeric(16,2) not null default 0,
  want_key text not null,
  want_qty numeric(16,2) not null default 0,
  want_left numeric(16,2) not null default 0,
  created bigint not null default 0,
  expires_ms bigint not null default 0,
  active boolean not null default true
);
create index if not exists wow_market_offers_active_idx on public.wow_market_offers(active, expires_ms);

alter table public.wow_settings enable row level security;
alter table public.wow_market_offers enable row level security;

-- ---- helpers internos ----
create or replace function public._wow_mkt_ok(p_key text)
returns boolean language sql immutable as $$
  select p_key in ('gold','wood','ore','cup','soldado','arquero','jinete','mago','paladin','dragon')
$$;

create or replace function public._wow_mkt_is_troop(p_key text)
returns boolean language sql immutable as $$
  select p_key in ('soldado','arquero','jinete','mago','paladin','dragon')
$$;

create or replace function public._wow_mkt_fee()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = 'market_fee'), 20)
$$;

create or replace function public._wow_mkt_sub(p_owner text, p_key text, p_qty numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
declare cur numeric;
begin
  if coalesce(p_qty,0) <= 0 then raise exception 'Cantidad inválida.'; end if;
  if p_key in ('gold','wood','ore','cup') then
    select case p_key when 'gold' then gold when 'wood' then wood when 'ore' then ore else cup end
      into cur from wow_users where id = p_owner;
    if coalesce(cur,0) < p_qty then raise exception 'No tienes suficientes recursos para esa operación.'; end if;
    update wow_users set
        gold = case when p_key = 'gold' then gold - p_qty else gold end,
        wood = case when p_key = 'wood' then wood - p_qty else wood end,
        ore  = case when p_key = 'ore'  then ore  - p_qty else ore  end,
        cup  = case when p_key = 'cup'  then cup  - p_qty else cup  end
      where id = p_owner;
  else
    select qty into cur from wow_troops where owner_id = p_owner and tkey = p_key;
    if coalesce(cur,0) < p_qty then raise exception 'No tienes suficientes tropas para esa operación.'; end if;
    update wow_troops set qty = qty - p_qty::int where owner_id = p_owner and tkey = p_key;
    delete from wow_troops where owner_id = p_owner and tkey = p_key and qty <= 0;
  end if;
end $$;

create or replace function public._wow_mkt_add(p_owner text, p_key text, p_qty numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(p_qty,0) <= 0 then return; end if;
  if p_key in ('gold','wood','ore','cup') then
    update wow_users set
        gold = case when p_key = 'gold' then gold + p_qty else gold end,
        wood = case when p_key = 'wood' then wood + p_qty else wood end,
        ore  = case when p_key = 'ore'  then ore  + p_qty else ore  end,
        cup  = case when p_key = 'cup'  then cup  + p_qty else cup  end
      where id = p_owner;
  else
    insert into wow_troops(owner_id, tkey, qty) values (p_owner, p_key, p_qty::int)
      on conflict (owner_id, tkey) do update set qty = wow_troops.qty + excluded.qty;
  end if;
end $$;

revoke all on function public._wow_mkt_ok(text) from public, anon, authenticated;
revoke all on function public._wow_mkt_is_troop(text) from public, anon, authenticated;
revoke all on function public._wow_mkt_fee() from public, anon, authenticated;
revoke all on function public._wow_mkt_sub(text, text, numeric) from public, anon, authenticated;
revoke all on function public._wow_mkt_add(text, text, numeric) from public, anon, authenticated;

-- ---- comision (lectura publica) ----
create or replace function public.wow_market_fee()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('fee', _wow_mkt_fee())
$$;
grant execute on function public.wow_market_fee() to anon, authenticated;

-- ---- publicar oferta ----
create or replace function public.wow_market_offer(p_token text, p_give text, p_give_qty numeric, p_want text, p_want_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ms bigint; n integer; nid bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  if not _wow_mkt_ok(p_give) then raise exception 'Objeto a dar no válido.'; end if;
  if not _wow_mkt_ok(p_want) then raise exception 'Objeto a pedir no válido.'; end if;
  if coalesce(p_want,'') <> 'cup' then
    raise exception 'En "Pido" solo puedes pedir 🧿 CUP.'; end if;
  if p_give = p_want then raise exception 'No puedes cambiar un objeto por sí mismo.'; end if;
  if coalesce(p_give_qty,0) <= 0 then raise exception 'Cantidad a dar inválida.'; end if;
  if coalesce(p_want_qty,0) <= 0 then raise exception 'Cantidad a pedir inválida.'; end if;
  if _wow_mkt_is_troop(p_give) and p_give_qty <> floor(p_give_qty) then
    raise exception 'Las tropas se comercian en unidades enteras.'; end if;
  if _wow_mkt_is_troop(p_want) and p_want_qty <> floor(p_want_qty) then
    raise exception 'Las tropas se comercian en unidades enteras.'; end if;
  select count(*) into n from wow_market_offers where seller = u.id and active;
  if n >= 5 then raise exception 'Ya tienes el máximo de 5 ofertas activas.'; end if;
  perform _wow_mkt_sub(u.id, p_give, p_give_qty);
  insert into wow_market_offers(seller, seller_name, give_key, give_qty, give_left, want_key, want_qty, want_left, created, expires_ms, active)
    values (u.id, u.name, p_give, p_give_qty, p_give_qty, p_want, p_want_qty, p_want_qty, ms, ms + 86400000, true)
    returning id into nid;
  return jsonb_build_object('ok', true, 'id', nid);
end $$;
grant execute on function public.wow_market_offer(text, text, numeric, text, numeric) to anon, authenticated;

-- ---- listado (ofertas ajenas + mis ofertas) ----
create or replace function public.wow_market_list(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ms bigint; o record; offs jsonb; mine jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  for o in select * from wow_market_offers where active and expires_ms <= ms for update loop
    perform _wow_mkt_add(o.seller, o.give_key, o.give_left);
    update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
  end loop;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'who', x.seller_name, 'give', x.give_key, 'give_left', x.give_left, 'give_qty', x.give_qty,
      'want', x.want_key, 'want_left', x.want_left, 'want_qty', x.want_qty, 'expires', x.expires_ms
    ) order by x.id desc), '[]'::jsonb)
   into offs
   from wow_market_offers x join wow_users w on w.id = x.seller
   where x.active and x.seller <> u.id and not w.is_admin;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'give', x.give_key, 'give_left', x.give_left, 'give_qty', x.give_qty,
      'want', x.want_key, 'want_left', x.want_left, 'want_qty', x.want_qty, 'expires', x.expires_ms
    ) order by x.id desc), '[]'::jsonb)
   into mine
   from wow_market_offers x where x.active and x.seller = u.id;
  return jsonb_build_object('ok', true, 'fee', _wow_mkt_fee(), 'offers', offs, 'mine', mine);
end $$;
grant execute on function public.wow_market_list(text) to anon, authenticated;

-- ---- tomar (aceptar) oferta, parcial permitido ----
create or replace function public.wow_market_take(p_token text, p_id bigint, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; o wow_market_offers; ms bigint;
  take numeric; want_part numeric; fee numeric; net numeric; new_left numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select * into o from wow_market_offers where id = p_id for update;
  if o.id is null or not o.active then raise exception 'Esa oferta ya no está disponible.'; end if;
  if o.expires_ms <= ms then
    perform _wow_mkt_add(o.seller, o.give_key, o.give_left);
    update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
    raise exception 'Esa oferta ha caducado.'; end if;
  if o.seller = u.id then raise exception 'Esa oferta es tuya.'; end if;
  take := coalesce(p_qty, 0);
  if take <= 0 then raise exception 'Cantidad inválida.'; end if;
  if take >= o.give_left then
    take := o.give_left;
    want_part := o.want_left;
  else
    if _wow_mkt_is_troop(o.give_key) then take := floor(take); end if;
    if take <= 0 then raise exception 'Cantidad inválida.'; end if;
    want_part := o.want_left * (take / o.give_left);
    if _wow_mkt_is_troop(o.want_key) then
      want_part := greatest(1, round(want_part));
    else
      want_part := round(want_part, 2);
    end if;
    if want_part > o.want_left then want_part := o.want_left; end if;
    if want_part <= 0 then raise exception 'Cantidad demasiado pequeña.'; end if;
  end if;
  -- el comprador paga el total (want)
  perform _wow_mkt_sub(u.id, o.want_key, want_part);
  -- recibe lo ofrecido (give)
  perform _wow_mkt_add(u.id, o.give_key, take);
  -- el vendedor recibe want menos comision; el resto se destruye
  fee := _wow_mkt_fee();
  net := want_part * (1 - fee/100.0);
  if _wow_mkt_is_troop(o.want_key) then net := round(net); end if;
  if net < 0 then net := 0; end if;
  perform _wow_mkt_add(o.seller, o.want_key, net);
  -- actualizar la oferta
  new_left := o.give_left - take;
  if new_left <= 0.0001 then
    update wow_market_offers set give_left = 0, want_left = 0, active = false where id = o.id;
  else
    update wow_market_offers set give_left = new_left, want_left = greatest(0, o.want_left - want_part) where id = o.id;
  end if;
  return jsonb_build_object('ok', true, 'took', take, 'paid', want_part, 'fee', fee, 'net', net);
end $$;
grant execute on function public.wow_market_take(text, bigint, numeric) to anon, authenticated;

-- ---- cancelar oferta propia (devuelve lo reservado) ----
create or replace function public.wow_market_cancel(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; o wow_market_offers; r numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  select * into o from wow_market_offers where id = p_id for update;
  if o.id is null or not o.active then raise exception 'La oferta ya no existe.'; end if;
  if o.seller <> u.id then raise exception 'Esa oferta no es tuya.'; end if;
  r := o.give_left;
  perform _wow_mkt_add(u.id, o.give_key, r);
  update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
  return jsonb_build_object('ok', true, 'refund', r);
end $$;
grant execute on function public.wow_market_cancel(text, bigint) to anon, authenticated;

-- ---- admin: ajustar comision ----
create or replace function public.wow_admin_setfee(p_token text, p_fee numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  if p_fee is null or p_fee < 0 or p_fee > 90 then raise exception 'La comisión debe estar entre 0 y 90.'; end if;
  insert into wow_settings(key, val) values ('market_fee', p_fee::text)
    on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'fee', p_fee);
end $$;
grant execute on function public.wow_admin_setfee(text, numeric) to anon, authenticated;

-- ================================================================
-- APENDICE TRONOS: FORTALEZAS CENTRALES CONQUISTABLES + TRIBUTO
--   (generado desde wow-throne.sql)
-- ================================================================
-- ================================================================
-- APENDICE TRONOS: FORTALEZAS CENTRALES CONQUISTABLES
--   - Dos tronos: nodo 0 (Azeroth) y nodo 21 (Kalimdor).
--   - Empiezan LIBRES: el primero que llega con tropas los ocupa.
--   - Otros reinos atacan la guarnicion para quitarlos.
--   - El duenio recibe parte de la comision del mercado (tributo)
--     acumulada en un tesoro que reclama cuando quiere.
--   - El admin no puede poseer tronos.
-- ================================================================

create table if not exists public.wow_thrones(
  node integer primary key,
  name text not null default '',
  holder text,
  holder_name text not null default '',
  since_ms bigint not null default 0,
  garrison jsonb not null default '{}'::jsonb,
  accrue_ms bigint not null default 0
);
alter table public.wow_thrones add column if not exists accrue_ms bigint not null default 0;
create table if not exists public.wow_throne_treasure(
  node integer not null,
  key text not null,
  qty numeric(16,2) not null default 0,
  primary key (node, key)
);
create table if not exists public.wow_throne_history(
  id bigserial primary key,
  node integer not null,
  kind text not null,
  actor text,
  actor_name text not null default '',
  detail jsonb not null default '{}'::jsonb,
  created bigint not null default 0
);
create table if not exists public.wow_events(
  id bigserial primary key,
  kind text not null default '',
  txt text not null default '',
  created bigint not null default 0
);
alter table public.wow_thrones enable row level security;
alter table public.wow_throne_treasure enable row level security;
alter table public.wow_throne_history enable row level security;
alter table public.wow_events enable row level security;

insert into public.wow_thrones(node, name) values (0, 'TRONO DE AZEROTH'), (21, 'TRONO DE KALIMDOR')
  on conflict (node) do nothing;
insert into public.wow_settings(key, val) values ('throne_share', '1')
  on conflict (key) do nothing;
-- produccion de recursos de cada trono con duenio (por hora)
insert into public.wow_settings(key, val) values
  ('throne_gold_h', '100'), ('throne_wood_h', '100'), ('throne_ore_h', '100')
  on conflict (key) do nothing;

-- ---- helpers internos ----
create or replace function public._wow_throne_pct()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = 'throne_share'), 1)
$$;
revoke all on function public._wow_throne_pct() from public, anon, authenticated;

create or replace function public._wow_throne_add(p_node integer, p_key text, p_qty numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(p_qty,0) <= 0 then return; end if;
  insert into wow_throne_treasure(node, key, qty) values (p_node, p_key, p_qty)
    on conflict (node, key) do update set qty = wow_throne_treasure.qty + excluded.qty;
end $$;
revoke all on function public._wow_throne_add(integer, text, numeric) from public, anon, authenticated;

-- ---- produccion de recursos por hora (configurable por el admin) ----
create or replace function public._wow_throne_rate(p_key text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = p_key), 100)
$$;
revoke all on function public._wow_throne_rate(text) from public, anon, authenticated;

-- abona al tesoro los recursos generados por cada trono con duenio desde el ultimo abono
create or replace function public._wow_throne_accrue()
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  ms bigint; t record; hrs numeric; rg numeric; rw numeric; ro numeric;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  rg := _wow_throne_rate('throne_gold_h');
  rw := _wow_throne_rate('throne_wood_h');
  ro := _wow_throne_rate('throne_ore_h');
  for t in select * from wow_thrones where holder is not null for update loop
    if coalesce(t.accrue_ms,0) <= 0 then
      update wow_thrones set accrue_ms = ms where node = t.node;
      continue;
    end if;
    hrs := (ms - t.accrue_ms)::numeric / 3600000.0;
    if hrs <= 0 then continue; end if;
    if rg > 0 then perform _wow_throne_add(t.node, 'gold', round(rg * hrs, 2)); end if;
    if rw > 0 then perform _wow_throne_add(t.node, 'wood', round(rw * hrs, 2)); end if;
    if ro > 0 then perform _wow_throne_add(t.node, 'ore',  round(ro * hrs, 2)); end if;
    update wow_thrones set accrue_ms = ms where node = t.node;
  end loop;
end $$;
revoke all on function public._wow_throne_accrue() from public, anon, authenticated;

create or replace function public._wow_throne_check(p_troops jsonb)
returns jsonb language plpgsql immutable as $$
declare k text; v numeric; res jsonb := '{}'::jsonb;
begin
  if p_troops is null or jsonb_typeof(p_troops) <> 'object' then raise exception 'Sin tropas.'; end if;
  for k, v in select key, value::numeric from jsonb_each_text(p_troops) loop
    if not _wow_mkt_is_troop(k) then raise exception 'Tropa no válida: %', k; end if;
    if v <= 0 or v <> floor(v) then raise exception 'Cantidad inválida para %.', k; end if;
    res := res || jsonb_build_object(k, v::int);
  end loop;
  if res = '{}'::jsonb then raise exception 'Elige al menos una tropa.'; end if;
  return res;
end $$;
revoke all on function public._wow_throne_check(jsonb) from public, anon, authenticated;

create or replace function public._wow_throne_log(p_node integer, p_kind text, p_actor text, p_actor_name text, p_detail jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare ms bigint := (extract(epoch from now())*1000)::bigint;
begin
  insert into wow_throne_history(node, kind, actor, actor_name, detail, created)
    values (p_node, p_kind, p_actor, coalesce(p_actor_name,''), coalesce(p_detail,'{}'::jsonb), ms);
  delete from wow_throne_history where node = p_node
    and id not in (select id from wow_throne_history where node = p_node order by id desc limit 40);
end $$;
revoke all on function public._wow_throne_log(integer, text, text, text, jsonb) from public, anon, authenticated;

create or replace function public._wow_event(p_kind text, p_text text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare ms bigint := (extract(epoch from now())*1000)::bigint;
begin
  insert into wow_events(kind, txt, created) values (p_kind, p_text, ms);
  delete from wow_events where id not in (select id from wow_events order by id desc limit 60);
end $$;
revoke all on function public._wow_event(text, text) from public, anon, authenticated;

-- ---- crónica global de sucesos ----
create or replace function public.wow_events(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('kind', kind, 'text', txt, 'created', created) order by id desc), '[]'::jsonb)
    into out from (select kind, txt, created, id from wow_events order by id desc limit 30) e;
  return out;
end $$;
grant execute on function public.wow_events(text) to anon, authenticated;

-- ---- estado de los tronos ----
create or replace function public.wow_throne_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; arr jsonb := '[]'::jsonb; g numeric; tr jsonb; fac text; hist jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  perform _wow_throne_accrue();
  for t in select * from wow_thrones order by node loop
    select coalesce(sum((value)::numeric),0) into g from jsonb_each_text(t.garrison);
    select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into tr
      from wow_throne_treasure where node = t.node and qty > 0;
    select coalesce(jsonb_agg(jsonb_build_object(
        'kind', h.kind, 'who', h.actor_name, 'who_id', h.actor,
        'detail', h.detail, 'created', h.created) order by h.id desc), '[]'::jsonb)
      into hist from (select * from wow_throne_history where node = t.node order by id desc limit 8) h;
    fac := null;
    if t.holder is not null then select faction into fac from wow_users where id = t.holder; end if;
    arr := arr || jsonb_build_object(
      'node', t.node, 'name', t.name, 'holder', t.holder, 'holder_name', t.holder_name,
      'faction', fac, 'garrison', coalesce(g,0), 'gdetail', t.garrison, 'since', t.since_ms,
      'mine', (t.holder = u.id), 'treasure', tr, 'history', hist);
  end loop;
  return jsonb_build_object('ok', true, 'share', _wow_throne_pct(), 'thrones', arr,
    'rates', jsonb_build_object('gold', _wow_throne_rate('throne_gold_h'),
                                'wood', _wow_throne_rate('throne_wood_h'),
                                'ore',  _wow_throne_rate('throne_ore_h')));
end $$;
grant execute on function public.wow_throne_info(text) to anon, authenticated;

-- ================================================================
-- LAS TROPAS VIAJAN: atacar, reforzar, retirar y reclamar tesoro
-- tardan lo mismo que el icono del mapa. Al llegar las tropas,
-- _wow_resolve() llama a _wow_throne_land() y ahi ocurre la accion.
-- ================================================================
create or replace function public._wow_throne_land(p_fleet_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  f wow_fleets; u wow_users; t wow_thrones; ms bigint; z record; r record;
  sim jsonb; surv jsonb; msg jsonb; prev text; ret integer;
  a_forge int; a_fort int; d_forge int; d_fort int; d_wall int;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  select * into f from wow_fleets where id = p_fleet_id;
  if f.id is null then return; end if;
  select * into u from wow_users where id = f.attacker;
  if u.id is null then delete from wow_fleets where id = f.id; return; end if;
  select * into t from wow_thrones where node = f.node for update;

  -- ---- reclamar tesoro: recoge lo acumulado y vuelve a casa ----
  if f.kind = 'throne_claim' then
    msg := '{}'::jsonb;
    if t.node is not null and t.holder = u.id then
      perform _wow_throne_accrue();
      for r in select key, qty from wow_throne_treasure where node = t.node and qty > 0 for update loop
        msg := msg || jsonb_build_object(r.key, r.qty);
      end loop;
      delete from wow_throne_treasure where node = t.node;
      if msg <> '{}'::jsonb then perform _wow_throne_log(t.node, 'claim', u.id, u.name, msg); end if;
    end if;
    ret := _wow_travel_node(u.pos, coalesce(f.node, _wow_pos_node(u.pos)));
    update wow_fleets set state = 'returning', loot = msg, arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
    return;
  end if;

  -- ---- refuerzo: suma a la guarnicion; si ya no es tuyo, vuelve a casa ----
  if f.kind = 'throne_rein' then
    if t.node is not null and t.holder = u.id then
      surv := t.garrison;
      for z in select key, value::int from jsonb_each_text(f.troops) loop
        surv := jsonb_set(surv, array[z.key], to_jsonb(coalesce((surv->>z.key)::int,0) + z.value), true);
      end loop;
      update wow_thrones set garrison = surv where node = t.node;
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

  -- ---- asalto: si el objetivo desaparecio, las tropas vuelven ----
  if t.node is null then
    ret := _wow_travel_node(u.pos, _wow_pos_node(u.pos));
    update wow_fleets set state = 'returning', arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who','','win',false,
        'note','El objetivo ya no existe: tus tropas vuelven a casa.','created',ms), ms);
    return;
  end if;

  -- ---- trono/aldea libre o guarnicion vacia: se ocupa sin lucha ----
  if coalesce(t.holder,'') = '' or t.garrison = '{}'::jsonb then
    update wow_thrones set holder = u.id, holder_name = u.name, since_ms = ms, garrison = f.troops, accrue_ms = ms where node = t.node;
    perform _wow_throne_log(t.node, 'take', u.id, u.name, jsonb_build_object('garrison', f.troops));
    perform _wow_event('throne', (case when t.kind = 'aldea' then '🛖 ' else '🏯 ' end) || u.name || ' ha ocupado ' || t.name || '.');
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',true,'battle',null,'created',ms), ms);
    delete from wow_fleets where id = f.id;
    return;
  end if;

  -- ---- batalla contra la guarnicion (muros/herreria/fortaleza del duenio) ----
  prev := t.holder_name;
  a_forge := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'herreria'), 0);
  a_fort  := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'fortaleza'), 0);
  d_forge := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'herreria'), 0);
  d_fort  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'fortaleza'), 0);
  d_wall  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'muralla'), 0);
  sim := _wow_sim(f.troops, t.garrison, d_wall, (ms/1000) + t.node*131,
                  1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort);
  if (sim->>'winner') = 'attacker' then
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'a_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    update wow_thrones set holder = u.id, holder_name = u.name, since_ms = ms, garrison = surv, accrue_ms = ms where node = t.node;
    perform _wow_throne_log(t.node, 'conquest', u.id, u.name, jsonb_build_object('from', prev));
    perform _wow_event('throne', (case when t.kind = 'aldea' then '🏘️ ' else '👑 ' end) || u.name || ' ha conquistado ' || t.name || ' (antes de ' || coalesce(prev, 'nadie') || ').');
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',true,'from',u.name,'battle',sim,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',true,'from',u.name,'battle',sim,'created',ms), ms);
  else
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'d_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    update wow_thrones set garrison = surv where node = t.node;
    perform _wow_throne_log(t.node, 'defended', u.id, u.name, jsonb_build_object('holder', prev));
    perform _wow_event('throne', '🛡️ La guarnición de ' || t.name || ' ha rechazado el ataque de ' || u.name || '.');
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms);
  end if;
  delete from wow_fleets where id = f.id;
end $$;
revoke all on function public._wow_throne_land(bigint) from public, anon, authenticated;

-- ---- conquistar (atacar la guarnicion): el ejercito viaja y combate al llegar ----
create or replace function public.wow_throne_attack(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; z record; travel integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian ni conquistan.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if exists(select 1 from wow_fleets where attacker = u.id and node = p_node and state = 'outbound') then
    raise exception 'Ya tienes un ejército en camino a %.', t.name; end if;
  -- el ejercito sale del reino y viaja
  for z in select key, value::int from jsonb_each_text(army) loop
    perform _wow_mkt_sub(u.id, z.key, z.value);
  end loop;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'outbound', 'throne_atk', ms, ms + travel*1000, ms);
  perform _wow_event('throne', '⚔️ ' || u.name || ' ha enviado un ejército contra ' || t.name || '.');
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name);
end $$;
grant execute on function public.wow_throne_attack(text, integer, jsonb) to anon, authenticated;

-- ---- reforzar guarnicion (solo el duenio): las tropas viajan ----
create or replace function public.wow_throne_reinforce(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; z record; travel integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if t.holder <> u.id then raise exception 'No controlas ese trono.'; end if;
  if exists(select 1 from wow_fleets where attacker = u.id and node = p_node and state = 'outbound') then
    raise exception 'Ya tienes un ejército en camino a %.', t.name; end if;
  for z in select key, value::int from jsonb_each_text(army) loop
    perform _wow_mkt_sub(u.id, z.key, z.value);
  end loop;
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'outbound', 'throne_rein', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name);
end $$;
grant execute on function public.wow_throne_reinforce(text, integer, jsonb) to anon, authenticated;

-- ---- retirar tropas de la guarnicion: salen al momento y llegan al icono ----
create or replace function public.wow_throne_withdraw(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; newg jsonb; z record; left_g int; travel integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if t.holder <> u.id then raise exception 'No controlas ese trono.'; end if;
  for z in select key, value::int from jsonb_each_text(army) loop
    if coalesce((t.garrison->>z.key)::int, 0) < z.value then
      raise exception 'No tienes tantas tropas de ese tipo en la guarnición.'; end if;
  end loop;
  -- salen de la guarnicion (viajan a casa)
  newg := t.garrison;
  for z in select key, value::int from jsonb_each_text(army) loop
    left_g := coalesce((newg->>z.key)::int, 0) - z.value;
    if left_g > 0 then
      newg := jsonb_set(newg, array[z.key], to_jsonb(left_g), true);
    else
      newg := newg - z.key;
    end if;
  end loop;
  update wow_thrones set garrison = newg where node = t.node;
  perform _wow_throne_log(t.node, 'withdraw', u.id, u.name, jsonb_build_object('troops', army));
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'returning', 'throne_with', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000,
                            'empty', (newg = '{}'::jsonb), 'target', t.name);
end $$;
grant execute on function public.wow_throne_withdraw(text, integer, jsonb) to anon, authenticated;

-- ---- reclamar tesoro (solo el duenio): una partida va, recoge y vuelve ----
create or replace function public.wow_throne_claim(p_token text, p_node integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; travel integer; have numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if t.holder <> u.id then raise exception 'No controlas ese trono.'; end if;
  if exists(select 1 from wow_fleets where attacker = u.id and node = p_node and kind = 'throne_claim' and state = 'outbound') then
    raise exception 'Ya tienes una partida en camino a reclamar el tesoro de %.', t.name; end if;
  perform _wow_throne_accrue();
  select coalesce(sum(qty),0) into have from wow_throne_treasure where node = p_node;
  if have <= 0 then raise exception 'No hay tesoro que reclamar todavía.'; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, '{}'::jsonb, '{}'::jsonb, 'outbound', 'throne_claim', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name);
end $$;
grant execute on function public.wow_throne_claim(text, integer) to anon, authenticated;

-- ---- ajuste admin del tributo de tronos ----
create or replace function public.wow_admin_setthrone(p_token text, p_pct numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  if p_pct is null or p_pct < 0 or p_pct > 90 then raise exception 'El tributo debe estar entre 0 y 90.'; end if;
  insert into wow_settings(key, val) values ('throne_share', p_pct::text)
    on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'share', p_pct);
end $$;
grant execute on function public.wow_admin_setthrone(text, numeric) to anon, authenticated;

-- ---- ajuste admin de la produccion de recursos de los tronos (por hora) ----
create or replace function public.wow_admin_setthrones(p_token text, p_gold numeric, p_wood numeric, p_ore numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  if p_gold is null or p_wood is null or p_ore is null
     or p_gold < 0 or p_wood < 0 or p_ore < 0
     or p_gold > 100000 or p_wood > 100000 or p_ore > 100000 then
    raise exception 'La producción debe estar entre 0 y 100000 por hora.';
  end if;
  insert into wow_settings(key, val) values ('throne_gold_h', p_gold::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key, val) values ('throne_wood_h', p_wood::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key, val) values ('throne_ore_h',  p_ore::text)  on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'rates', jsonb_build_object('gold', p_gold, 'wood', p_wood, 'ore', p_ore));
end $$;
grant execute on function public.wow_admin_setthrones(text, numeric, numeric, numeric) to anon, authenticated;

-- ================================================================
-- Integracion con el mercado: ademas de la comision, se abona el
-- tributo del trono (por defecto 1% del valor del trato) al tesoro
-- de cada trono con duenio. (Reemplaza wow_market_take.)
-- ================================================================
create or replace function public.wow_market_take(p_token text, p_id bigint, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; o wow_market_offers; ms bigint;
  take numeric; want_part numeric; fee numeric; net numeric; new_left numeric;
  shp numeric; share numeric; tt record;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select * into o from wow_market_offers where id = p_id for update;
  if o.id is null or not o.active then raise exception 'Esa oferta ya no está disponible.'; end if;
  if o.expires_ms <= ms then
    perform _wow_mkt_add(o.seller, o.give_key, o.give_left);
    update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
    raise exception 'Esa oferta ha caducado.'; end if;
  if o.seller = u.id then raise exception 'Esa oferta es tuya.'; end if;
  take := coalesce(p_qty, 0);
  if take <= 0 then raise exception 'Cantidad inválida.'; end if;
  if take >= o.give_left then
    take := o.give_left;
    want_part := o.want_left;
  else
    if _wow_mkt_is_troop(o.give_key) then take := floor(take); end if;
    if take <= 0 then raise exception 'Cantidad inválida.'; end if;
    want_part := o.want_left * (take / o.give_left);
    if _wow_mkt_is_troop(o.want_key) then
      want_part := greatest(1, round(want_part));
    else
      want_part := round(want_part, 2);
    end if;
    if want_part > o.want_left then want_part := o.want_left; end if;
    if want_part <= 0 then raise exception 'Cantidad demasiado pequeña.'; end if;
  end if;
  -- el comprador paga el total (want)
  perform _wow_mkt_sub(u.id, o.want_key, want_part);
  -- recibe lo ofrecido (give)
  perform _wow_mkt_add(u.id, o.give_key, take);
  -- el vendedor recibe want menos comision; el resto se destruye
  fee := _wow_mkt_fee();
  net := want_part * (1 - fee/100.0);
  if _wow_mkt_is_troop(o.want_key) then net := round(net); end if;
  if net < 0 then net := 0; end if;
  perform _wow_mkt_add(o.seller, o.want_key, net);
  -- tributo del trono: 1% (ajustable) del trato, descontado de la comision
  shp := _wow_throne_pct();
  share := want_part * least(shp, fee) / 100.0;
  if _wow_mkt_is_troop(o.want_key) then share := round(share); end if;
  if share > 0 then
    for tt in select node from wow_thrones where holder is not null loop
      perform _wow_throne_add(tt.node, o.want_key, share);
    end loop;
  end if;
  -- actualizar la oferta
  new_left := o.give_left - take;
  if new_left <= 0.0001 then
    update wow_market_offers set give_left = 0, want_left = 0, active = false where id = o.id;
  else
    update wow_market_offers set give_left = new_left, want_left = greatest(0, o.want_left - want_part) where id = o.id;
  end if;
  return jsonb_build_object('ok', true, 'took', take, 'paid', want_part, 'fee', fee, 'net', net, 'throne_share', share);
end $$;
grant execute on function public.wow_market_take(text, bigint, numeric) to anon, authenticated;

-- ================================================================
-- Ranking: agrega el numero de tronos que controla cada reino.
-- ================================================================
create or replace function public.wow_leaderboard(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'name', w.name, 'faction', w.faction, 'me', (w.id = u.id),
      'points', coalesce((select sum(g.level) from wow_buildings g where g.owner_id = w.id),0) * 100
                + coalesce((select sum(t.qty) from wow_troops t where t.owner_id = w.id),0),
      'level_sum', coalesce((select sum(g.level) from wow_buildings g where g.owner_id = w.id),0),
      'troops', coalesce((select sum(t.qty) from wow_troops t where t.owner_id = w.id),0),
      'thrones', (select count(*) from wow_thrones th where th.holder = w.id))
    order by (select count(*) from wow_thrones th where th.holder = w.id) desc,
             coalesce((select sum(g.level) from wow_buildings g where g.owner_id = w.id),0) * 100
              + coalesce((select sum(t.qty) from wow_troops t where t.owner_id = w.id),0) desc), '[]'::jsonb)
  into out
  from wow_users w where w.active and not coalesce(w.is_admin,false);
  return out;
end $$;
grant execute on function public.wow_leaderboard(text) to anon, authenticated;

-- ================================================================
-- APENDICE ALDEAS: POBLADOS NEUTRALES CONQUISTABLES + TRIBUTO
--   (generado desde wow-aldea.sql)
-- ================================================================
-- ================================================================
-- APENDICE ALDEAS: POBLADOS NEUTRALES CONQUISTABLES
--   - Ocho aldeas: nodos 42..45 (continente alto) y 46..49 (bajo).
--   - Empiezan LIBRES: el primero que llega con tropas las ocupa;
--     otros reinos atacan la guarnicion para quitarlas.
--   - El duenio recibe produccion (100/h, configurable) acumulada en
--     un tesoro que reclama cuando quiere, y un % del valor del trato
--     del mercado (tributo, 1% por defecto y configurable por admin).
--   - Reutiliza el motor de tronos (misma tabla wow_thrones con `kind`,
--     mismo tesoro/historial y mismas funciones wow_throne_*).
-- ================================================================

-- tipo de estructura por nodo: 'trono' (def.) o 'aldea'
alter table public.wow_thrones add column if not exists kind text not null default 'trono';

insert into public.wow_thrones(node, name, kind) values
  (42, 'Aldea del Alba',       'aldea'),
  (43, 'Aldea del Bosque',     'aldea'),
  (44, 'Aldea de la Colina',   'aldea'),
  (45, 'Aldea del Río',        'aldea'),
  (46, 'Aldea de la Costa',    'aldea'),
  (47, 'Aldea del Valle',      'aldea'),
  (48, 'Aldea del Desierto',   'aldea'),
  (49, 'Aldea de la Niebla',   'aldea')
  on conflict (node) do nothing;
-- por si quedaran filas de aldeas fuera de rango
update public.wow_thrones set kind = 'aldea' where node in (42,43,44,45,46,47,48,49);

insert into public.wow_settings(key, val) values ('aldea_share', '1')
  on conflict (key) do nothing;
insert into public.wow_settings(key, val) values
  ('aldea_gold_h', '100'), ('aldea_wood_h', '100'), ('aldea_ore_h', '100')
  on conflict (key) do nothing;

-- ---- helpers internos por tipo de nodo ----
create or replace function public._wow_aldea_pct()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = 'aldea_share'), 1)
$$;
revoke all on function public._wow_aldea_pct() from public, anon, authenticated;

create or replace function public._wow_node_kind(p_node integer)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select kind from wow_thrones where node = p_node), 'trono')
$$;
revoke all on function public._wow_node_kind(integer) from public, anon, authenticated;

create or replace function public._wow_node_pct(p_node integer)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select case _wow_node_kind(p_node) when 'aldea' then _wow_aldea_pct() else _wow_throne_pct() end
$$;
revoke all on function public._wow_node_pct(integer) from public, anon, authenticated;

create or replace function public._wow_node_rate(p_node integer, p_res text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select _wow_throne_rate(case _wow_node_kind(p_node)
    when 'aldea' then 'aldea_' || p_res || '_h'
    else 'throne_' || p_res || '_h' end)
$$;
revoke all on function public._wow_node_rate(integer, text) from public, anon, authenticated;

-- ---- produccion por hora segun el tipo de nodo (reemplaza la de tronos) ----
create or replace function public._wow_throne_accrue()
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  ms bigint; t record; hrs numeric; rg numeric; rw numeric; ro numeric;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  for t in select * from wow_thrones where holder is not null for update loop
    if coalesce(t.accrue_ms,0) <= 0 then
      update wow_thrones set accrue_ms = ms where node = t.node;
      continue;
    end if;
    hrs := (ms - t.accrue_ms)::numeric / 3600000.0;
    if hrs <= 0 then continue; end if;
    rg := _wow_node_rate(t.node, 'gold');
    rw := _wow_node_rate(t.node, 'wood');
    ro := _wow_node_rate(t.node, 'ore');
    if rg > 0 then perform _wow_throne_add(t.node, 'gold', round(rg * hrs, 2)); end if;
    if rw > 0 then perform _wow_throne_add(t.node, 'wood', round(rw * hrs, 2)); end if;
    if ro > 0 then perform _wow_throne_add(t.node, 'ore', round(ro * hrs, 2)); end if;
    update wow_thrones set accrue_ms = ms where node = t.node;
  end loop;
end $$;
revoke all on function public._wow_throne_accrue() from public, anon, authenticated;

-- ---- info de nodos (reutilizable trono/aldea) ----
create or replace function public._wow_fort_info(p_uid text, p_kind text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare t wow_thrones; arr jsonb := '[]'::jsonb; g numeric; tr jsonb; fac text; hist jsonb;
begin
  for t in select * from wow_thrones where kind = p_kind order by node loop
    select coalesce(sum((value)::numeric),0) into g from jsonb_each_text(t.garrison);
    select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into tr
      from wow_throne_treasure where node = t.node and qty > 0;
    select coalesce(jsonb_agg(jsonb_build_object(
        'kind', h.kind, 'who', h.actor_name, 'who_id', h.actor,
        'detail', h.detail, 'created', h.created) order by h.id desc), '[]'::jsonb)
      into hist from (select * from wow_throne_history where node = t.node order by id desc limit 8) h;
    fac := null;
    if t.holder is not null then select faction into fac from wow_users where id = t.holder; end if;
    arr := arr || jsonb_build_object(
      'node', t.node, 'name', t.name, 'kind', t.kind,
      'holder', t.holder, 'holder_name', t.holder_name,
      'faction', fac, 'garrison', coalesce(g,0), 'gdetail', t.garrison, 'since', t.since_ms,
      'mine', (t.holder = p_uid), 'treasure', tr, 'history', hist);
  end loop;
  return arr;
end $$;
revoke all on function public._wow_fort_info(text, text) from public, anon, authenticated;

create or replace function public.wow_throne_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  perform _wow_throne_accrue();
  return jsonb_build_object('ok', true, 'share', _wow_throne_pct(),
    'thrones', _wow_fort_info(u.id, 'trono'),
    'rates', jsonb_build_object('gold', _wow_throne_rate('throne_gold_h'),
                                'wood', _wow_throne_rate('throne_wood_h'),
                                'ore',  _wow_throne_rate('throne_ore_h')));
end $$;
grant execute on function public.wow_throne_info(text) to anon, authenticated;

create or replace function public.wow_aldea_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  perform _wow_throne_accrue();
  return jsonb_build_object('ok', true, 'share', _wow_aldea_pct(),
    'aldeas', _wow_fort_info(u.id, 'aldea'),
    'rates', jsonb_build_object('gold', _wow_throne_rate('aldea_gold_h'),
                                'wood', _wow_throne_rate('aldea_wood_h'),
                                'ore',  _wow_throne_rate('aldea_ore_h')));
end $$;
grant execute on function public.wow_aldea_info(text) to anon, authenticated;

-- ---- ajuste admin del tributo de aldeas ----
create or replace function public.wow_admin_setaldeashare(p_token text, p_pct numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  if p_pct is null or p_pct < 0.01 or p_pct > 20 then raise exception 'El tributo de aldeas debe estar entre 0,01 y 20.'; end if;
  insert into wow_settings(key, val) values ('aldea_share', trim_scale(round(p_pct, 2))::text)
    on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'share', trim_scale(round(p_pct, 2)));
end $$;
grant execute on function public.wow_admin_setaldeashare(text, numeric) to anon, authenticated;

-- ---- ajuste admin de la produccion de recursos de las aldeas (por hora) ----
create or replace function public.wow_admin_setaldeas(p_token text, p_gold numeric, p_wood numeric, p_ore numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  if p_gold is null or p_wood is null or p_ore is null
     or p_gold < 0 or p_wood < 0 or p_ore < 0
     or p_gold > 100000 or p_wood > 100000 or p_ore > 100000 then
    raise exception 'La producción debe estar entre 0 y 100000 por hora.';
  end if;
  insert into wow_settings(key, val) values ('aldea_gold_h', p_gold::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key, val) values ('aldea_wood_h', p_wood::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key, val) values ('aldea_ore_h',  p_ore::text)  on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'rates', jsonb_build_object('gold', p_gold, 'wood', p_wood, 'ore', p_ore));
end $$;
grant execute on function public.wow_admin_setaldeas(text, numeric, numeric, numeric) to anon, authenticated;

-- ================================================================
-- Mercado: el tributo va al tesoro de CADA estructura con duenio,
-- con su % segun el tipo (trono -> throne_share, aldea -> aldea_share).
-- (Reemplaza wow_market_take del apendice de tronos.)
-- ================================================================
create or replace function public.wow_market_take(p_token text, p_id bigint, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; o wow_market_offers; ms bigint;
  take numeric; want_part numeric; fee numeric; net numeric; new_left numeric;
  share numeric; tt record;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select * into o from wow_market_offers where id = p_id for update;
  if o.id is null or not o.active then raise exception 'Esa oferta ya no está disponible.'; end if;
  if o.expires_ms <= ms then
    perform _wow_mkt_add(o.seller, o.give_key, o.give_left);
    update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
    raise exception 'Esa oferta ha caducado.'; end if;
  if o.seller = u.id then raise exception 'Esa oferta es tuya.'; end if;
  take := coalesce(p_qty, 0);
  if take <= 0 then raise exception 'Cantidad inválida.'; end if;
  if take >= o.give_left then
    take := o.give_left;
    want_part := o.want_left;
  else
    if _wow_mkt_is_troop(o.give_key) then take := floor(take); end if;
    if take <= 0 then raise exception 'Cantidad inválida.'; end if;
    want_part := o.want_left * (take / o.give_left);
    if _wow_mkt_is_troop(o.want_key) then
      want_part := greatest(1, round(want_part));
    else
      want_part := round(want_part, 2);
    end if;
    if want_part > o.want_left then want_part := o.want_left; end if;
    if want_part <= 0 then raise exception 'Cantidad demasiado pequeña.'; end if;
  end if;
  -- el comprador paga el total (want)
  perform _wow_mkt_sub(u.id, o.want_key, want_part);
  -- recibe lo ofrecido (give)
  perform _wow_mkt_add(u.id, o.give_key, take);
  -- el vendedor recibe want menos comision; el resto se destruye
  fee := _wow_mkt_fee();
  net := want_part * (1 - fee/100.0);
  if _wow_mkt_is_troop(o.want_key) then net := round(net); end if;
  if net < 0 then net := 0; end if;
  perform _wow_mkt_add(o.seller, o.want_key, net);
  -- tributo: % del valor del trato segun el tipo de cada estructura con duenio
  share := 0;
  for tt in select node from wow_thrones where holder is not null order by node loop
    share := want_part * least(_wow_node_pct(tt.node), fee) / 100.0;
    if _wow_mkt_is_troop(o.want_key) then share := round(share); end if;
    if share > 0 then perform _wow_throne_add(tt.node, o.want_key, share); end if;
  end loop;
  -- actualizar la oferta
  new_left := o.give_left - take;
  if new_left <= 0.0001 then
    update wow_market_offers set give_left = 0, want_left = 0, active = false where id = o.id;
  else
    update wow_market_offers set give_left = new_left, want_left = greatest(0, o.want_left - want_part) where id = o.id;
  end if;
  return jsonb_build_object('ok', true, 'took', take, 'paid', want_part, 'fee', fee, 'net', net, 'throne_share', share);
end $$;
grant execute on function public.wow_market_take(text, bigint, numeric) to anon, authenticated;

-- ================================================================
-- Ranking: agrega tronos y aldeas que controla cada reino.
-- ================================================================
create or replace function public.wow_leaderboard(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'name', s.name, 'faction', s.faction, 'me', s.me, 'created', s.created,
      'alliance', s.atag,
      'points', s.lsum * 100 + s.tsum, 'level_sum', s.lsum, 'troops', s.tsum,
      'thrones', s.thrones, 'aldeas', s.aldeas)
    order by s.thrones desc, s.aldeas desc, (s.lsum * 100 + s.tsum) desc, s.created), '[]'::jsonb)
    into out
    from (
      select w.id, w.name, w.faction, w.created, (w.id = u.id) me, coalesce(al.tag,'') atag,
        coalesce((select sum(b.level) from wow_buildings b where b.owner_id = w.id),0) lsum,
        coalesce((select sum(t.qty) from wow_troops t where t.owner_id = w.id),0) tsum,
        (select count(*) from wow_thrones th where th.holder = w.id and th.kind = 'trono') thrones,
        (select count(*) from wow_thrones th where th.holder = w.id and th.kind = 'aldea') aldeas
      from wow_users w left join wow_alliances al on al.id = w.alliance
      where w.active and not coalesce(w.is_admin,false)
    ) s;
  return out;
end $$;
grant execute on function public.wow_leaderboard(text) to anon, authenticated;

-- ================================================================
-- APENDICE ALIANZAS: RANKING Y GUERRAS ENTRE ALIANZAS
--   (generado desde wow-alliance.sql)
-- ================================================================
-- ================================================================
-- ALIANZAS v2: RANKING DE ALIANZAS + GUERRAS ENTRE ALIANZAS
--   (generado desde wow-alliance.sql)
-- ================================================================

-- ---------- tablas ----------
create table if not exists public.wow_ally_wars(
  id bigserial primary key,
  a text not null,
  b text not null,
  a_tag text not null default '',
  b_tag text not null default '',
  a_name text not null default '',
  b_name text not null default '',
  a_score integer not null default 0,
  b_score integer not null default 0,
  started bigint not null default 0,
  ends bigint not null default 0,
  active boolean not null default true,
  a_won boolean,
  created bigint not null default 0
);
create index if not exists wow_ally_wars_active_idx on public.wow_ally_wars (active, ends);
alter table public.wow_ally_wars enable row level security;

alter table public.wow_alliances add column if not exists war_wins integer not null default 0;
alter table public.wow_alliances add column if not exists war_losses integer not null default 0;

-- ---------- helper: cerrar guerras vencidas ----------
create or replace function public._wow_war_tick()
returns void language plpgsql security definer set search_path to 'public' as $$
declare r record; vms bigint; vawin boolean; vwin_tag text;
begin
  vms := (extract(epoch from now())*1000)::bigint;
  for r in select * from wow_ally_wars where active and ends <= vms loop
    vawin := r.a_score >= r.b_score;
    update wow_ally_wars set active = false, a_won = vawin where id = r.id;
    if vawin then
      update wow_alliances set war_wins = war_wins + 1 where id = r.a;
      update wow_alliances set war_losses = war_losses + 1 where id = r.b;
      vwin_tag := r.a_tag;
    else
      update wow_alliances set war_wins = war_wins + 1 where id = r.b;
      update wow_alliances set war_losses = war_losses + 1 where id = r.a;
      vwin_tag := r.b_tag;
    end if;
    perform _wow_event('war',
      '🏳️ La guerra [ ' || r.a_tag || ' ] vs [ ' || r.b_tag || ' ] ha terminado. Vence [ ' || vwin_tag ||
      ' ] (' || greatest(r.a_score, r.b_score) || '-' || least(r.a_score, r.b_score) || ').');
  end loop;
end $$;
revoke all on function public._wow_war_tick() from public, anon, authenticated;

-- ---------- trigger: anotar puntos de guerra ----------
create or replace function public._wow_war_report()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare va text; vb text; vwa text; r record; vwin boolean;
begin
  if NEW.kind <> 'out' or coalesce(NEW.data->>'dir', '') <> 'out' then return NEW; end if;
  select alliance into va from wow_users where id = NEW.owner;
  if va is null then return NEW; end if;
  select alliance into vb from wow_users where name = NEW.data->>'who';
  if vb is null or vb = va then return NEW; end if;
  select * into r from wow_ally_wars
    where active and ((a = va and b = vb) or (a = vb and b = va)) limit 1;
  if r.id is null then return NEW; end if;
  vwin := coalesce((NEW.data->>'win')::boolean, false);
  vwa := case when vwin then va else vb end;
  if vwa = r.a then
    update wow_ally_wars set a_score = a_score + 1 where id = r.id;
  else
    update wow_ally_wars set b_score = b_score + 1 where id = r.id;
  end if;
  return NEW;
end $$;
revoke all on function public._wow_war_report() from public, anon, authenticated;
drop trigger if exists wow_war_report on public.wow_reports;
create trigger wow_war_report after insert on public.wow_reports
  for each row execute function public._wow_war_report();

-- ---------- ranking de alianzas ----------
create or replace function public.wow_alliance_rank(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', x.id, 'name', x.name, 'tag', x.tag,
             'members', x.members, 'points', x.points,
             'troops', x.troops, 'thrones', x.thrones,
             'wins', x.wins, 'losses', x.losses,
             'mine', x.id = u.alliance) order by x.points desc, x.wins desc, x.created), '[]') into out
    from (
      select a.id, a.name, a.tag, a.created,
             a.war_wins as wins, a.war_losses as losses,
             (select count(*) from wow_users w where w.alliance = a.id) as members,
             (select coalesce(sum(_wow_points(w.id)),0) from wow_users w where w.alliance = a.id) as points,
             (select coalesce(sum(t.qty),0) from wow_troops t
                join wow_users w on w.id = t.owner_id where w.alliance = a.id) as troops,
             (select count(*) from wow_thrones th
                join wow_users w on w.id = th.holder where w.alliance = a.id) as thrones
        from wow_alliances a
    ) x;
  return out;
end $$;
grant execute on function public.wow_alliance_rank(text) to anon, authenticated;

-- ---------- declarar guerra ----------
create or replace function public.wow_ally_war_declare(p_token text, p_target text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ra wow_alliances; rb wow_alliances; vms bigint; vid bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'Entra a una alianza para declarar guerras.'; end if;
  select * into ra from wow_alliances where id = u.alliance;
  if ra.leader <> u.id then raise exception 'Solo el líder de la alianza puede declarar la guerra.'; end if;
  select * into rb from wow_alliances where id = p_target;
  if rb.id is null then raise exception 'Esa alianza no existe.'; end if;
  if ra.id = rb.id then raise exception 'No puedes declarar la guerra a tu propia alianza.'; end if;
  if exists(select 1 from wow_ally_wars
              where active and ((a = ra.id and b = rb.id) or (a = rb.id and b = ra.id))) then
    raise exception 'Ya hay una guerra activa contra esa alianza.'; end if;
  vms := (extract(epoch from now())*1000)::bigint;
  insert into wow_ally_wars (a, b, a_tag, b_tag, a_name, b_name, a_score, b_score, started, ends, active, created)
  values (ra.id, rb.id, ra.tag, rb.tag, ra.name, rb.name, 0, 0, vms, vms + 172800000, true, vms)
  returning id into vid;
  perform _wow_event('war', '⚔️ La alianza [ ' || ra.tag || ' ] ha declarado la guerra a [ ' || rb.tag || ' ].');
  return jsonb_build_object('ok', true, 'id', vid);
end $$;
grant execute on function public.wow_ally_war_declare(text, text) to anon, authenticated;

-- ---------- rendirse ----------
create or replace function public.wow_ally_war_surrender(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ra wow_alliances; r wow_ally_wars; vawin boolean;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'No estás en ninguna alianza.'; end if;
  select * into ra from wow_alliances where id = u.alliance;
  if ra.leader <> u.id then raise exception 'Solo el líder de la alianza puede rendirse.'; end if;
  select * into r from wow_ally_wars where id = p_id and active;
  if r.id is null then raise exception 'Esa guerra ya no está activa.'; end if;
  if u.alliance not in (r.a, r.b) then raise exception 'Tu alianza no participa en esa guerra.'; end if;
  vawin := (u.alliance = r.b);
  update wow_ally_wars set active = false, a_won = vawin where id = r.id;
  if vawin then
    update wow_alliances set war_wins = war_wins + 1 where id = r.a;
    update wow_alliances set war_losses = war_losses + 1 where id = r.b;
  else
    update wow_alliances set war_wins = war_wins + 1 where id = r.b;
    update wow_alliances set war_losses = war_losses + 1 where id = r.a;
  end if;
  perform _wow_event('war',
    '🏳️ La alianza [ ' || ra.tag || ' ] se ha rendido ante [ ' || (case when u.alliance = r.a then r.b_tag else r.a_tag end) || ' ].');
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_ally_war_surrender(text, bigint) to anon, authenticated;

-- ---------- listar guerras activas ----------
create or replace function public.wow_ally_wars(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_war_tick();
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', w.id, 'a', w.a, 'b', w.b,
             'a_tag', w.a_tag, 'b_tag', w.b_tag,
             'a_name', w.a_name, 'b_name', w.b_name,
             'a_score', w.a_score, 'b_score', w.b_score,
             'ends', w.ends, 'started', w.started,
             'mine', (u.alliance in (w.a, w.b)),
             'i_am_a', (u.alliance = w.a))
           order by w.started desc), '[]') into out
    from wow_ally_wars w where w.active;
  return jsonb_build_object('wars', out, 'mine', u.alliance);
end $$;
grant execute on function public.wow_ally_wars(text) to anon, authenticated;

-- ---------- limite de miembros: maximo 5 por alianza ----------
create or replace function public.wow_alliance_join(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; vcnt integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is not null then raise exception 'Ya estás en una alianza. Sal de la actual primero.'; end if;
  if not exists(select 1 from wow_alliances where id = p_id) then
    raise exception 'Esa alianza ya no existe.'; end if;
  select count(*) into vcnt from wow_users where alliance = p_id;
  if vcnt >= 5 then raise exception 'Esa alianza ya está llena (máximo 5 miembros).'; end if;
  update wow_users set alliance = p_id where id = u.id;
  return jsonb_build_object('ok', true, 'id', p_id);
end $$;
grant execute on function public.wow_alliance_join(text, text) to anon, authenticated;

-- la info de la alianza incluye el id de cada miembro (para poder expulsarlos) y quien es el lider
create or replace function public.wow_alliance_info(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a wow_alliances; mem jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select * into a from wow_alliances where id = p_id;
  if a.id is null then raise exception 'Esa alianza ya no existe.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', w.id, 'name', w.name, 'faction', w.faction, 'points', _wow_points(w.id),
             'leader', w.id = a.leader, 'me', w.id = u.id)
           order by (w.id = a.leader) desc, w.created), '[]') into mem
    from wow_users w where w.alliance = a.id;
  return jsonb_build_object('id', a.id, 'name', a.name, 'tag', a.tag, 'descr', a.descr,
    'leader', (select name from wow_users where id = a.leader),
    'members', mem, 'is_member', u.alliance = a.id,
    'is_leader', (u.id = a.leader));
end $$;
grant execute on function public.wow_alliance_info(text, text) to anon, authenticated;

-- expulsar a un miembro de la alianza (solo el lider)
create or replace function public.wow_alliance_kick(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a wow_alliances; t wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'No estás en ninguna alianza.'; end if;
  select * into a from wow_alliances where id = u.alliance;
  if a.leader is distinct from u.id then raise exception 'Solo el líder de la alianza puede expulsar miembros.'; end if;
  if p_id = u.id then raise exception 'El líder no puede expulsarse a sí mismo.'; end if;
  select * into t from wow_users where id = p_id;
  if t.id is null or t.alliance is distinct from u.alliance then raise exception 'Ese reino ya no está en tu alianza.'; end if;
  update wow_users set alliance = null where id = t.id;
  perform _wow_event('alliance', '🚪 [' || a.tag || '] ' || t.name || ' ha sido expulsado de la alianza ' || a.name || '.');
  return jsonb_build_object('ok', true, 'id', t.id, 'name', t.name);
end $$;
grant execute on function public.wow_alliance_kick(text, text) to anon, authenticated;

-- ================================================================
-- APENDICE CHAT GLOBAL: mensajes publicos de todos los jugadores
--   (generado desde wow-chat.sql)
-- ================================================================
-- ================================================================
-- APENDICE CHAT GLOBAL: mensajes publicos de todos los jugadores
--   (generado desde wow-chat.sql)
-- ================================================================

create table if not exists public.wow_gchat(
  id bigserial primary key,
  user_id text not null,
  name text not null,
  faction text not null default 'alianza',
  ally_tag text not null default '',
  msg text not null,
  created bigint not null default 0
);
alter table public.wow_gchat enable row level security;

-- ---------- chat global ----------
create or replace function public.wow_gchat_send(p_token text, p_msg text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; vmsg text; vms bigint; last_ms bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  vmsg := btrim(coalesce(p_msg,''));
  if vmsg = '' then raise exception 'Escribe un mensaje.'; end if;
  if length(vmsg) > 300 then vmsg := left(vmsg, 300); end if;
  vms := (extract(epoch from now())*1000)::bigint;
  select max(created) into last_ms from wow_gchat where user_id = u.id;
  if last_ms is not null and vms - last_ms < 2000 then
    raise exception 'Espera un momento antes de volver a escribir.';
  end if;
  insert into wow_gchat(user_id, name, faction, ally_tag, msg, created)
  values (u.id, u.name, coalesce(u.faction,'alianza'),
          coalesce((select tag from wow_alliances where id = u.alliance), ''), vmsg, vms);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_gchat_send(text, text) to anon, authenticated;

create or replace function public.wow_gchat(p_token text, p_since bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id, 'name', c.name, 'faction', c.faction, 'tag', c.ally_tag,
             'msg', c.msg, 'created', c.created, 'me', c.user_id = u.id) order by c.id), '[]') into out
    from (select * from wow_gchat
           where (coalesce(p_since,0) = 0 or created > coalesce(p_since,0))
           order by id desc limit 60) c;
  return out;
end $$;
grant execute on function public.wow_gchat(text, bigint) to anon, authenticated;

-- ---------- moderacion: solo el admin puede borrar mensajes ----------
create or replace function public.wow_gchat_delete(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; n integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'No tienes permisos de administrador.'; end if;
  delete from wow_gchat where id = p_id;
  get diagnostics n = row_count;
  return jsonb_build_object('ok', true, 'deleted', n);
end $$;
grant execute on function public.wow_gchat_delete(text, bigint) to anon, authenticated;

-- ================================================================
-- APENDICE ONLINE: contador de reinos en linea
--   (generado desde wow-online.sql)
-- ================================================================
-- ================================================================
-- APENDICE ONLINE: reinos en linea (contador publico)
--   - last_ms se actualiza en cada refresco (wow_state -> _wow_tick),
--     que el cliente dispara cada 20 s mientras el juego esta abierto.
--   - "en linea" = reino activo con last_ms dentro del umbral
--     (online_min minutos, 5 por defecto, ajustable por admin).
--   - Cuenta por usuario (varias pestanas = 1) e incluye a Administracion.
-- ================================================================

insert into public.wow_settings(key, val) values ('online_min', '5')
  on conflict (key) do nothing;

-- minutos que definen "en linea"
create or replace function public._wow_online_min()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key = 'online_min'), 5)
$$;
revoke all on function public._wow_online_min() from public, anon, authenticated;

-- reinos activos vistos dentro del umbral
create or replace function public._wow_online_count()
returns integer language sql stable security definer set search_path to 'public' as $$
  select count(*)::int from wow_users
   where active
     and last_ms >= (extract(epoch from now())*1000)::bigint
                    - (_wow_online_min() * 60000)::bigint
$$;
revoke all on function public._wow_online_count() from public, anon, authenticated;

-- consulta publica (para el juego)
create or replace function public.wow_online(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  return jsonb_build_object('count', _wow_online_count(), 'min', _wow_online_min());
end $$;
grant execute on function public.wow_online(text) to anon, authenticated;

-- info para el panel admin
create or replace function public.wow_online_info()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('min', _wow_online_min(), 'count', _wow_online_count())
$$;
grant execute on function public.wow_online_info() to anon, authenticated;

-- ajustar umbral en minutos (solo admin)
create or replace function public.wow_admin_setonline(p_token text, p_min numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if p_min is null or p_min < 1 or p_min > 60 then
    raise exception 'El tiempo en línea debe estar entre 1 y 60 minutos.'; end if;
  insert into wow_settings(key, val) values ('online_min', p_min::text)
    on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'min', p_min);
end $$;
grant execute on function public.wow_admin_setonline(text, numeric) to anon, authenticated;

-- ---- wow_state: incluye el contador de reinos en linea ----
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
             'atk', _wow_atk(v.t), 'hp', _wow_hp(v.t), 'req', _wow_treq(v.t)) order by v.ord), '[]') into trs
    from (values ('soldado',1),('arquero',2),('jinete',3),('mago',4),('paladin',5),('dragon',6)) v(t,ord)
    left join wow_troops t on t.owner_id = u.id and t.tkey = v.t;
  select coalesce(jsonb_agg(jsonb_build_object('kind', q.kind, 'ref', q.ref, 'qty', q.qty, 'unit_ms', q.unit_ms,
           'start', q.start_ms, 'finish', q.finish_ms) order by q.kind), '[]') into que
    from wow_queue q where q.owner_id = u.id;
  pts := (select coalesce(sum(level),0) from wow_buildings where owner_id = u.id) * 100
       + (select coalesce(sum(qty),0) from wow_troops where owner_id = u.id);
  return jsonb_build_object('id', u.id, 'name', u.name, 'faction', u.faction, 'is_admin', u.is_admin,
    'gold', u.gold, 'wood', u.wood, 'ore', u.ore, 'cup', coalesce(u.cup,0), 'capacity', cap, 'rate', rate,
    'buildings', blds, 'troops', trs, 'queue', que->0, 'queues', que, 'points', pts, 'now', ms,
    'alliance', u.alliance,
    'ally_tag', coalesce((select tag from wow_alliances where id = u.alliance), ''),
    'online', _wow_online_count());
end $$;
grant execute on function public.wow_state(text) to anon, authenticated;

-- ================================================================
-- APENDICE 4 CONTINENTES: mapa 2x2 + reparto de registros
--   (generado desde wow-cont4.sql)
-- ================================================================
-- ================================================================
-- APENDICE 4 CONTINENTES: mapa 2x2 (80 casillas de castillo)
--   - Tronos y aldeas de los dos continentes nuevos (derecha).
--   - Los registros nuevos se reparten entre el continente con menos
--     reinos, para que los cuatro se pueblen por igual.
--   - El reparto de casillas (80 = 4 x 20) es el mismo que usa el
--     frontend: pos/20 = continente, pos%20 = slot.
-- ================================================================

alter table public.wow_thrones add column if not exists kind text not null default 'trono';

-- tronos de la columna derecha
insert into public.wow_thrones(node, name) values
  (50, 'TRONO DE NORTHREND'), (75, 'TRONO DE PANDARIA')
  on conflict (node) do nothing;

-- aldeas de la columna derecha (4 por continente, como en los otros dos)
insert into public.wow_thrones(node, name, kind) values
  (71, 'Aldea del Amanecer', 'aldea'),
  (72, 'Aldea del Roble',    'aldea'),
  (73, 'Aldea del Pico',     'aldea'),
  (74, 'Aldea del Raudal',   'aldea'),
  (96, 'Aldea del Puerto',   'aldea'),
  (97, 'Aldea de la Pradera','aldea'),
  (98, 'Aldea de la Arena',  'aldea'),
  (99, 'Aldea de la Nieve',  'aldea')
  on conflict (node) do nothing;

-- ---------- cuenta: hueco en el continente con menos reinos ----------
create or replace function public.wow_register(p_name text, p_realm text, p_faction text, p_salt text, p_hash text, p_now bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare vname text; vrealm text; vkey text; vfac text;
       vpos integer; vc integer; vn integer; vs integer;
begin
  vname := btrim(coalesce(p_name,'')); vkey := _wow_key(vname); vrealm := btrim(coalesce(p_realm,''));
  if length(vkey) < 2 then raise exception 'Escribe un nombre de rey (así entrarás después).'; end if;
  if length(vrealm) < 2 then raise exception 'Escribe el nombre de tu reino.'; end if;
  -- los nombres se ven en el ranking, el mapa y el chat: nada de etiquetas ni símbolos raros
  if vname ~ '[<>&"''\\]' or vname ~ '[[:cntrl:]]' or length(vname) > 24 then
    raise exception 'El nombre de rey solo puede llevar letras, números, espacios y guiones.'; end if;
  if vrealm ~ '[<>&"''\\]' or vrealm ~ '[[:cntrl:]]' or length(vrealm) > 24 then
    raise exception 'El nombre del reino solo puede llevar letras, números, espacios y guiones.'; end if;
  vfac := lower(btrim(coalesce(p_faction,'')));
  if vfac not in ('alianza','horda') then raise exception 'Elige Alianza o Horda.'; end if;
  if coalesce(p_salt,'') = '' or coalesce(p_hash,'') = '' then raise exception 'Faltan datos de seguridad.'; end if;
  if exists(select 1 from wow_users where name_key = vkey) then
    raise exception 'Ese nombre de rey ya está en uso. Prueba con otro.'; end if;

  -- continente con menos reinos (los cuatro se pueblan parejos)
  vc := 0; vn := -1;
  for i in 0..3 loop
    select count(*) into vs from wow_users where active and pos >= i*20 and pos < i*20 + 20;
    if vn < 0 or vs < vn then vn := vs; vc := i; end if;
  end loop;
  -- primer hueco libre; si ese continente se lleno, paso al siguiente
  vpos := null;
  for i in 0..3 loop
    for j in 0..19 loop
      if not exists(select 1 from wow_users where active and pos = vc*20 + j) then
        vpos := vc*20 + j; exit;
      end if;
    end loop;
    exit when vpos is not null;
    vc := (vc + 1) % 4;
  end loop;
  if vpos is null then raise exception 'El mundo está lleno: ya hay 80 reinos.'; end if;

  insert into wow_users (id, name, name_key, faction, salt, hash, active, created, last_ms, gold, wood, ore, pos, alliance)
  values (vkey, vrealm, vkey, vfac, p_salt, p_hash, true, p_now, p_now, 500, 500, 500, vpos, null);
  return jsonb_build_object('ok', true, 'id', vkey, 'pos', vpos);
end $$;

-- ================================================================
-- APENDICE REINOS AUTOMATICOS: reinos que juegan solos (pg_cron)
--   (generado desde wow-bots.sql)
-- ================================================================
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

-- ================================================================
-- APENDICE NODOS DE ALIANZA: tronos/aldeas a nombre de la alianza + arcon
--   (generado desde wow-allynode.sql)
-- ================================================================
-- ================================================================
-- APENDICE ALIANZAS PROPIETARIAS: tronos y aldeas en nombre de la
-- alianza + arcon comun y reparto por porcentajes que decide el lider.
--   - Al conquistar un nodo estando en alianza, pasa a ser DE LA
--     ALIANZA (se guarda holder_ally) y el nombre que se muestra es
--     el de la alianza ([TAG] Nombre).
--   - Cualquier miembro puede reforzar, retirar y reclamar el tesoro
--     de un nodo de su alianza; el tesoro va al ARCON comun.
--   - El lider reparte el arcon por porcentajes (o paga sueltos).
--   - No se puede atacar un nodo de tu propia alianza.
--   - Los reinos automaticos de la alianza refuerzan sus nodos y
--     atacan los de la alianza enemiga en guerra.
-- ================================================================

-- ----------------------------------------------------------------
-- 1) La propiedad puede ser de una alianza
-- ----------------------------------------------------------------
alter table public.wow_thrones add column if not exists holder_ally text;
create index if not exists wow_thrones_holder_ally_idx on public.wow_thrones(holder_ally);

-- los nodos ya ocupados por un miembro de alianza pasan a ser de la alianza
update public.wow_thrones t set holder_ally = w.alliance
  from public.wow_users w
 where t.holder = w.id and t.holder is not null
   and w.alliance is not null and t.holder_ally is null;

-- ----------------------------------------------------------------
-- 2) Arcon de la alianza y porcentajes de reparto
-- ----------------------------------------------------------------
create table if not exists public.wow_alliance_vault(
  alliance_id text not null references public.wow_alliances(id) on delete cascade,
  key text not null,
  qty numeric(16,2) not null default 0,
  primary key (alliance_id, key)
);
create table if not exists public.wow_alliance_share(
  alliance_id text not null references public.wow_alliances(id) on delete cascade,
  user_id text not null,
  pct numeric(5,2) not null default 0,
  primary key (alliance_id, user_id)
);
alter table public.wow_alliance_vault enable row level security;
alter table public.wow_alliance_share enable row level security;
revoke all on public.wow_alliance_vault from public, anon, authenticated;
revoke all on public.wow_alliance_share from public, anon, authenticated;

-- ---- helpers internos ----
create or replace function public._wow_node_mine(p_holder text, p_ally text, p_uid text, p_ually text)
returns boolean language sql immutable as $$
  select coalesce(p_holder = p_uid, false)
      or coalesce(p_ally = p_ually and p_ally is not null, false)
$$;
revoke all on function public._wow_node_mine(text, text, text, text) from public, anon, authenticated;

create or replace function public._wow_ally_label(p_ally text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select '[' || al.tag || '] ' || al.name from wow_alliances al where al.id = p_ally), '')
$$;
revoke all on function public._wow_ally_label(text) from public, anon, authenticated;

create or replace function public._wow_vault_add(p_ally text, p_key text, p_qty numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if p_ally is null or coalesce(p_qty,0) <= 0 then return; end if;
  insert into wow_alliance_vault(alliance_id, key, qty) values (p_ally, p_key, p_qty)
    on conflict (alliance_id, key) do update set qty = wow_alliance_vault.qty + excluded.qty;
end $$;
revoke all on function public._wow_vault_add(text, text, numeric) from public, anon, authenticated;

create or replace function public._wow_ally_of(p_uid text)
returns text language sql stable security definer set search_path to 'public' as $$
  select alliance from wow_users where id = p_uid
$$;
revoke all on function public._wow_ally_of(text) from public, anon, authenticated;

create or replace function public._wow_ally_leader(p_ally text)
returns text language sql stable security definer set search_path to 'public' as $$
  select leader from wow_alliances where id = p_ally
$$;
revoke all on function public._wow_ally_leader(text) from public, anon, authenticated;

create or replace function public._wow_res_name(p_key text)
returns text language sql immutable as $$
  select case p_key
    when 'gold' then 'oro' when 'wood' then 'madera' when 'ore' then 'mineral' when 'cup' then 'CUP'
    when 'soldado' then 'soldados' when 'arquero' then 'arqueros' when 'jinete' then 'jinetes'
    when 'mago' then 'magos' when 'paladin' then 'paladines' when 'dragon' then 'dragones'
    else p_key end
$$;
revoke all on function public._wow_res_name(text) from public, anon, authenticated;

create or replace function public._wow_res_str(p_json jsonb)
returns text language sql immutable as $$
  select coalesce(string_agg(t.txt, ', ' order by t.k), '')
    from (select key k, trim(to_char((value)::numeric, 'FM999999990.##')) || ' ' || _wow_res_name(key) txt
            from jsonb_each_text(coalesce(p_json, '{}'::jsonb))) t
$$;
revoke all on function public._wow_res_str(jsonb) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- 3) Info de nodos: dueño visible + "es mio / de mi alianza"
-- ----------------------------------------------------------------
create or replace function public._wow_fort_info(p_uid text, p_kind text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare t wow_thrones; arr jsonb := '[]'::jsonb; g numeric; tr jsonb; fac text; hist jsonb;
        ua text; lab text;
begin
  ua := _wow_ally_of(p_uid);
  for t in select * from wow_thrones where kind = p_kind order by node loop
    select coalesce(sum((value)::numeric),0) into g from jsonb_each_text(t.garrison);
    select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into tr
      from wow_throne_treasure where node = t.node and qty > 0;
    select coalesce(jsonb_agg(jsonb_build_object(
        'kind', h.kind, 'who', h.actor_name, 'who_id', h.actor,
        'detail', h.detail, 'created', h.created) order by h.id desc), '[]'::jsonb)
      into hist from (select * from wow_throne_history where node = t.node order by id desc limit 8) h;
    fac := null;
    if t.holder is not null then select faction into fac from wow_users where id = t.holder; end if;
    lab := null;
    if t.holder_ally is not null then lab := _wow_ally_label(t.holder_ally); end if;
    arr := arr || jsonb_build_object(
      'node', t.node, 'name', t.name, 'kind', t.kind,
      'holder', t.holder, 'holder_name', t.holder_name,
      'holder_ally', t.holder_ally, 'ally', lab,
      'faction', fac, 'garrison', coalesce(g,0), 'gdetail', t.garrison, 'since', t.since_ms,
      'mine', _wow_node_mine(t.holder, t.holder_ally, p_uid, ua), 'treasure', tr, 'history', hist);
  end loop;
  return arr;
end $$;
revoke all on function public._wow_fort_info(text, text) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- 4) Llegada de tropas a un nodo (copia de _wow_throne_land con
--    propiedad de alianza y tesoro al arcon)
-- ----------------------------------------------------------------
create or replace function public._wow_throne_land(p_fleet_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  f wow_fleets; u wow_users; t wow_thrones; ms bigint; z record; r record;
  sim jsonb; surv jsonb; msg jsonb; prev text; ret integer; ually text; lab text;
  a_forge int; a_fort int; d_forge int; d_fort int; d_wall int;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  select * into f from wow_fleets where id = p_fleet_id;
  if f.id is null then return; end if;
  select * into u from wow_users where id = f.attacker;
  if u.id is null then delete from wow_fleets where id = f.id; return; end if;
  select * into t from wow_thrones where node = f.node for update;

  -- ---- reclamar tesoro ----
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
      -- si el nodo es de una alianza, el tesoro se queda en el arcon comun
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

  -- ---- refuerzo: suma a la guarnicion; si ya no es tuyo, vuelve a casa ----
  if f.kind = 'throne_rein' then
    if t.node is not null and _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
      surv := t.garrison;
      for z in select key, value::int from jsonb_each_text(f.troops) loop
        surv := jsonb_set(surv, array[z.key], to_jsonb(coalesce((surv->>z.key)::int,0) + z.value), true);
      end loop;
      update wow_thrones set garrison = surv where node = t.node;
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

  -- ---- asalto: si el objetivo desaparecio, las tropas vuelven ----
  if t.node is null then
    ret := _wow_travel_node(u.pos, _wow_pos_node(u.pos));
    update wow_fleets set state = 'returning', arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who','','win',false,
        'note','El objetivo ya no existe: tus tropas vuelven a casa.','created',ms), ms);
    return;
  end if;

  -- ---- libre o guarnicion vacia: se ocupa sin lucha ----
  if coalesce(t.holder,'') = '' or t.garrison = '{}'::jsonb then
    ually := u.alliance;
    update wow_thrones set holder = u.id, holder_name = u.name, holder_ally = ually,
      since_ms = ms, garrison = f.troops, accrue_ms = ms where node = t.node;
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

  -- ---- batalla contra la guarnicion (muros/herreria/fortaleza del duenio) ----
  prev := t.holder_name;
  a_forge := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'herreria'), 0);
  a_fort  := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'fortaleza'), 0);
  d_forge := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'herreria'), 0);
  d_fort  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'fortaleza'), 0);
  d_wall  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'muralla'), 0);
  sim := _wow_sim(f.troops, t.garrison, d_wall, (ms/1000) + t.node*131,
                  1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort);
  if (sim->>'winner') = 'attacker' then
    ually := u.alliance;
    surv := '{}'::jsonb;
    for z in select key, value from jsonb_each_text(sim->'a_left') loop
      if (z.value)::int > 0 then surv := surv || jsonb_build_object(z.key, (z.value)::int); end if;
    end loop;
    update wow_thrones set holder = u.id, holder_name = u.name, holder_ally = ually,
      since_ms = ms, garrison = surv, accrue_ms = ms where node = t.node;
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
    perform _wow_throne_log(t.node, 'defended', u.id, u.name, jsonb_build_object('holder', prev));
    perform _wow_event('throne', '🛡️ La guarnición de ' || t.name || ' ha rechazado el ataque de ' || u.name || '.');
    insert into wow_reports(owner, kind, data, created) values
      (u.id, 'out', jsonb_build_object('dir','throne','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms),
      (t.holder, 'in', jsonb_build_object('dir','throne_in','who',t.name,'win',false,'from',u.name,'battle',sim,'created',ms), ms);
  end if;
  delete from wow_fleets where id = f.id;
end $$;
revoke all on function public._wow_throne_land(bigint) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- 5) Atacar / reforzar / retirar / reclamar con propiedad de alianza
-- ----------------------------------------------------------------
create or replace function public.wow_throne_attack(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; z record; travel integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian ni conquistan.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if t.holder_ally is not null and t.holder_ally = u.alliance then
    raise exception 'Ese lugar ya es de tu alianza.'; end if;
  if exists(select 1 from wow_fleets where attacker = u.id and node = p_node and state = 'outbound') then
    raise exception 'Ya tienes un ejército en camino a %.', t.name; end if;
  for z in select key, value::int from jsonb_each_text(army) loop
    perform _wow_mkt_sub(u.id, z.key, z.value);
  end loop;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'outbound', 'throne_atk', ms, ms + travel*1000, ms);
  perform _wow_event('throne', '⚔️ ' || u.name || ' ha enviado un ejército contra ' || t.name || '.');
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name);
end $$;
grant execute on function public.wow_throne_attack(text, integer, jsonb) to anon, authenticated;

create or replace function public.wow_throne_reinforce(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; z record; travel integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if not _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
    raise exception 'No controlas ese lugar.'; end if;
  if exists(select 1 from wow_fleets where attacker = u.id and node = p_node and state = 'outbound') then
    raise exception 'Ya tienes un ejército en camino a %.', t.name; end if;
  for z in select key, value::int from jsonb_each_text(army) loop
    perform _wow_mkt_sub(u.id, z.key, z.value);
  end loop;
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'outbound', 'throne_rein', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name);
end $$;
grant execute on function public.wow_throne_reinforce(text, integer, jsonb) to anon, authenticated;

create or replace function public.wow_throne_withdraw(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; newg jsonb; z record; left_g int; travel integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if not _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
    raise exception 'No controlas ese lugar.'; end if;
  for z in select key, value::int from jsonb_each_text(army) loop
    if coalesce((t.garrison->>z.key)::int, 0) < z.value then
      raise exception 'No tienes tantas tropas de ese tipo en la guarnición.'; end if;
  end loop;
  newg := t.garrison;
  for z in select key, value::int from jsonb_each_text(army) loop
    left_g := coalesce((newg->>z.key)::int, 0) - z.value;
    if left_g > 0 then
      newg := jsonb_set(newg, array[z.key], to_jsonb(left_g), true);
    else
      newg := newg - z.key;
    end if;
  end loop;
  update wow_thrones set garrison = newg where node = t.node;
  perform _wow_throne_log(t.node, 'withdraw', u.id, u.name, jsonb_build_object('troops', army));
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'returning', 'throne_with', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000,
                            'empty', (newg = '{}'::jsonb), 'target', t.name);
end $$;
grant execute on function public.wow_throne_withdraw(text, integer, jsonb) to anon, authenticated;

create or replace function public.wow_throne_claim(p_token text, p_node integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; travel integer; have numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if not _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
    raise exception 'No controlas ese lugar.'; end if;
  if exists(select 1 from wow_fleets where attacker = u.id and node = p_node and kind = 'throne_claim' and state = 'outbound') then
    raise exception 'Ya tienes una partida en camino a reclamar el tesoro de %.', t.name; end if;
  perform _wow_throne_accrue();
  select coalesce(sum(qty),0) into have from wow_throne_treasure where node = p_node;
  if have <= 0 then raise exception 'No hay tesoro que reclamar todavía.'; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, '{}'::jsonb, '{}'::jsonb, 'outbound', 'throne_claim', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000, 'target', t.name,
    'ally', _wow_ally_label(t.holder_ally));
end $$;
grant execute on function public.wow_throne_claim(text, integer) to anon, authenticated;

-- ----------------------------------------------------------------
-- 6) Arcon de la alianza: ver, fijar porcentajes, repartir y pagar
-- ----------------------------------------------------------------
create or replace function public.wow_alliance_vault(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a text; islead boolean; tr jsonb; mem jsonb; tot numeric := 0; sm numeric := 0;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  a := u.alliance;
  if a is null then return jsonb_build_object('ok', true, 'vault', '{}'::jsonb, 'members', '[]'::jsonb,
    'is_leader', false, 'sum', 0); end if;
  islead := (u.id = _wow_ally_leader(a));
  select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into tr
    from wow_alliance_vault where alliance_id = a and qty > 0;
  select coalesce(sum(qty),0) into tot from wow_alliance_vault where alliance_id = a;
  select coalesce(sum(pct),0) into sm from wow_alliance_share where alliance_id = a
    and user_id in (select id from wow_users where alliance = a and active);
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', w.id, 'name', w.name, 'pct', coalesce(s.pct, 0),
      'me', (w.id = u.id), 'leader', (w.id = _wow_ally_leader(a))) order by w.created), '[]'::jsonb)
    into mem
    from wow_users w
    left join wow_alliance_share s on s.alliance_id = a and s.user_id = w.id
   where w.alliance = a and w.active;
  return jsonb_build_object('ok', true, 'alliance', a, 'is_leader', islead,
    'tag', coalesce((select tag from wow_alliances where id = a), ''),
    'name', coalesce((select name from wow_alliances where id = a), ''),
    'vault', tr, 'total', tot, 'members', mem, 'sum', coalesce(sm,0));
end $$;
grant execute on function public.wow_alliance_vault(text) to anon, authenticated;

create or replace function public.wow_alliance_setshare(p_token text, p_id text, p_pct numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a text; sm numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  a := u.alliance;
  if a is null then raise exception 'No estás en ninguna alianza.'; end if;
  if u.id <> _wow_ally_leader(a) then raise exception 'Solo el líder de la alianza reparte el arcón.'; end if;
  if not exists(select 1 from wow_users w where w.id = p_id and w.alliance = a) then
    raise exception 'Ese reino no está en tu alianza.'; end if;
  if p_pct is null or p_pct < 0 or p_pct > 100 then raise exception 'El porcentaje debe estar entre 0 y 100.'; end if;
  insert into wow_alliance_share(alliance_id, user_id, pct) values (a, p_id, round(p_pct,2))
    on conflict (alliance_id, user_id) do update set pct = excluded.pct;
  select coalesce(sum(pct),0) into sm from wow_alliance_share where alliance_id = a;
  return jsonb_build_object('ok', true, 'id', p_id, 'pct', round(p_pct,2), 'sum', sm);
end $$;
grant execute on function public.wow_alliance_setshare(text, text, numeric) to anon, authenticated;

create or replace function public.wow_alliance_pay(p_token text, p_id text, p_key text, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a text; have numeric; q numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  a := u.alliance;
  if a is null then raise exception 'No estás en ninguna alianza.'; end if;
  if u.id <> _wow_ally_leader(a) then raise exception 'Solo el líder de la alianza reparte el arcón.'; end if;
  if not exists(select 1 from wow_users w where w.id = p_id and w.alliance = a) then
    raise exception 'Ese reino no está en tu alianza.'; end if;
  q := coalesce(p_qty, 0);
  if q <= 0 then raise exception 'Cantidad inválida.'; end if;
  select coalesce(qty,0) into have from wow_alliance_vault where alliance_id = a and key = p_key;
  have := coalesce(have, 0);
  if have <= 0 then raise exception 'No hay % en el arcón.', _wow_res_name(p_key); end if;
  if have < q then raise exception 'Solo hay % de % en el arcón.', have, _wow_res_name(p_key); end if;
  perform _wow_mkt_add(p_id, p_key, q);
  update wow_alliance_vault set qty = qty - q where alliance_id = a and key = p_key;
  perform _wow_event('alliance', '💰 ' || u.name || ' ha repartido ' || trim(to_char(q, 'FM999999990.##')) || ' ' ||
    _wow_res_name(p_key) || ' a ' || (select name from wow_users where id = p_id) || ' del arcón de su alianza.');
  return jsonb_build_object('ok', true, 'id', p_id, 'key', p_key, 'qty', q);
end $$;
grant execute on function public.wow_alliance_pay(text, text, text, numeric) to anon, authenticated;

create or replace function public.wow_alliance_distribute(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; a text; sm numeric; m record; v record; snap jsonb;
  amt numeric; have numeric; paid jsonb; n integer := 0;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  a := u.alliance;
  if a is null then raise exception 'No estás en ninguna alianza.'; end if;
  if u.id <> _wow_ally_leader(a) then raise exception 'Solo el líder de la alianza reparte el arcón.'; end if;
  select coalesce(sum(pct),0) into sm from wow_alliance_share
   where alliance_id = a and user_id in (select id from wow_users where alliance = a and active);
  if sm > 100.1 then raise exception 'Los porcentajes suman %: no pueden pasar de 100.', round(sm,1); end if;
  select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into snap
    from wow_alliance_vault where alliance_id = a and qty > 0;
  if snap = '{}'::jsonb then raise exception 'El arcón de la alianza está vacío.'; end if;
  for m in select w.id, w.name, coalesce(s.pct,0) pct
             from wow_users w left join wow_alliance_share s on s.alliance_id = a and s.user_id = w.id
            where w.alliance = a and w.active and coalesce(s.pct,0) > 0
            order by coalesce(s.pct,0) desc, w.created loop
    paid := '{}'::jsonb;
    for v in select key, (value)::numeric qty from jsonb_each_text(snap) loop
      select coalesce(qty,0) into have from wow_alliance_vault where alliance_id = a and key = v.key for update;
      have := coalesce(have, 0);
      if have > 0 then
        if _wow_mkt_is_troop(v.key) then
          amt := floor(v.qty * m.pct / 100.0);
        else
          amt := round(v.qty * m.pct / 100.0, 2);
        end if;
        if amt > have then amt := have; end if;
        if amt > 0 then
          perform _wow_mkt_add(m.id, v.key, amt);
          update wow_alliance_vault set qty = qty - amt where alliance_id = a and key = v.key;
          paid := paid || jsonb_build_object(v.key, amt);
        end if;
      end if;
    end loop;
    if paid <> '{}'::jsonb then
      n := n + 1;
      perform _wow_event('alliance', '💰 ' || m.name || ' recibe del arcón de la alianza: ' || _wow_res_str(paid) || '.');
    end if;
  end loop;
  delete from wow_alliance_vault where alliance_id = a and qty <= 0.001;
  return jsonb_build_object('ok', true, 'members_paid', n);
end $$;
grant execute on function public.wow_alliance_distribute(text) to anon, authenticated;

-- ----------------------------------------------------------------
-- 7) Los reinos automaticos: refuerzan y reclaman para su alianza,
--    y en guerra atacan los nodos de la alianza enemiga
-- ----------------------------------------------------------------
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
  ua := _wow_ally_of(p_id);

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
      -- a) conquistar una aldea libre que no sea de su alianza (mejor botin, menos conflicto)
      select th.node into node from wow_thrones th
        where th.kind = 'aldea'
          and th.holder is distinct from p_id
          and (th.holder_ally is null or ua is null or th.holder_ally <> ua)
          and coalesce((select sum((x.value)::int) from jsonb_each_text(th.garrison) x), 0) = 0
        order by random() limit 1;
      if node is not null then
        begin perform wow_throne_attack(tok, node, army); exception when others then null; end;
      else
        -- a2) si su alianza esta en guerra, va a por un nodo de la alianza enemiga
        if ua is not null then
          select th.node into node from wow_thrones th
            join wow_ally_wars wr on wr.active and (wr.a = ua or wr.b = ua)
              and th.holder_ally = case when wr.a = ua then wr.b else wr.a end
           where th.holder_ally is not null
           order by random() limit 1;
          if node is not null then
            begin perform wow_throne_attack(tok, node, army); exception when others then null; end;
          end if;
        end if;
      end if;
      if node is null then
        prot := _wow_protect_below();
        tgt := null;
        -- b) si su alianza esta en guerra, va a por el reino enemigo (asi luchan juntos y suman para la alianza)
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

  -- 5) cobrar el tesoro de lo que controle (suyo o de su alianza: va al arcon)
  if random() < 0.35 then
    select th.node into node from wow_thrones th
      where th.holder = p_id or (ua is not null and th.holder_ally = ua)
      order by random() limit 1;
    if node is not null then
      begin perform wow_throne_claim(tok, node); exception when others then null; end;
    end if;
  end if;

  -- 6) los mas fuertes refuerzan sus nodos y los de su alianza
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

  -- 7) cadencia humana: turnos irregulares y, a veces, un descanso largo
  if random() < 0.12 then
    nx := ms + (30*60000 + (random()*90*60000)::bigint)::bigint;   -- 30-120 min fuera
  else
    nx := ms + (base*60000*(0.5 + random()))::bigint;              -- 0.5x - 1.5x
  end if;
  update wow_bots set next_ms = nx, last_act_ms = ms where user_id = p_id;
end $$;
revoke all on function public._wow_bot_act(text) from public, anon, authenticated;

-- ================================================================
-- APENDICE DIPLOMACIA: pactos de no agresion (treguas) entre alianzas
--   (generado desde wow-diplo.sql)
-- ================================================================
-- ================================================================
-- DIPLOMACIA v1: pactos de no agresion entre alianzas
--   (generado desde wow-diplo.sql)
--   - el lider propone un pacto (24/48/72 h o sin caducidad); caduca en 24 h
--   - el lider contrario acepta o rechaza (aceptar una oferta en guerra = paz)
--   - mientras hay pacto vigente NO se puede atacar ni espiar (tambien los bots)
--   - cualquiera de los dos lideres puede cancelarlo; sin castigo
--   - declarar la guerra rompe el pacto automaticamente
-- ================================================================

-- ---------- tabla ----------
create table if not exists public.wow_ally_pacts(
  id bigserial primary key,
  a text not null,
  b text not null,
  a_tag text not null default '',
  b_tag text not null default '',
  a_name text not null default '',
  b_name text not null default '',
  state text not null default 'oferta',
  offered_by text not null default '',
  hours integer not null default 0,
  started bigint not null default 0,
  ends bigint not null default 0,
  offer_ends bigint not null default 0,
  ended bigint not null default 0,
  created bigint not null default 0
);
create index if not exists wow_ally_pacts_state_idx on public.wow_ally_pacts (state, ends);
create index if not exists wow_ally_pacts_pair_idx on public.wow_ally_pacts (a, b);
alter table public.wow_ally_pacts enable row level security;

-- ---------- helper: hay pacto activo entre dos alianzas? ----------
create or replace function public._wow_pact_active(p_a text, p_b text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists(select 1 from wow_ally_pacts
     where state = 'activo' and ((a = p_a and b = p_b) or (a = p_b and b = p_a)))
$$;
revoke all on function public._wow_pact_active(text, text) from public, anon, authenticated;

-- ---------- caducar ofertas y pactos vencidos ----------
create or replace function public._wow_pact_tick()
returns void language plpgsql security definer set search_path to 'public' as $$
declare r record; vms bigint;
begin
  vms := (extract(epoch from now())*1000)::bigint;
  for r in select * from wow_ally_pacts where state = 'oferta' and offer_ends > 0 and offer_ends <= vms loop
    update wow_ally_pacts set state = 'expirado', ended = vms where id = r.id;
    perform _wow_event('war', '⌛ La oferta de pacto entre [ ' || r.a_tag || ' ] y [ ' || r.b_tag || ' ] ha caducado.');
  end loop;
  for r in select * from wow_ally_pacts where state = 'activo' and ends > 0 and ends <= vms loop
    update wow_ally_pacts set state = 'expirado', ended = vms where id = r.id;
    perform _wow_event('war', '🤝 El pacto de no agresión entre [ ' || r.a_tag || ' ] y [ ' || r.b_tag || ' ] ha expirado.');
  end loop;
end $$;
revoke all on function public._wow_pact_tick() from public, anon, authenticated;

-- ---------- cerrar guerras vencidas (y caducar pactos) ----------
create or replace function public._wow_war_tick()
returns void language plpgsql security definer set search_path to 'public' as $$
declare r record; vms bigint; vawin boolean; vwin_tag text;
begin
  vms := (extract(epoch from now())*1000)::bigint;
  for r in select * from wow_ally_wars where active and ends <= vms loop
    vawin := r.a_score >= r.b_score;
    update wow_ally_wars set active = false, a_won = vawin where id = r.id;
    if vawin then
      update wow_alliances set war_wins = war_wins + 1 where id = r.a;
      update wow_alliances set war_losses = war_losses + 1 where id = r.b;
      vwin_tag := r.a_tag;
    else
      update wow_alliances set war_wins = war_wins + 1 where id = r.b;
      update wow_alliances set war_losses = war_losses + 1 where id = r.a;
      vwin_tag := r.b_tag;
    end if;
    perform _wow_event('war',
      '🏳️ La guerra [ ' || r.a_tag || ' ] vs [ ' || r.b_tag || ' ] ha terminado. Vence [ ' || vwin_tag ||
      ' ] (' || greatest(r.a_score, r.b_score) || '-' || least(r.a_score, r.b_score) || ').');
  end loop;
  perform _wow_pact_tick();
end $$;
revoke all on function public._wow_war_tick() from public, anon, authenticated;

-- ---------- bloqueo de ataques y espionaje con pacto vigente ----------
-- (trigger sobre wow_fleets: cubre ataques a reinos, a nodos y espionaje;
--  los reinos automaticos ya envuelven sus acciones en try/except, asi que
--  el error tambien les frena sin perder tropas)
create or replace function public._wow_pact_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare va text; vb text; vally text; vholder text; vlab text;
begin
  if NEW.kind is null or NEW.kind not in ('attack', 'spy', 'throne_atk') then return NEW; end if;
  va := _wow_ally_of(NEW.attacker);
  if va is null then return NEW; end if;
  if NEW.kind = 'throne_atk' then
    select th.holder_ally, th.holder into vally, vholder from wow_thrones th where th.node = NEW.node;
    vb := coalesce(vally, _wow_ally_of(vholder));
  else
    vb := _wow_ally_of(NEW.target);
  end if;
  if vb is null or vb = va then return NEW; end if;
  select case when p.a = va then p.b_tag else p.a_tag end into vlab
    from wow_ally_pacts p
   where p.state = 'activo' and ((p.a = va and p.b = vb) or (p.a = vb and p.b = va))
   limit 1;
  if vlab is null then return NEW; end if;
  raise exception 'Hay un pacto de no agresión con [%]: no puedes atacar ni espiar.', vlab;
end $$;
revoke all on function public._wow_pact_guard() from public, anon, authenticated;
drop trigger if exists wow_pact_guard on public.wow_fleets;
create trigger wow_pact_guard before insert on public.wow_fleets
  for each row execute function public._wow_pact_guard();

-- ---------- proponer pacto ----------
create or replace function public.wow_ally_pact_offer(p_token text, p_target text, p_hours integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ra wow_alliances; rb wow_alliances; vms bigint; vid bigint; vwar boolean;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'Entra a una alianza para pactar.'; end if;
  select * into ra from wow_alliances where id = u.alliance;
  if ra.leader <> u.id then raise exception 'Solo el líder de la alianza puede proponer pactos.'; end if;
  select * into rb from wow_alliances where id = p_target;
  if rb.id is null then raise exception 'Esa alianza no existe.'; end if;
  if ra.id = rb.id then raise exception 'No puedes pactar con tu propia alianza.'; end if;
  p_hours := coalesce(p_hours, 0);
  if p_hours not in (0, 24, 48, 72) then raise exception 'Duración no válida: 24, 48, 72 horas o sin caducidad.'; end if;
  if _wow_pact_active(ra.id, rb.id) then raise exception 'Ya tenéis un pacto de no agresión con esa alianza.'; end if;
  if exists(select 1 from wow_ally_pacts
              where state = 'oferta' and ((a = ra.id and b = rb.id) or (a = rb.id and b = ra.id))) then
    raise exception 'Ya hay una oferta de pacto pendiente con esa alianza.'; end if;
  vms := (extract(epoch from now())*1000)::bigint;
  insert into wow_ally_pacts (a, b, a_tag, b_tag, a_name, b_name, state, offered_by, hours, offer_ends, created)
  values (ra.id, rb.id, ra.tag, rb.tag, ra.name, rb.name, 'oferta', ra.id, p_hours, vms + 86400000, vms)
  returning id into vid;
  vwar := exists(select 1 from wow_ally_wars
                  where active and ((a = ra.id and b = rb.id) or (a = rb.id and b = ra.id)));
  if vwar then
    perform _wow_event('war', '🕊️ La alianza [ ' || ra.tag || ' ] ofrece la paz a [ ' || rb.tag || ' ].');
  else
    perform _wow_event('war', '📨 La alianza [ ' || ra.tag || ' ] propone un pacto de no agresión a [ ' || rb.tag || ' ].');
  end if;
  return jsonb_build_object('ok', true, 'id', vid);
end $$;
grant execute on function public.wow_ally_pact_offer(text, text, integer) to anon, authenticated;

-- ---------- aceptar / rechazar ----------
create or replace function public.wow_ally_pact_answer(p_token text, p_id bigint, p_accept boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ra wow_alliances; r wow_ally_pacts; w record; vms bigint; vawin boolean; vdur text;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'No estás en ninguna alianza.'; end if;
  select * into ra from wow_alliances where id = u.alliance;
  if ra.leader <> u.id then raise exception 'Solo el líder de la alianza puede responder.'; end if;
  perform _wow_pact_tick();
  select * into r from wow_ally_pacts where id = p_id and state = 'oferta';
  if r.id is null then raise exception 'Esa oferta ya no está disponible.'; end if;
  if u.alliance not in (r.a, r.b) then raise exception 'Esa oferta no es de tu alianza.'; end if;
  if r.offered_by = u.alliance then raise exception 'No puedes responder a tu propia oferta.'; end if;
  vms := (extract(epoch from now())*1000)::bigint;
  if coalesce(p_accept, false) then
    update wow_ally_pacts set state = 'activo', started = vms,
      ends = case when coalesce(r.hours, 0) > 0 then vms + (r.hours::bigint * 3600000) else 0 end
     where id = r.id;
    select * into w from wow_ally_wars
      where active and ((a = r.a and b = r.b) or (a = r.b and b = r.a)) limit 1;
    if w.id is not null then
      vawin := w.a_score >= w.b_score;
      update wow_ally_wars set active = false, a_won = vawin where id = w.id;
      if vawin then
        update wow_alliances set war_wins = war_wins + 1 where id = r.a;
        update wow_alliances set war_losses = war_losses + 1 where id = r.b;
      else
        update wow_alliances set war_wins = war_wins + 1 where id = r.b;
        update wow_alliances set war_losses = war_losses + 1 where id = r.a;
      end if;
      perform _wow_event('war', '🕊️ Paz firmada entre [ ' || r.a_tag || ' ] y [ ' || r.b_tag ||
        ' ]: la guerra termina ' || greatest(w.a_score, w.b_score) || '-' || least(w.a_score, w.b_score) || '.');
    else
      vdur := case when coalesce(r.hours, 0) > 0 then (r.hours || ' h') else 'sin caducidad' end;
      perform _wow_event('war', '🤝 Pacto de no agresión firmado entre [ ' || r.a_tag || ' ] y [ ' || r.b_tag || ' ] (' || vdur || ').');
    end if;
    return jsonb_build_object('ok', true, 'state', 'activo');
  end if;
  update wow_ally_pacts set state = 'rechazado', ended = vms where id = r.id;
  perform _wow_event('war', '❌ [ ' || ra.tag || ' ] ha rechazado el pacto propuesto por [ ' ||
    (case when r.offered_by = r.a then r.a_tag else r.b_tag end) || ' ].');
  return jsonb_build_object('ok', true, 'state', 'rechazado');
end $$;
grant execute on function public.wow_ally_pact_answer(text, bigint, boolean) to anon, authenticated;

-- ---------- cancelar (pacto o propia oferta) ----------
create or replace function public.wow_ally_pact_cancel(p_token text, p_id bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ra wow_alliances; r wow_ally_pacts; vms bigint; vother text;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'No estás en ninguna alianza.'; end if;
  select * into ra from wow_alliances where id = u.alliance;
  if ra.leader <> u.id then raise exception 'Solo el líder de la alianza puede cancelarlo.'; end if;
  perform _wow_pact_tick();
  select * into r from wow_ally_pacts where id = p_id and state in ('oferta', 'activo');
  if r.id is null then raise exception 'Ese pacto ya no está vigente.'; end if;
  if u.alliance not in (r.a, r.b) then raise exception 'Ese pacto no es de tu alianza.'; end if;
  if r.state = 'oferta' and r.offered_by <> u.alliance then
    raise exception 'Solo quien propuso la oferta puede retirarla (el otro líder la acepta o la rechaza).'; end if;
  vms := (extract(epoch from now())*1000)::bigint;
  vother := case when u.alliance = r.a then r.b_tag else r.a_tag end;
  if r.state = 'oferta' then
    update wow_ally_pacts set state = 'expirado', ended = vms where id = r.id;
    perform _wow_event('war', '⌛ [ ' || ra.tag || ' ] retira su propuesta de pacto a [ ' || vother || ' ].');
  else
    update wow_ally_pacts set state = 'cancelado', ended = vms where id = r.id;
    perform _wow_event('war', '🏴 [ ' || ra.tag || ' ] ha cancelado el pacto de no agresión con [ ' || vother || ' ].');
  end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_ally_pact_cancel(text, bigint) to anon, authenticated;

-- ---------- estado diplomatico ----------
create or replace function public.wow_ally_diplo(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; pacts jsonb; oin jsonb; oout jsonb; vlead boolean;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_war_tick();
  if u.alliance is null then
    return jsonb_build_object('pacts', '[]'::jsonb, 'offers_in', '[]'::jsonb, 'offers_out', '[]'::jsonb,
      'is_leader', false, 'mine', null);
  end if;
  vlead := exists(select 1 from wow_alliances a where a.id = u.alliance and a.leader = u.id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'a', p.a, 'b', p.b, 'a_tag', p.a_tag, 'b_tag', p.b_tag,
           'a_name', p.a_name, 'b_name', p.b_name, 'hours', p.hours,
           'started', p.started, 'ends', p.ends, 'offer_ends', p.offer_ends,
           'offered_by', p.offered_by, 'i_am_a', (u.alliance = p.a)) order by p.id desc), '[]') into pacts
    from wow_ally_pacts p
   where p.state = 'activo' and u.alliance in (p.a, p.b);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'a', p.a, 'b', p.b, 'a_tag', p.a_tag, 'b_tag', p.b_tag,
           'a_name', p.a_name, 'b_name', p.b_name, 'hours', p.hours,
           'started', p.started, 'ends', p.ends, 'offer_ends', p.offer_ends,
           'offered_by', p.offered_by, 'i_am_a', (u.alliance = p.a)) order by p.id desc), '[]') into oin
    from wow_ally_pacts p
   where p.state = 'oferta' and p.offered_by <> u.alliance and u.alliance in (p.a, p.b);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'a', p.a, 'b', p.b, 'a_tag', p.a_tag, 'b_tag', p.b_tag,
           'a_name', p.a_name, 'b_name', p.b_name, 'hours', p.hours,
           'started', p.started, 'ends', p.ends, 'offer_ends', p.offer_ends,
           'offered_by', p.offered_by, 'i_am_a', (u.alliance = p.a)) order by p.id desc), '[]') into oout
    from wow_ally_pacts p
   where p.state = 'oferta' and p.offered_by = u.alliance;
  return jsonb_build_object('pacts', pacts, 'offers_in', oin, 'offers_out', oout,
    'is_leader', vlead, 'mine', u.alliance);
end $$;
grant execute on function public.wow_ally_diplo(text) to anon, authenticated;

-- ---------- declarar guerra (rompe el pacto automaticamente) ----------
create or replace function public.wow_ally_war_declare(p_token text, p_target text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ra wow_alliances; rb wow_alliances; vms bigint; vid bigint;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'Entra a una alianza para declarar guerras.'; end if;
  select * into ra from wow_alliances where id = u.alliance;
  if ra.leader <> u.id then raise exception 'Solo el líder de la alianza puede declarar la guerra.'; end if;
  select * into rb from wow_alliances where id = p_target;
  if rb.id is null then raise exception 'Esa alianza no existe.'; end if;
  if ra.id = rb.id then raise exception 'No puedes declarar la guerra a tu propia alianza.'; end if;
  if exists(select 1 from wow_ally_wars
              where active and ((a = ra.id and b = rb.id) or (a = rb.id and b = ra.id))) then
    raise exception 'Ya hay una guerra activa contra esa alianza.'; end if;
  vms := (extract(epoch from now())*1000)::bigint;
  update wow_ally_pacts set state = 'cancelado', ended = vms
   where state = 'activo' and ((a = ra.id and b = rb.id) or (a = rb.id and b = ra.id));
  if found then
    perform _wow_event('war', '🏴 [ ' || ra.tag || ' ] ha roto el pacto de no agresión con [ ' || rb.tag ||
      ' ] al declararle la guerra.');
  end if;
  insert into wow_ally_wars (a, b, a_tag, b_tag, a_name, b_name, a_score, b_score, started, ends, active, created)
  values (ra.id, rb.id, ra.tag, rb.tag, ra.name, rb.name, 0, 0, vms, vms + 172800000, true, vms)
  returning id into vid;
  perform _wow_event('war', '⚔️ La alianza [ ' || ra.tag || ' ] ha declarado la guerra a [ ' || rb.tag || ' ].');
  return jsonb_build_object('ok', true, 'id', vid);
end $$;
grant execute on function public.wow_ally_war_declare(text, text) to anon, authenticated;

-- ================================================================
-- APENDICE INTERRUPTOR DE REINOS AUTOMATICOS: un boton enciende/apaga todos
--   (generado desde wow-botswitch.sql)
-- ================================================================
-- ================================================================
-- APENDICE INTERRUPTOR DE REINOS AUTOMATICOS (un solo boton)
--   - wow_admin_bot_auto: activa o apaga TODOS los reinos
--     automaticos de golpe.
--       * Activar: todos vuelven a jugar ya y se ven siempre en
--         linea mientras el interruptor este encendido.
--       * Apagar: dejan de jugar y salen del contador en linea al
--         instante.
--   - wow_bots_tick (override):
--       * late (last_ms) de todos los que juegan -> siempre "en
--         linea", aunque su umbral (online_min) sea corto.
--       * sin siestas: nadie deja de actuar mas de 1.5x su ritmo
--         (el nivel sigue marcando la frecuencia: nivel 3 = base 4).
--   - El cron wow_bots ya llama a wow_bots_tick: no hay que tocarlo.
-- ================================================================

-- activar / apagar todos los reinos automaticos
create or replace function public.wow_admin_bot_auto(p_token text, p_on boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; on_ boolean; ms bigint; n integer := 0;
begin
  a := _wow_admin(p_token);
  on_ := coalesce(p_on, false);
  insert into wow_settings(key, val) values ('bot_auto', case when on_ then '1' else '0' end)
    on conflict (key) do update set val = excluded.val;
  ms := (extract(epoch from now())*1000)::bigint;
  if on_ then
    -- vuelven a jugar ya y se ven en linea
    update wow_bots set active = true, next_ms = 0 where active is distinct from true or next_ms is distinct from 0;
    update wow_users set last_ms = ms where id in (select user_id from wow_bots);
  else
    -- dejan de jugar y salen del contador en linea ya mismo
    update wow_bots set active = false where active is distinct from false;
    update wow_users set last_ms = 0 where id in (select user_id from wow_bots);
  end if;
  select count(*) into n from wow_bots;
  return jsonb_build_object('ok', true, 'auto', on_, 'bots', n);
end $$;
grant execute on function public.wow_admin_bot_auto(text, boolean) to anon, authenticated;

-- turno global: avanza el mundo y actua sobre los que les toca
create or replace function public.wow_bots_tick(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare b record; ms bigint; n integer := 0; mx bigint;
begin
  perform _wow_resolve();       -- las flotas aterrizan aunque no haya nadie conectado
  if _wow_bot_auto() = 0 then return jsonb_build_object('ok', true, 'auto', false, 'acted', 0); end if;
  ms := (extract(epoch from now())*1000)::bigint;
  -- siempre en linea: latido de todos los reinos automaticos que juegan
  update wow_users set last_ms = ms
   where active and id in (select user_id from wow_bots where active);
  for b in select user_id, level from wow_bots where active and (p_force or next_ms <= ms) loop
    begin
      perform _wow_bot_act(b.user_id);
      n := n + 1;
    exception when others then
      -- un reino con problemas no debe detener a los demas
      update wow_bots set next_ms = ms + 60000 where user_id = b.user_id;
    end;
    -- sin siestas: nunca espera mas de 1.5x su ritmo
    mx := ms + (((_wow_bot_level(b.level)->>'min')::int * 90000))::bigint;
    update wow_bots set next_ms = least(next_ms, mx) where user_id = b.user_id;
  end loop;
  return jsonb_build_object('ok', true, 'auto', true, 'acted', n);
end $$;
revoke all on function public.wow_bots_tick(boolean) from public, anon, authenticated;

-- ================================================================
-- APENDICE EMBLEMA DE ALIANZA: el lider elige el icono del clan
--   (generado desde wow-emblems.sql)
-- ================================================================
-- ================================================================
-- APENDICE EMBLEMA DE ALIANZA
--   - El lider elige un icono (emoji) para su clan.
--   - El emblema sale en el mapa sobre las ALDEAS y FORTALEZAS
--     conquistadas por la alianza (en vez del 🏛️ por defecto),
--     en la ficha de cada lugar y en la cabecera de la alianza.
--   - wow_alliance_info devuelve el emblema actual y la lista de
--     emblemas disponibles (para pintar el selector).
--   - Solo el lider puede cambiarlo; '' lo quita.
-- ================================================================

alter table public.wow_alliances add column if not exists emblem text not null default '';

-- emblemas disponibles
create or replace function public._wow_emblems()
returns text[] language sql immutable as $$
  select array['🦁','🐺','🐉','🦅','🐻','🐍','🕷️','🦂','🐗','🦌','⚔️','🛡️','👑','💀',
               '🔥','⚡','🌙','☀️','⭐','🌊','🌲','🏔️','🏰','🏹','⚓','🔱']::text[]
$$;
revoke all on function public._wow_emblems() from public, anon, authenticated;

-- emblema de una alianza ('' = sin emblema)
create or replace function public._wow_ally_icon(p_ally text)
returns text language sql stable security definer set search_path to 'public' as $$
  select coalesce((select emblem from wow_alliances where id = p_ally), '')
$$;
revoke all on function public._wow_ally_icon(text) from public, anon, authenticated;

-- elegir o quitar el emblema (solo el lider)
create or replace function public.wow_alliance_emblem(p_token text, p_icon text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a wow_alliances; ic text;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.alliance is null then raise exception 'No estás en ninguna alianza.'; end if;
  select * into a from wow_alliances where id = u.alliance;
  if a.id is null then raise exception 'Esa alianza ya no existe.'; end if;
  if a.leader <> u.id then raise exception 'Solo el líder puede elegir el emblema de la alianza.'; end if;
  ic := btrim(coalesce(p_icon, ''));
  if length(ic) > 8 then raise exception 'Ese emblema no está disponible.'; end if;
  if ic <> '' and not (ic = any(_wow_emblems())) then
    raise exception 'Ese emblema no está disponible.'; end if;
  update wow_alliances set emblem = ic where id = a.id;
  return jsonb_build_object('ok', true, 'emblem', ic);
end $$;
grant execute on function public.wow_alliance_emblem(text, text) to anon, authenticated;

-- ---- ficha de nodos: + emblema del clan que lo tiene ----
create or replace function public._wow_fort_info(p_uid text, p_kind text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare t wow_thrones; arr jsonb := '[]'::jsonb; g numeric; tr jsonb; fac text; hist jsonb;
        ua text; lab text;
begin
  ua := _wow_ally_of(p_uid);
  for t in select * from wow_thrones where kind = p_kind order by node loop
    select coalesce(sum((value)::numeric),0) into g from jsonb_each_text(t.garrison);
    select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into tr
      from wow_throne_treasure where node = t.node and qty > 0;
    select coalesce(jsonb_agg(jsonb_build_object(
        'kind', h.kind, 'who', h.actor_name, 'who_id', h.actor,
        'detail', h.detail, 'created', h.created) order by h.id desc), '[]'::jsonb)
      into hist from (select * from wow_throne_history where node = t.node order by id desc limit 8) h;
    fac := null;
    if t.holder is not null then select faction into fac from wow_users where id = t.holder; end if;
    lab := null;
    if t.holder_ally is not null then lab := _wow_ally_label(t.holder_ally); end if;
    arr := arr || jsonb_build_object(
      'node', t.node, 'name', t.name, 'kind', t.kind,
      'holder', t.holder, 'holder_name', t.holder_name,
      'holder_ally', t.holder_ally, 'ally', lab, 'ally_icon', _wow_ally_icon(t.holder_ally),
      'faction', fac, 'garrison', coalesce(g,0), 'gdetail', t.garrison, 'since', t.since_ms,
      'mine', _wow_node_mine(t.holder, t.holder_ally, p_uid, ua), 'treasure', tr, 'history', hist);
  end loop;
  return arr;
end $$;
revoke all on function public._wow_fort_info(text, text) from public, anon, authenticated;

-- ---- info de la alianza: + emblema actual y emblemas disponibles ----
create or replace function public.wow_alliance_info(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; a wow_alliances; mem jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select * into a from wow_alliances where id = p_id;
  if a.id is null then raise exception 'Esa alianza ya no existe.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', w.id, 'name', w.name, 'faction', w.faction, 'points', _wow_points(w.id),
             'leader', w.id = a.leader, 'me', w.id = u.id)
           order by (w.id = a.leader) desc, w.created), '[]') into mem
    from wow_users w where w.alliance = a.id;
  return jsonb_build_object('id', a.id, 'name', a.name, 'tag', a.tag, 'descr', a.descr,
    'emblem', a.emblem, 'emblems', _wow_emblems(),
    'leader', (select name from wow_users where id = a.leader),
    'members', mem, 'is_member', u.alliance = a.id,
    'is_leader', (u.id = a.leader));
end $$;
grant execute on function public.wow_alliance_info(text, text) to anon, authenticated;

-- ================================================================
-- EL EMBLEMA REPRESENTA A LA ALIANZA: sale junto a su [TAG] en la
-- barra de arriba, el ranking, la lista de alianzas, la diplomacia
-- (guerras y pactos) y el chat global.
-- ================================================================

-- ---- estado del reino: + emblema de mi alianza (barra de arriba) ----
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
             'atk', _wow_atk(v.t), 'hp', _wow_hp(v.t), 'req', _wow_treq(v.t)) order by v.ord), '[]') into trs
    from (values ('soldado',1),('arquero',2),('jinete',3),('mago',4),('paladin',5),('dragon',6)) v(t,ord)
    left join wow_troops t on t.owner_id = u.id and t.tkey = v.t;
  select coalesce(jsonb_agg(jsonb_build_object('kind', q.kind, 'ref', q.ref, 'qty', q.qty, 'unit_ms', q.unit_ms,
           'start', q.start_ms, 'finish', q.finish_ms) order by q.kind), '[]') into que
    from wow_queue q where q.owner_id = u.id;
  pts := (select coalesce(sum(level),0) from wow_buildings where owner_id = u.id) * 100
       + (select coalesce(sum(qty),0) from wow_troops where owner_id = u.id);
  return jsonb_build_object('id', u.id, 'name', u.name, 'faction', u.faction, 'is_admin', u.is_admin,
    'gold', u.gold, 'wood', u.wood, 'ore', u.ore, 'cup', coalesce(u.cup,0), 'capacity', cap, 'rate', rate,
    'buildings', blds, 'troops', trs, 'queue', que->0, 'queues', que, 'points', pts, 'now', ms,
    'alliance', u.alliance,
    'ally_tag', coalesce((select tag from wow_alliances where id = u.alliance), ''),
    'ally_emblem', _wow_ally_icon(u.alliance),
    'online', _wow_online_count());
end $$;
grant execute on function public.wow_state(text) to anon, authenticated;

-- ---- lista de alianzas: + emblema ----
create or replace function public.wow_alliance_list(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', a.id, 'name', a.name, 'tag', a.tag, 'descr', a.descr, 'emblem', a.emblem,
             'members', (select count(*) from wow_users w where w.alliance = a.id),
             'points', (select coalesce(sum(_wow_points(w.id)),0) from wow_users w where w.alliance = a.id),
             'mine', a.id = u.alliance)
           order by (select coalesce(sum(_wow_points(w.id)),0) from wow_users w where w.alliance = a.id) desc, a.created), '[]') into out
    from wow_alliances a;
  return out;
end $$;
grant execute on function public.wow_alliance_list(text) to anon, authenticated;

-- ---- ranking de alianzas: + emblema ----
create or replace function public.wow_alliance_rank(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', x.id, 'name', x.name, 'tag', x.tag, 'emblem', x.emblem,
             'members', x.members, 'points', x.points,
             'troops', x.troops, 'thrones', x.thrones,
             'wins', x.wins, 'losses', x.losses,
             'mine', x.id = u.alliance) order by x.points desc, x.wins desc, x.created), '[]') into out
    from (
      select a.id, a.name, a.tag, a.emblem, a.created,
             a.war_wins as wins, a.war_losses as losses,
             (select count(*) from wow_users w where w.alliance = a.id) as members,
             (select coalesce(sum(_wow_points(w.id)),0) from wow_users w where w.alliance = a.id) as points,
             (select coalesce(sum(t.qty),0) from wow_troops t
                join wow_users w on w.id = t.owner_id where w.alliance = a.id) as troops,
             (select count(*) from wow_thrones th
                join wow_users w on w.id = th.holder where w.alliance = a.id) as thrones
        from wow_alliances a
    ) x;
  return out;
end $$;
grant execute on function public.wow_alliance_rank(text) to anon, authenticated;

-- ---- guerras: + emblema de cada bando ----
create or replace function public.wow_ally_wars(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_war_tick();
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', w.id, 'a', w.a, 'b', w.b,
             'a_tag', w.a_tag, 'b_tag', w.b_tag,
             'a_name', w.a_name, 'b_name', w.b_name,
             'a_icon', _wow_ally_icon(w.a), 'b_icon', _wow_ally_icon(w.b),
             'a_score', w.a_score, 'b_score', w.b_score,
             'ends', w.ends, 'started', w.started,
             'mine', (u.alliance in (w.a, w.b)),
             'i_am_a', (u.alliance = w.a))
           order by w.started desc), '[]') into out
    from wow_ally_wars w where w.active;
  return jsonb_build_object('wars', out, 'mine', u.alliance);
end $$;
grant execute on function public.wow_ally_wars(text) to anon, authenticated;

-- ---- diplomacia (pactos y ofertas): + emblema del rival ----
create or replace function public.wow_ally_diplo(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; pacts jsonb; oin jsonb; oout jsonb; vlead boolean;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_war_tick();
  if u.alliance is null then
    return jsonb_build_object('pacts', '[]'::jsonb, 'offers_in', '[]'::jsonb, 'offers_out', '[]'::jsonb,
      'is_leader', false, 'mine', null);
  end if;
  vlead := exists(select 1 from wow_alliances a where a.id = u.alliance and a.leader = u.id);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'a', p.a, 'b', p.b, 'a_tag', p.a_tag, 'b_tag', p.b_tag,
           'a_name', p.a_name, 'b_name', p.b_name, 'hours', p.hours,
           'a_icon', _wow_ally_icon(p.a), 'b_icon', _wow_ally_icon(p.b),
           'started', p.started, 'ends', p.ends, 'offer_ends', p.offer_ends,
           'offered_by', p.offered_by, 'i_am_a', (u.alliance = p.a)) order by p.id desc), '[]') into pacts
    from wow_ally_pacts p
   where p.state = 'activo' and u.alliance in (p.a, p.b);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'a', p.a, 'b', p.b, 'a_tag', p.a_tag, 'b_tag', p.b_tag,
           'a_name', p.a_name, 'b_name', p.b_name, 'hours', p.hours,
           'a_icon', _wow_ally_icon(p.a), 'b_icon', _wow_ally_icon(p.b),
           'started', p.started, 'ends', p.ends, 'offer_ends', p.offer_ends,
           'offered_by', p.offered_by, 'i_am_a', (u.alliance = p.a)) order by p.id desc), '[]') into oin
    from wow_ally_pacts p
   where p.state = 'oferta' and p.offered_by <> u.alliance and u.alliance in (p.a, p.b);
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', p.id, 'a', p.a, 'b', p.b, 'a_tag', p.a_tag, 'b_tag', p.b_tag,
           'a_name', p.a_name, 'b_name', p.b_name, 'hours', p.hours,
           'a_icon', _wow_ally_icon(p.a), 'b_icon', _wow_ally_icon(p.b),
           'started', p.started, 'ends', p.ends, 'offer_ends', p.offer_ends,
           'offered_by', p.offered_by, 'i_am_a', (u.alliance = p.a)) order by p.id desc), '[]') into oout
    from wow_ally_pacts p
   where p.state = 'oferta' and p.offered_by = u.alliance;
  return jsonb_build_object('pacts', pacts, 'offers_in', oin, 'offers_out', oout,
    'is_leader', vlead, 'mine', u.alliance);
end $$;
grant execute on function public.wow_ally_diplo(text) to anon, authenticated;

-- ---- chat global: + emblema de la alianza del que escribe ----
create or replace function public.wow_gchat(p_token text, p_since bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id, 'name', c.name, 'faction', c.faction, 'tag', c.ally_tag,
             'emblem', coalesce((select al.emblem from wow_alliances al where al.tag = c.ally_tag), ''),
             'msg', c.msg, 'created', c.created, 'me', c.user_id = u.id) order by c.id), '[]') into out
    from (select * from wow_gchat
           where (coalesce(p_since,0) = 0 or created > coalesce(p_since,0))
           order by id desc limit 60) c;
  return out;
end $$;
grant execute on function public.wow_gchat(text, bigint) to anon, authenticated;


-- ================================================================
-- APENDICE MERCADO DE LOS REINOS AUTOMATICOS: venden recursos y tropas por CUP
--   (generado desde wow-botmarket.sql)
-- ================================================================
-- ================================================================
-- APENDICE MERCADO DE LOS REINOS AUTOMATICOS
--   - Los reinos automaticos VENDEN recursos y tropas por CUP, al
--     precio que fija el administrador (rango min-max por objeto).
--     NUNCA compran: no aceptan ofertas de nadie.
--   - El CUP que ganan va directo a la cuenta de Administracion y
--     se lleva un contador (wow_settings.bot_cup_earned) para el
--     panel del administrador.
--   - El administrador fija el rango de cada objeto:
--     hasta = 0 significa "eso no lo venden".
--   - _wow_bot_market: lo llama el turno global (wow_bots_tick).
--   - wow_market_take (override): si el vendedor es un reino
--     automatico, el CUP va a Administracion en vez de al bot.
-- ================================================================

create table if not exists public.wow_bot_prices(
  item text primary key,
  lo numeric(16,4) not null default 0,
  hi numeric(16,4) not null default 0
);
alter table public.wow_bot_prices enable row level security;
revoke all on table public.wow_bot_prices from public, anon, authenticated;

insert into public.wow_bot_prices(item, lo, hi) values
  ('gold',0.10,0.30), ('wood',0.05,0.15), ('ore',0.20,0.50),
  ('soldado',2,4), ('arquero',3,6), ('jinete',5,10),
  ('mago',8,16), ('paladin',12,24), ('dragon',25,50)
on conflict (item) do nothing;

insert into public.wow_settings(key, val) values ('bot_cup_earned', '0')
  on conflict (key) do nothing;

-- objetos que pueden vender (nunca cup)
create or replace function public._wow_bot_items()
returns text[] language sql immutable as $$
  select array['gold','wood','ore','soldado','arquero','jinete','mago','paladin','dragon']::text[]
$$;
revoke all on function public._wow_bot_items() from public, anon, authenticated;

-- cuenta de administracion (la primera que exista)
create or replace function public._wow_bot_bank()
returns text language sql stable security definer set search_path to 'public' as $$
  select id from wow_users where is_admin order by created, id limit 1
$$;
revoke all on function public._wow_bot_bank() from public, anon, authenticated;

-- ingresar el CUP de una venta de bot: a Administracion + contador
create or replace function public._wow_bot_bank_add(p_qty numeric, p_seller text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare tgt text;
begin
  if coalesce(p_qty,0) <= 0 then return; end if;
  tgt := _wow_bot_bank();
  if tgt is null or tgt = p_seller then tgt := p_seller; end if;
  update wow_users set cup = cup + p_qty where id = tgt;
  insert into wow_settings(key, val) values ('bot_cup_earned', p_qty::text)
    on conflict (key) do update set val = (coalesce(nullif(wow_settings.val,'')::numeric,0) + p_qty)::text;
end $$;
revoke all on function public._wow_bot_bank_add(numeric, text) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- panel del administrador: precios + lo que han ganado
-- ----------------------------------------------------------------
create or replace function public.wow_admin_bot_prices(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  return jsonb_build_object('ok', true,
    'earned', coalesce((select nullif(val,'')::numeric from wow_settings where key = 'bot_cup_earned'), 0),
    'admin_cup', coalesce((select cup from wow_users where id = _wow_bot_bank()), 0),
    'prices', coalesce((select jsonb_agg(jsonb_build_object('item', p.item, 'lo', p.lo, 'hi', p.hi)
                order by array_position(_wow_bot_items(), p.item)) from wow_bot_prices p), '[]'::jsonb),
    'offers', (select count(*) from wow_market_offers o join wow_bots b on b.user_id = o.seller
                join wow_users w on w.id = o.seller
                where o.active));
end $$;
grant execute on function public.wow_admin_bot_prices(text) to anon, authenticated;

create or replace function public.wow_admin_bot_price(p_token text, p_item text, p_lo numeric, p_hi numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; lo numeric; hi numeric;
begin
  a := _wow_admin(p_token);
  if not (coalesce(p_item,'') = any(_wow_bot_items())) then
    raise exception 'Ese objeto no se puede vender.'; end if;
  lo := greatest(0, coalesce(p_lo,0));
  hi := greatest(0, coalesce(p_hi,0));
  if hi > 0 and hi < lo then raise exception 'El precio máximo no puede ser menor que el mínimo.'; end if;
  if lo > 100000 or hi > 100000 then raise exception 'Ese precio es demasiado alto.'; end if;
  insert into wow_bot_prices(item, lo, hi) values (p_item, lo, hi)
    on conflict (item) do update set lo = excluded.lo, hi = excluded.hi;
  return jsonb_build_object('ok', true, 'item', p_item, 'lo', lo, 'hi', hi, 'on', hi > 0);
end $$;
grant execute on function public.wow_admin_bot_price(text, text, numeric, numeric) to anon, authenticated;

-- ----------------------------------------------------------------
-- el reino automatico pone una oferta de venta (si le sobra algo)
-- ----------------------------------------------------------------
create or replace function public._wow_bot_market(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  b wow_bots; it text; plo numeric; phi numeric; price numeric; stock numeric;
  sell numeric; want numeric; n integer; ms bigint; cand text[] := '{}';
begin
  select * into b from wow_bots where user_id = p_id and active;
  if b.user_id is null then return; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  select count(*) into n from wow_market_offers where seller = p_id and active;
  if n >= 2 then return; end if;                 -- como mucho 2 ofertas a la vez
  if random() > 0.35 then return; end if;        -- no lo intentan cada minuto
  foreach it in array _wow_bot_items() loop
    select p.lo, p.hi into plo, phi from wow_bot_prices p where p.item = it;
    if coalesce(phi,0) <= 0 then continue; end if; -- desactivado por el admin
    if it in ('gold','wood','ore') then
      select case it when 'gold' then gold when 'wood' then wood else ore end
        into stock from wow_users where id = p_id;
      if coalesce(stock,0) < 400 then continue; end if;   -- solo sobrantes
    else
      select qty into stock from wow_troops where owner_id = p_id and tkey = it;
      if coalesce(stock,0) < 30 then continue; end if;
    end if;
    cand := cand || it;
  end loop;
  if array_length(cand, 1) is null then return; end if;
  it := cand[1 + floor(random() * array_length(cand, 1))::int];
  select p.lo, p.hi into plo, phi from wow_bot_prices p where p.item = it;
  if it in ('gold','wood','ore') then
    select case it when 'gold' then gold when 'wood' then wood else ore end
      into stock from wow_users where id = p_id;
    sell := floor(stock * 0.25);
    if sell > 1000 then sell := 1000; end if;
  else
    select qty into stock from wow_troops where owner_id = p_id and tkey = it;
    sell := greatest(5, floor(stock * 0.10));
    if sell > 200 then sell := 200; end if;
  end if;
  if coalesce(sell,0) <= 0 then return; end if;
  price := plo + random() * (phi - plo);
  if coalesce(price,0) <= 0 then return; end if;
  want := round(sell * price, 2);
  if coalesce(want,0) <= 0 then return; end if;
  begin
    perform _wow_mkt_sub(p_id, it, sell);
  exception when others then return;
  end;
  insert into wow_market_offers(seller, seller_name, give_key, give_qty, give_left, want_key, want_qty, want_left, created, expires_ms, active)
    values (p_id, (select name from wow_users where id = p_id), it, sell, sell, 'cup', want, want, ms, ms + 86400000, true);
end $$;
revoke all on function public._wow_bot_market(text) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- turno global (igual que el interruptor + mercado de los bots)
-- ----------------------------------------------------------------
create or replace function public.wow_bots_tick(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare b record; ms bigint; n integer := 0; mx bigint;
begin
  perform _wow_resolve();
  if _wow_bot_auto() = 0 then return jsonb_build_object('ok', true, 'auto', false, 'acted', 0); end if;
  ms := (extract(epoch from now())*1000)::bigint;
  update wow_users set last_ms = ms
   where active and id in (select user_id from wow_bots where active);
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
end $$;
revoke all on function public.wow_bots_tick(boolean) from public, anon, authenticated;

-- ----------------------------------------------------------------
-- aceptar oferta (override): el CUP de un bot va a Administracion
-- y se sigue repartiendo el tributo a tronos y aldeas.
-- (Esta es la version final: se aplica despues del apendice de aldeas.)
-- ----------------------------------------------------------------
create or replace function public.wow_market_take(p_token text, p_id bigint, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; o wow_market_offers; ms bigint;
  take numeric; want_part numeric; fee numeric; net numeric; new_left numeric;
  share numeric; tt record;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select * into o from wow_market_offers where id = p_id for update;
  if o.id is null or not o.active then raise exception 'Esa oferta ya no está disponible.'; end if;
  if o.expires_ms <= ms then
    perform _wow_mkt_add(o.seller, o.give_key, o.give_left);
    update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
    raise exception 'Esa oferta ha caducado.'; end if;
  if o.seller = u.id then raise exception 'Esa oferta es tuya.'; end if;
  take := coalesce(p_qty, 0);
  if take <= 0 then raise exception 'Cantidad inválida.'; end if;
  if take >= o.give_left then
    take := o.give_left;
    want_part := o.want_left;
  else
    if _wow_mkt_is_troop(o.give_key) then take := floor(take); end if;
    if take <= 0 then raise exception 'Cantidad inválida.'; end if;
    want_part := o.want_left * (take / o.give_left);
    if _wow_mkt_is_troop(o.want_key) then
      want_part := greatest(1, round(want_part));
    else
      want_part := round(want_part, 2);
    end if;
    if want_part > o.want_left then want_part := o.want_left; end if;
    if want_part <= 0 then raise exception 'Cantidad demasiado pequeña.'; end if;
  end if;
  perform _wow_mkt_sub(u.id, o.want_key, want_part);
  perform _wow_mkt_add(u.id, o.give_key, take);
  fee := _wow_mkt_fee();
  net := want_part * (1 - fee/100.0);
  if _wow_mkt_is_troop(o.want_key) then net := round(net); end if;
  if net < 0 then net := 0; end if;
  -- el CUP de la venta de un reino automatico va a Administracion
  if o.want_key = 'cup' and exists(select 1 from wow_bots where user_id = o.seller) then
    perform _wow_bot_bank_add(net, o.seller);
  else
    perform _wow_mkt_add(o.seller, o.want_key, net);
  end if;
  -- tributo: % del valor del trato segun el tipo de cada estructura con duenio
  share := 0;
  for tt in select node from wow_thrones where holder is not null order by node loop
    share := want_part * least(_wow_node_pct(tt.node), fee) / 100.0;
    if _wow_mkt_is_troop(o.want_key) then share := round(share); end if;
    if share > 0 then perform _wow_throne_add(tt.node, o.want_key, share); end if;
  end loop;
  new_left := o.give_left - take;
  if new_left <= 0.0001 then
    update wow_market_offers set give_left = 0, want_left = 0, active = false where id = o.id;
  else
    update wow_market_offers set give_left = new_left, want_left = greatest(0, o.want_left - want_part) where id = o.id;
  end if;
  return jsonb_build_object('ok', true, 'took', take, 'paid', want_part, 'fee', fee, 'net', net, 'throne_share', share);
end $$;
grant execute on function public.wow_market_take(text, bigint, numeric) to anon, authenticated;

-- ================================================================
-- APENDICE APORTES: cada jugador solo retira las tropas que aportó
--   (generado desde wow-nodecontrib.sql)
-- ================================================================
-- ================================================================
-- Apendice: aportes de tropas por jugador en tronos y aldeas
-- (cada uno solo puede retirar lo que aporto)
-- ================================================================

create table if not exists public.wow_node_contrib(
  node integer not null,
  user_id text not null,
  troops jsonb not null default '{}'::jsonb,
  primary key (node, user_id)
);
alter table public.wow_node_contrib enable row level security;
revoke all on table public.wow_node_contrib from anon, authenticated;

create or replace function public._wow_contrib_get(p_node integer, p_uid text)
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select coalesce((select troops from wow_node_contrib where node = p_node and user_id = p_uid), '{}'::jsonb)
$$;
revoke all on function public._wow_contrib_get(integer, text) from public, anon, authenticated;

create or replace function public._wow_contrib_add(p_node integer, p_uid text, p_army jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare m jsonb;
begin
  if p_uid is null or coalesce(p_army, '{}'::jsonb) = '{}'::jsonb then return; end if;
  select coalesce(jsonb_object_agg(key, s), '{}'::jsonb) into m from (
    select key, sum(v) as s from (
      select key, value::int as v from jsonb_each_text(_wow_contrib_get(p_node, p_uid))
      union all
      select key, value::int as v from jsonb_each_text(p_army)
    ) x group by key having sum(v) > 0
  ) y;
  if m = '{}'::jsonb then
    delete from wow_node_contrib where node = p_node and user_id = p_uid;
  else
    insert into wow_node_contrib(node, user_id, troops) values (p_node, p_uid, m)
      on conflict (node, user_id) do update set troops = excluded.troops;
  end if;
end $$;
revoke all on function public._wow_contrib_add(integer, text, jsonb) from public, anon, authenticated;

create or replace function public._wow_contrib_sub(p_node integer, p_uid text, p_army jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare m jsonb;
begin
  if p_uid is null or coalesce(p_army, '{}'::jsonb) = '{}'::jsonb then return; end if;
  select coalesce(jsonb_object_agg(key, s), '{}'::jsonb) into m from (
    select key, sum(v) as s from (
      select key, value::int as v from jsonb_each_text(_wow_contrib_get(p_node, p_uid))
      union all
      select key, -(value::int) as v from jsonb_each_text(p_army)
    ) x group by key having sum(v) > 0
  ) y;
  if m = '{}'::jsonb then
    delete from wow_node_contrib where node = p_node and user_id = p_uid;
  else
    insert into wow_node_contrib(node, user_id, troops) values (p_node, p_uid, m)
      on conflict (node, user_id) do update set troops = excluded.troops;
  end if;
end $$;
revoke all on function public._wow_contrib_sub(integer, text, jsonb) from public, anon, authenticated;

create or replace function public._wow_contrib_set(p_node integer, p_uid text, p_army jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  delete from wow_node_contrib where node = p_node and user_id = p_uid;
  if p_uid is not null and coalesce(p_army, '{}'::jsonb) <> '{}'::jsonb then
    insert into wow_node_contrib(node, user_id, troops) values (p_node, p_uid, p_army);
  end if;
end $$;
revoke all on function public._wow_contrib_set(integer, text, jsonb) from public, anon, authenticated;

create or replace function public._wow_contrib_clear(p_node integer)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  delete from wow_node_contrib where node = p_node;
end $$;
revoke all on function public._wow_contrib_clear(integer) from public, anon, authenticated;

create or replace function public._wow_contrib_scale(p_node integer, p_garrison jsonb)
returns void language plpgsql security definer set search_path to 'public' as $$
declare k text; tot int; nw int; carry int; sh int; c record; big text;
begin
  for k in select key from (
      select jsonb_object_keys(troops) as key from wow_node_contrib where node = p_node
      union
      select jsonb_object_keys(coalesce(p_garrison, '{}'::jsonb)) as key
    ) u loop
    select coalesce(sum(coalesce((troops->>k)::int, 0)), 0) into tot
      from wow_node_contrib where node = p_node;
    nw := coalesce((coalesce(p_garrison, '{}'::jsonb)->>k)::int, 0);
    if tot > 0 and nw < tot then
      carry := nw;
      for c in select user_id, coalesce((troops->>k)::int, 0) as v
                 from wow_node_contrib where node = p_node
                order by coalesce((troops->>k)::int, 0) desc, user_id loop
        if c.v > 0 then
          sh := floor(c.v::numeric * nw / tot);
          if sh > carry then sh := carry; end if;
          if sh > 0 then
            update wow_node_contrib set troops = jsonb_set(troops, array[k], to_jsonb(sh), true)
             where node = p_node and user_id = c.user_id;
          else
            update wow_node_contrib set troops = troops - k
             where node = p_node and user_id = c.user_id;
          end if;
          carry := carry - sh;
        end if;
      end loop;
      if carry > 0 then
        select user_id into big from wow_node_contrib where node = p_node
          order by coalesce((troops->>k)::int, 0) desc, user_id limit 1;
        if big is not null then
          update wow_node_contrib set troops = jsonb_set(troops, array[k],
            to_jsonb(coalesce((troops->>k)::int, 0) + carry), true)
           where node = p_node and user_id = big;
        end if;
      end if;
    end if;
  end loop;
  delete from wow_node_contrib where node = p_node and troops = '{}'::jsonb;
end $$;
revoke all on function public._wow_contrib_scale(integer, jsonb) from public, anon, authenticated;

insert into wow_node_contrib(node, user_id, troops)
select node, holder, garrison from wow_thrones
 where holder is not null and coalesce(garrison, '{}'::jsonb) <> '{}'::jsonb
on conflict (node, user_id) do nothing;

create or replace function public._wow_contrib_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if new.garrison = '{}'::jsonb or new.holder is distinct from old.holder then
    delete from wow_node_contrib where node = new.node;
  end if;
  return new;
end $$;
revoke all on function public._wow_contrib_guard() from public, anon, authenticated;
drop trigger if exists wow_contrib_guard on public.wow_thrones;
create trigger wow_contrib_guard after update on public.wow_thrones
  for each row execute function public._wow_contrib_guard();

create or replace function public._wow_throne_land(p_fleet_id bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  f wow_fleets; u wow_users; t wow_thrones; ms bigint; z record; r record;
  sim jsonb; surv jsonb; msg jsonb; prev text; ret integer; ually text; lab text;
  a_forge int; a_fort int; d_forge int; d_fort int; d_wall int;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  select * into f from wow_fleets where id = p_fleet_id;
  if f.id is null then return; end if;
  select * into u from wow_users where id = f.attacker;
  if u.id is null then delete from wow_fleets where id = f.id; return; end if;
  select * into t from wow_thrones where node = f.node for update;

  -- ---- reclamar tesoro ----
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
      -- si el nodo es de una alianza, el tesoro se queda en el arcon comun
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

  -- ---- refuerzo: suma a la guarnicion; si ya no es tuyo, vuelve a casa ----
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

  -- ---- asalto: si el objetivo desaparecio, las tropas vuelven ----
  if t.node is null then
    ret := _wow_travel_node(u.pos, _wow_pos_node(u.pos));
    update wow_fleets set state = 'returning', arrive_ms = ms + ret*1000, leg_start_ms = ms where id = f.id;
    insert into wow_reports(owner, kind, data, created)
      values (u.id, 'out', jsonb_build_object('dir','throne','who','','win',false,
        'note','El objetivo ya no existe: tus tropas vuelven a casa.','created',ms), ms);
    return;
  end if;

  -- ---- libre o guarnicion vacia: se ocupa sin lucha ----
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

  -- ---- batalla contra la guarnicion (muros/herreria/fortaleza del duenio) ----
  prev := t.holder_name;
  a_forge := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'herreria'), 0);
  a_fort  := coalesce((select max(level) from wow_buildings where owner_id = u.id and bkey = 'fortaleza'), 0);
  d_forge := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'herreria'), 0);
  d_fort  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'fortaleza'), 0);
  d_wall  := coalesce((select max(level) from wow_buildings where owner_id = t.holder and bkey = 'muralla'), 0);
  sim := _wow_sim(f.troops, t.garrison, d_wall, (ms/1000) + t.node*131,
                  1 + 0.04*a_forge, 1 + 0.04*d_forge, 1 + 0.04*a_fort, 1 + 0.04*d_fort);
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
end $$;
revoke all on function public._wow_throne_land(bigint) from public, anon, authenticated;

create or replace function public.wow_throne_withdraw(p_token text, p_node integer, p_troops jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_thrones; ms bigint; army jsonb; newg jsonb; mc jsonb; z record; left_g int; travel integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  army := _wow_throne_check(p_troops);
  select * into t from wow_thrones where node = p_node for update;
  if t.node is null then raise exception 'Trono no válido.'; end if;
  if not _wow_node_mine(t.holder, t.holder_ally, u.id, u.alliance) then
    raise exception 'No controlas ese lugar.'; end if;
  mc := _wow_contrib_get(t.node, u.id);
  for z in select key, value::int from jsonb_each_text(army) loop
    if coalesce((mc->>z.key)::int, 0) < z.value then
      raise exception 'Solo puedes retirar las tropas que aportaste.'; end if;
  end loop;
  for z in select key, value::int from jsonb_each_text(army) loop
    if coalesce((t.garrison->>z.key)::int, 0) < z.value then
      raise exception 'No tienes tantas tropas de ese tipo en la guarnición.'; end if;
  end loop;
  newg := t.garrison;
  for z in select key, value::int from jsonb_each_text(army) loop
    left_g := coalesce((newg->>z.key)::int, 0) - z.value;
    if left_g > 0 then
      newg := jsonb_set(newg, array[z.key], to_jsonb(left_g), true);
    else
      newg := newg - z.key;
    end if;
  end loop;
  update wow_thrones set garrison = newg where node = t.node;
  perform _wow_contrib_sub(t.node, u.id, army);
  perform _wow_throne_log(t.node, 'withdraw', u.id, u.name, jsonb_build_object('troops', army));
  ms := (extract(epoch from now())*1000)::bigint;
  travel := _wow_travel_node(u.pos, t.node);
  insert into wow_fleets(attacker, target, node, troops, loot, state, kind, depart_ms, arrive_ms, leg_start_ms)
    values (u.id, '', t.node, army, '{}'::jsonb, 'returning', 'throne_with', ms, ms + travel*1000, ms);
  return jsonb_build_object('ok', true, 'travel', travel, 'arrive', ms + travel*1000,
                            'empty', (newg = '{}'::jsonb), 'target', t.name);
end $$;
grant execute on function public.wow_throne_withdraw(text, integer, jsonb) to anon, authenticated;

create or replace function public._wow_fort_info(p_uid text, p_kind text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare t wow_thrones; arr jsonb := '[]'::jsonb; g numeric; tr jsonb; fac text; hist jsonb;
        ua text; lab text;
begin
  ua := _wow_ally_of(p_uid);
  for t in select * from wow_thrones where kind = p_kind order by node loop
    select coalesce(sum((value)::numeric),0) into g from jsonb_each_text(t.garrison);
    select coalesce(jsonb_object_agg(key, qty), '{}'::jsonb) into tr
      from wow_throne_treasure where node = t.node and qty > 0;
    select coalesce(jsonb_agg(jsonb_build_object(
        'kind', h.kind, 'who', h.actor_name, 'who_id', h.actor,
        'detail', h.detail, 'created', h.created) order by h.id desc), '[]'::jsonb)
      into hist from (select * from wow_throne_history where node = t.node order by id desc limit 8) h;
    fac := null;
    if t.holder is not null then select faction into fac from wow_users where id = t.holder; end if;
    lab := null;
    if t.holder_ally is not null then lab := _wow_ally_label(t.holder_ally); end if;
    arr := arr || jsonb_build_object(
      'node', t.node, 'name', t.name, 'kind', t.kind,
      'holder', t.holder, 'holder_name', t.holder_name,
      'holder_ally', t.holder_ally, 'ally', lab, 'ally_icon', _wow_ally_icon(t.holder_ally),
      'faction', fac, 'mycontrib', _wow_contrib_get(t.node, p_uid), 'garrison', coalesce(g,0), 'gdetail', t.garrison, 'since', t.since_ms,
      'mine', _wow_node_mine(t.holder, t.holder_ally, p_uid, ua), 'treasure', tr, 'history', hist);
  end loop;
  return arr;
end $$;
revoke all on function public._wow_fort_info(text, text) from public, anon, authenticated;

-- ================================================================
-- Tesoro: no perder los centimos de CUP del tributo del mercado
-- ================================================================

create or replace function public._wow_node_tix(p_kind text)
returns integer language sql immutable as $$
  select case when p_kind = 'cup' then 4 else 2 end
$$;
revoke all on function public._wow_node_tix(text) from public, anon, authenticated;

do $do$
begin
  if exists(select 1 from wow_throne_treasure where key <> 'cup' and qty <> round(qty, 2)) then
    raise exception 'Abortado: hay oro/madera/mineral con mas de 2 decimales; avisar antes de seguir.';
  end if;
  if exists(select 1 from wow_throne_treasure where key = 'cup' and qty <> round(qty, 6)) then
    raise exception 'Abortado: hay CUP con mas de 6 decimales; avisar antes de seguir.';
  end if;
end $do$;

alter table public.wow_throne_treasure alter column qty type numeric(20,4);

do $do$
begin
  if exists(select 1 from wow_throne_treasure where key <> 'cup' and qty <> round(qty, 2)) then
    raise exception 'Alteracion inesperada del tesoro; rollback.';
  end if;
end $do$;

create or replace function public._wow_throne_add(p_node integer, p_key text, p_qty numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
declare q numeric;
begin
  if coalesce(p_qty,0) <= 0 then return; end if;
  q := round(p_qty, _wow_node_tix(p_key));
  if q <= 0 then return; end if;
  insert into wow_throne_treasure(node, key, qty) values (p_node, p_key, q)
    on conflict (node, key) do update set qty = wow_throne_treasure.qty + excluded.qty;
end $$;
revoke all on function public._wow_throne_add(integer, text, numeric) from public, anon, authenticated;

-- ================================================================
-- APENDICE CONFIANZA DE TIEMPO: el reino no puede ganar tiempo con el reloj del PC
--   (generado desde wow-timetrust.sql)
-- ================================================================
-- ================================================================
-- APENDICE CONFIANZA DE TIEMPO: el reino no puede ganar tiempo
-- manipulando el reloj de su ordenador.
--   - wow_register (override): created y last_ms los pone el
--     SERVIDOR (now()), nunca el cliente. Se mantiene el parametro
--     p_now por compatibilidad, pero se ignora.
--   - _wow_tick (override): recorta la produccion por refresco a
--     _wow_tick_max() horas. Si un reino lleva mucho sin entrar
--     (o alguien intenta colar tiempo), no acumula mas que ese
--     tope en una sola peticion: entra y sigue acumulando.
--   - _wow_tick_max(): tope configurable en wow_settings (por
--     defecto 3 horas).
--   - wow_admin_timeaudit: lista reinos con created/last_ms
--     sospechosos (en el futuro o desfase grande) para revisar.
--   - Saneado: last_ms/created en el futuro se corrigen a now().
-- ================================================================

-- tope de horas de produccion que se pueden acreditar en un refresco
create or replace function public._wow_tick_max()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select least(greatest(coalesce((select val::numeric from wow_settings where key = 'tick_max_h'), 3), 1), 72)
$$;
revoke all on function public._wow_tick_max() from public, anon, authenticated;

-- registro: la hora la pone el servidor (se ignora p_now)
create or replace function public.wow_register(p_name text, p_realm text, p_faction text, p_salt text, p_hash text, p_now bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare vname text; vrealm text; vkey text; vfac text;
       vpos integer; vc integer; vn integer; vs integer; ms bigint;
begin
  vname := btrim(coalesce(p_name,'')); vkey := _wow_key(vname); vrealm := btrim(coalesce(p_realm,''));
  if length(vkey) < 2 then raise exception 'Escribe un nombre de rey (así entrarás después).'; end if;
  if length(vrealm) < 2 then raise exception 'Escribe el nombre de tu reino.'; end if;
  if vname ~ '[<>&"''\\]' or vname ~ '[[:cntrl:]]' or length(vname) > 24 then
    raise exception 'El nombre de rey solo puede llevar letras, números, espacios y guiones.'; end if;
  if vrealm ~ '[<>&"''\\]' or vrealm ~ '[[:cntrl:]]' or length(vrealm) > 24 then
    raise exception 'El nombre del reino solo puede llevar letras, números, espacios y guiones.'; end if;
  vfac := lower(btrim(coalesce(p_faction,'')));
  if vfac not in ('alianza','horda') then raise exception 'Elige Alianza o Horda.'; end if;
  if coalesce(p_salt,'') = '' or coalesce(p_hash,'') = '' then raise exception 'Faltan datos de seguridad.'; end if;
  if exists(select 1 from wow_users where name_key = vkey) then
    raise exception 'Ese nombre de rey ya está en uso. Prueba con otro.'; end if;
  vc := 0; vn := -1;
  for i in 0..3 loop
    select count(*) into vs from wow_users where active and pos >= i*20 and pos < i*20 + 20;
    if vn < 0 or vs < vn then vn := vs; vc := i; end if;
  end loop;
  vpos := null;
  for i in 0..3 loop
    for j in 0..19 loop
      if not exists(select 1 from wow_users where active and pos = vc*20 + j) then
        vpos := vc*20 + j; exit;
      end if;
    end loop;
    exit when vpos is not null;
    vc := (vc + 1) % 4;
  end loop;
  if vpos is null then raise exception 'El mundo está lleno: ya hay 80 reinos.'; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  if p_now is not null and abs(p_now - ms) > 300000 then
    begin
      insert into wow_events(kind, txt, created) values ('clock', 'Reloj raro al registrar "' || vname || '": desfase ' || round((p_now - ms)/60000.0) || ' min.', ms);
    exception when others then null;
    end;
  end if;
  insert into wow_users (id, name, name_key, faction, salt, hash, active, created, last_ms, gold, wood, ore, pos, alliance)
  values (vkey, vrealm, vkey, vfac, p_salt, p_hash, true, ms, ms, 500, 500, 500, vpos, null);
  return jsonb_build_object('ok', true, 'id', vkey, 'pos', vpos);
end $$;
grant execute on function public.wow_register(text, text, text, text, text, bigint) to anon, authenticated;

-- tick: recorta la produccion por refresco al tope
create or replace function public._wow_tick(p_owner text)
returns wow_users language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ms bigint; el numeric; cap numeric; rate jsonb; q wow_queue; done integer;
begin
  select * into u from wow_users where id = p_owner for update;
  if u.id is null then return u; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  el := greatest(ms - least(u.last_ms, ms), 0)::numeric;
  el := least(el, _wow_tick_max() * 3600000);
  if exists (select 1 from wow_queue where owner_id = p_owner and kind = 'build' and finish_ms <= ms) then
    update wow_buildings set level = level + 1, finish_ms = 0
     where owner_id = p_owner and bkey = (select ref from wow_queue where owner_id = p_owner and kind = 'build');
    delete from wow_queue where owner_id = p_owner and kind = 'build';
  end if;
  select * into q from wow_queue where owner_id = p_owner and kind = 'train';
  if q is not null and q.owner_id is not null and q.unit_ms > 0 then
    done := least(q.qty, floor((ms - q.start_ms) / q.unit_ms));
    if done > 0 then
      insert into wow_troops(owner_id, tkey, qty) values (p_owner, q.ref, done)
        on conflict (owner_id, tkey) do update set qty = wow_troops.qty + excluded.qty;
      update wow_queue set qty = qty - done, start_ms = start_ms + done * unit_ms
       where owner_id = p_owner and kind = 'train';
      delete from wow_queue where owner_id = p_owner and kind = 'train' and qty <= 0;
    end if;
  end if;
  select * into q from wow_queue where owner_id = p_owner;
  rate := _wow_rate(p_owner);
  cap := _wow_cap(p_owner);
  update wow_users set
      gold = least(u.gold + el/3600000.0 * (rate->>'gold')::numeric, cap),
      wood = least(u.wood + el/3600000.0 * (rate->>'wood')::numeric, cap),
      ore  = least(u.ore  + el/3600000.0 * (rate->>'ore')::numeric, cap),
      last_ms = ms
    where id = p_owner returning * into u;
  return u;
end $$;
revoke all on function public._wow_tick(text) from public, anon, authenticated;

-- auditoria: reinos con la hora rara (para el panel de admin)
create or replace function public.wow_admin_timeaudit(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; ms bigint;
begin
  a := _wow_admin(p_token);
  ms := (extract(epoch from now())*1000)::bigint;
  return jsonb_build_object('ok', true, 'now', ms, 'top', _wow_tick_max(), 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', w.id, 'name', w.name,
      'created', w.created, 'last', w.last_ms,
      'created_off_min', round((w.created - ms)/60000.0),
      'last_off_min', round((w.last_ms - ms)/60000.0)
    ) order by abs(w.created - ms) desc)
    from wow_users w
    where w.created > ms + 300000 or w.last_ms > ms + 300000
       or w.created < ms - 365::bigint*86400000
  ), '[]'::jsonb));
end $$;
grant execute on function public.wow_admin_timeaudit(text) to anon, authenticated;

-- saneado: ninguna cuenta puede tener created/last_ms en el futuro
update wow_users set created = (extract(epoch from now())*1000)::bigint
 where created > (extract(epoch from now())*1000)::bigint + 300000;
update wow_users set last_ms = (extract(epoch from now())*1000)::bigint
 where last_ms > (extract(epoch from now())*1000)::bigint + 300000;

-- deja el tope por defecto en la configuracion (no pisa un valor ya elegido)
insert into wow_settings(key, val) values ('tick_max_h', '3')
  on conflict (key) do nothing;

-- ================================================================
-- APENDICE CONTROL DE PRODUCCION: el admin regula lo que producen los reinos
--   (generado desde wow-prod.sql)
-- ================================================================
-- ================================================================
-- APENDICE CONTROL DE PRODUCCION: el administrador puede regular
-- cuanto producen los reinos.
--   - wow_settings 'prod_mult': multiplicador GLOBAL de produccion
--     (por defecto 1). 0 = nadie produce, 0.5 = la mitad, 2 = doble.
--   - wow_users.prod_mult: multiplicador POR REINO (por defecto 1).
--   - _wow_rate (override): aplica ambos multiplicadores al ritmo de
--     oro/madera/mineral. No toca capacidad, costes ni tiempos.
--   - wow_admin_setprod: cambia el multiplicador global (0 a 10).
--   - wow_admin_setproduser: cambia el de un reino concreto (0 a 10).
--   - wow_state (override): incluye 'prod_mult' para que el cliente
--     pueda avisar de que la produccion del reino esta alterada.
--   - Todos los cambios quedan registrados en wow_events.
-- ================================================================

-- multiplicador global por defecto
insert into wow_settings(key, val) values ('prod_mult', '1') on conflict (key) do nothing;

-- multiplicador por reino
alter table wow_users add column if not exists prod_mult numeric not null default 1;

-- limite comun (0 a 10, 2 decimales)
create or replace function public._wow_prod_clamp(p numeric)
returns numeric language sql immutable as $$
  select round(least(greatest(coalesce(p,1),0),10), 2)
$$;
revoke all on function public._wow_prod_clamp(numeric) from public, anon, authenticated;

-- multiplicador global efectivo
create or replace function public._wow_prod_global()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select _wow_prod_clamp(coalesce((select val::numeric from wow_settings where key = 'prod_mult'), 1))
$$;
revoke all on function public._wow_prod_global() from public, anon, authenticated;

-- informacion publica del multiplicador global
create or replace function public.wow_prod_info()
returns jsonb language sql stable security definer set search_path to 'public' as $$
  select jsonb_build_object('mult', _wow_prod_global())
$$;
grant execute on function public.wow_prod_info() to anon, authenticated;

-- listado de reinos con su multiplicador de produccion
create or replace function public.wow_admin_list(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; out jsonb; ms bigint;
begin
  a := _wow_admin(p_token);
  perform _wow_resolve();
  ms := (extract(epoch from now())*1000)::bigint;
  select jsonb_build_object('now', ms, 'me', a.id, 'prod_mult', _wow_prod_global(), 'users', coalesce((
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
end $$;
grant execute on function public.wow_admin_list(text) to anon, authenticated;

-- ritmo de produccion con los multiplicadores aplicados
create or replace function public._wow_rate(p_owner text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare g integer; w integer; o integer; mk integer; mult numeric; pm numeric; base jsonb;
begin
  select coalesce(max(case when bkey='tesoreria' then level end),0),
         coalesce(max(case when bkey='aserradero' then level end),0),
         coalesce(max(case when bkey='mina' then level end),0),
         coalesce(max(case when bkey='mercado' then level end),0)
    into g,w,o,mk from wow_buildings where owner_id = p_owner;
  mult := 1 + 0.05 * mk;
  pm := _wow_prod_global() * _wow_prod_clamp(coalesce((select prod_mult from wow_users where id = p_owner), 1));
  return jsonb_build_object('gold', round(round((30+25*g)*mult) * pm),
                            'wood', round(round((30+25*w)*mult) * pm),
                            'ore',  round(round((30+25*o)*mult) * pm));
end $$;
revoke all on function public._wow_rate(text) from public, anon, authenticated;

-- cambiar el multiplicador GLOBAL (solo admin)
create or replace function public.wow_admin_setprod(p_token text, p_mult numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; v numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'Solo el administrador puede hacer esto.'; end if;
  v := _wow_prod_clamp(p_mult);
  insert into wow_settings(key, val) values ('prod_mult', v::text)
    on conflict (key) do update set val = excluded.val;
  insert into wow_events(kind, txt, created)
    values ('prod', 'Producción global puesta en x'||v||' por '||u.name, (extract(epoch from now())*1000)::bigint);
  return jsonb_build_object('ok', true, 'prod_mult', v);
end $$;
revoke all on function public.wow_admin_setprod(text, numeric) from public, anon, authenticated;

-- cambiar el multiplicador de UN REINO (solo admin)
create or replace function public.wow_admin_setproduser(p_token text, p_id text, p_mult numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; t wow_users; v numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if not u.is_admin then raise exception 'Solo el administrador puede hacer esto.'; end if;
  select * into t from wow_users where id = p_id;
  if t.id is null then raise exception 'Ese reino no existe.'; end if;
  v := _wow_prod_clamp(p_mult);
  update wow_users set prod_mult = v where id = t.id;
  insert into wow_events(kind, txt, created)
    values ('prod', 'Producción de '||t.name||' puesta en x'||v||' por '||u.name, (extract(epoch from now())*1000)::bigint);
  return jsonb_build_object('ok', true, 'id', t.id, 'prod_mult', v);
end $$;
revoke all on function public.wow_admin_setproduser(text, text, numeric) from public, anon, authenticated;

-- estado: avisa del multiplicador del reino (global x suyo)
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
             'atk', _wow_atk(v.t), 'hp', _wow_hp(v.t), 'req', _wow_treq(v.t)) order by v.ord), '[]') into trs
    from (values ('soldado',1),('arquero',2),('jinete',3),('mago',4),('paladin',5),('dragon',6)) v(t,ord)
    left join wow_troops t on t.owner_id = u.id and t.tkey = v.t;
  select coalesce(jsonb_agg(jsonb_build_object('kind', q.kind, 'ref', q.ref, 'qty', q.qty, 'unit_ms', q.unit_ms,
           'start', q.start_ms, 'finish', q.finish_ms) order by q.kind), '[]') into que
    from wow_queue q where q.owner_id = u.id;
  pts := (select coalesce(sum(level),0) from wow_buildings where owner_id = u.id) * 100
       + (select coalesce(sum(qty),0) from wow_troops where owner_id = u.id);
  return jsonb_build_object('id', u.id, 'name', u.name, 'faction', u.faction, 'is_admin', u.is_admin,
    'gold', u.gold, 'wood', u.wood, 'ore', u.ore, 'cup', coalesce(u.cup,0), 'capacity', cap, 'rate', rate,
    'prod_mult', (_wow_prod_global() * _wow_prod_clamp(u.prod_mult)),
    'buildings', blds, 'troops', trs, 'queue', que->0, 'queues', que, 'points', pts, 'now', ms,
    'alliance', u.alliance,
    'ally_tag', coalesce((select tag from wow_alliances where id = u.alliance), ''),
    'ally_emblem', _wow_ally_icon(u.alliance),
    'online', _wow_online_count());
end $$;
revoke all on function public.wow_state(text) from public, anon, authenticated;
