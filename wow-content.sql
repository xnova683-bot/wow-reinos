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
  if exists(select 1 from wow_queue where owner_id = u.id) then
    raise exception 'Ya tienes algo en construcción.'; end if;
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
  if exists(select 1 from wow_queue where owner_id = u.id) then
    raise exception 'Ya estás entrenando o construyendo algo.'; end if;
  if coalesce(p_key,'') not in ('soldado','arquero','jinete','mago','paladin','dragon') then
    raise exception 'Tropa no válida.'; end if;
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
