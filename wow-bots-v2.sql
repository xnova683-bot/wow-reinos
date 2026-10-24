-- ================================================================
-- BOTS v2 - FASE 1
--   Personalidad por bot + utilidades de evaluacion (fuerza,
--   simulacion con niebla, deteccion de otros bots, registro).
--   Nada de esto se expone al cliente: RLS + revoke.
-- ================================================================

alter table public.wow_bots
  add column if not exists caution        int  not null default 50,
  add column if not exists teamwork       int  not null default 50,
  add column if not exists spy_rate       int  not null default 25,
  add column if not exists defense_aware  int  not null default 50,
  add column if not exists risk_tolerance int  not null default 50,
  add column if not exists activity       int  not null default 50,
  add column if not exists behavior       text not null default 'balanced',
  add column if not exists scout_ms       bigint not null default 0;

alter table public.wow_bots drop constraint if exists wow_bots_ranges;
alter table public.wow_bots add constraint wow_bots_ranges check (
  caution between 0 and 100 and teamwork between 0 and 100 and
  spy_rate between 0 and 100 and defense_aware between 0 and 100 and
  risk_tolerance between 0 and 100 and activity between 0 and 100
);

-- registro privado de decisiones (solo admin, para depurar)
create table if not exists public.wow_bot_log (
  id bigserial primary key,
  bot text not null,
  kind text not null,
  detail jsonb not null default '{}'::jsonb,
  created bigint not null
);
alter table public.wow_bot_log enable row level security;
revoke all on public.wow_bot_log from public, anon, authenticated;
revoke all on sequence public.wow_bot_log_id_seq from public, anon, authenticated;

create or replace function public._wow_bot_log(p_id text, p_kind text, p_detail jsonb default '{}'::jsonb)
returns void language sql security definer set search_path to 'public' as $$
  insert into public.wow_bot_log(bot, kind, detail, created)
  values (p_id, p_kind, coalesce(p_detail,'{}'::jsonb), (extract(epoch from now())*1000)::bigint)
$$;
revoke all on function public._wow_bot_log(text, text, jsonb) from public, anon, authenticated;

-- ================================================================
-- presets de personalidad
-- ================================================================
create or replace function public._wow_bot_preset(p_name text)
returns jsonb language sql immutable as $$
  select case coalesce(p_name,'balanced')
    when 'aggressive' then '{"caution":25,"teamwork":40,"spy_rate":15,"defense_aware":35,"risk_tolerance":80,"activity":75,"behavior":"aggressive"}'::jsonb
    when 'turtle'     then '{"caution":80,"teamwork":35,"spy_rate":50,"defense_aware":90,"risk_tolerance":20,"activity":35,"behavior":"turtle"}'::jsonb
    when 'teamplayer' then '{"caution":55,"teamwork":90,"spy_rate":45,"defense_aware":65,"risk_tolerance":50,"activity":55,"behavior":"teamplayer"}'::jsonb
    when 'opportunist'then '{"caution":60,"teamwork":30,"spy_rate":70,"defense_aware":75,"risk_tolerance":45,"activity":65,"behavior":"opportunist"}'::jsonb
    else                   '{"caution":50,"teamwork":50,"spy_rate":25,"defense_aware":50,"risk_tolerance":50,"activity":50,"behavior":"balanced"}'::jsonb
  end
$$;
revoke all on function public._wow_bot_preset(text) from public, anon, authenticated;

create or replace function public._wow_bot_apply_preset(p_id text, p_preset text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c jsonb := _wow_bot_preset(p_preset);
begin
  update wow_bots set
    caution        = coalesce((c->>'caution')::int, caution),
    teamwork       = coalesce((c->>'teamwork')::int, teamwork),
    spy_rate       = coalesce((c->>'spy_rate')::int, spy_rate),
    defense_aware  = coalesce((c->>'defense_aware')::int, defense_aware),
    risk_tolerance = coalesce((c->>'risk_tolerance')::int, risk_tolerance),
    activity       = coalesce((c->>'activity')::int, activity),
    behavior       = coalesce(c->>'behavior', behavior)
  where user_id = p_id;
end $$;
revoke all on function public._wow_bot_apply_preset(text, text) from public, anon, authenticated;

-- ================================================================
-- deteccion y fuerza
-- ================================================================
create or replace function public._wow_bot_is_bot(p_id text)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select exists(select 1 from public.wow_bots where user_id = p_id)
$$;
revoke all on function public._wow_bot_is_bot(text) from public, anon, authenticated;

create or replace function public._wow_bot_power(p_troops jsonb)
returns numeric language plpgsql immutable as $$
declare
  keys text[] := array['soldado','arquero','jinete','mago','paladin','dragon'];
  hps  numeric[] := array[12,8,16,7,26,34];
  atks numeric[] := array[10,15,20,26,24,44];
  i int; tot numeric := 0; q numeric;
begin
  for i in 1..6 loop
    q := coalesce((p_troops->>keys[i])::numeric, 0);
    if q > 0 then tot := tot + q * (hps[i] + atks[i] * 1.2); end if;
  end loop;
  return round(tot, 2);
end $$;
revoke all on function public._wow_bot_power(jsonb) from public, anon, authenticated;

-- fuerza completa de un reino: tropas + defensas + rey
create or replace function public._wow_bot_forces(p_id text)
returns jsonb language plpgsql stable security definer set search_path to 'public' as $$
declare tr jsonb := '{}'::jsonb; z record;
        w int := 0; fg int := 0; ft int := 0; kp numeric := 0; kn int := 0;
begin
  for z in select tkey, qty from wow_troops where owner_id = p_id and qty > 0 loop
    tr := tr || jsonb_build_object(z.tkey, z.qty);
  end loop;
  select coalesce(max(level) filter (where bkey = 'muralla'), 0),
         coalesce(max(level) filter (where bkey = 'herreria'), 0),
         coalesce(max(level) filter (where bkey = 'fortaleza'), 0)
    into w, fg, ft
    from wow_buildings where owner_id = p_id;
  select level, coalesce(atk * 1.2 + hp, 0) into kn, kp
    from wow_kings where owner_id = p_id;
  return jsonb_build_object(
    'troops', tr,
    'wall', w, 'forge', fg, 'fort', ft,
    'king_level', kn,
    'power', _wow_bot_power(tr) + coalesce(kp, 0),
    'points', _wow_points(p_id)
  );
end $$;
revoke all on function public._wow_bot_forces(text) from public, anon, authenticated;

-- fuerza combinada de una alianza (jugadores + bots no pausados)
create or replace function public._wow_bot_ally_strength(p_ally text)
returns numeric language plpgsql stable security definer set search_path to 'public' as $$
declare tot numeric := 0; r record;
begin
  if p_ally is null then return 0; end if;
  for r in select u.id from wow_users u
             join wow_bots b on b.user_id = u.id and b.active
            where u.alliance = p_ally loop
    tot := tot + coalesce((_wow_bot_forces(r.id)->>'power')::numeric, 0);
  end loop;
  return tot;
end $$;
revoke all on function public._wow_bot_ally_strength(text) from public, anon, authenticated;

-- ================================================================
-- evaluacion de batallas con niebla (informacion imperfecta)
-- ================================================================
-- p_fog: 0 = informacion perfecta, 0.15 = +-15% de error sobre el enemigo
create or replace function public._wow_bot_sim_kingdom(
  p_id text, p_target text, p_army jsonb,
  p_send_king boolean default false, p_fog numeric default 0.10)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  own jsonb; tgt jsonb; def jsonb; att jsonb; sim jsonb;
  i int; keys text[] := array['soldado','arquero','jinete','mago','paladin','dragon'];
  scale numeric; q numeric; a_start numeric := 0; a_left numeric := 0; loss numeric := 0;
  seed bigint;
begin
  own := _wow_bot_forces(p_id);
  tgt := _wow_bot_forces(p_target);
  if tgt is null or tgt = '{}'::jsonb then return jsonb_build_object('ok', false); end if;
  att := coalesce(p_army, '{}'::jsonb) - '_king';
  def := '{}'::jsonb;
  scale := greatest(0, 1 + ((random()*2 - 1) * greatest(coalesce(p_fog,0),0)));
  for i in 1..6 loop
    q := coalesce((tgt->'troops'->>keys[i])::numeric, 0) * scale;
    if q > 0 then def := def || jsonb_build_object(keys[i], q); end if;
  end loop;
  for i in 1..6 loop a_start := a_start + coalesce((att->>keys[i])::numeric, 0); end loop;
  seed := (extract(epoch from now())*1000)::bigint;
  sim := _wow_sim(att, def, coalesce((tgt->>'wall')::int, 0), seed,
                  1 + 0.04 * coalesce((own->>'forge')::numeric, 0),
                  1 + 0.04 * coalesce((tgt->>'forge')::numeric, 0),
                  1 + 0.04 * coalesce((own->>'fort')::numeric, 0),
                  1 + 0.04 * coalesce((tgt->>'fort')::numeric, 0),
                  case when p_send_king then p_id else null end,
                  p_target);
  for i in 1..6 loop a_left := a_left + coalesce((sim->'a_left'->>keys[i])::numeric, 0); end loop;
  if a_start > 0 then loss := greatest(0, 1 - (a_left / a_start)); end if;
  return jsonb_build_object(
    'ok', true,
    'win', (sim->>'winner') = 'attacker',
    'loss_pct', round(loss * 100)::int,
    'atk_power', _wow_bot_power(att),
    'def_power', _wow_bot_power(def),
    'att_left', sim->'a_left',
    'def_left', sim->'d_left',
    'rounds', coalesce(jsonb_array_length(sim->'rounds'), 0)
  );
end $$;
revoke all on function public._wow_bot_sim_kingdom(text, text, jsonb, boolean, numeric) from public, anon, authenticated;

create or replace function public._wow_bot_sim_node(
  p_id text, p_node integer, p_army jsonb, p_fog numeric default 0.10)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  own jsonb; t jsonb; trow wow_thrones; def jsonb; att jsonb := coalesce(p_army,'{}'::jsonb) - '_king';
  sim jsonb; i int; keys text[] := array['soldado','arquero','jinete','mago','paladin','dragon'];
  scale numeric; q numeric; a_start numeric := 0; a_left numeric := 0; loss numeric := 0;
  seed bigint; dfor int := 0; dfort int := 0; dwall int := 0;
begin
  select * into trow from wow_thrones where node = p_node;
  if trow.node is null then return jsonb_build_object('ok', false); end if;
  if trow.holder is not null then
    own := _wow_bot_forces(p_id);
    select coalesce(max(level) filter (where bkey='herreria'),0),
           coalesce(max(level) filter (where bkey='fortaleza'),0),
           coalesce(max(level) filter (where bkey='muralla'),0)
      into dfor, dfort, dwall from wow_buildings where owner_id = trow.holder;
  end if;
  def := '{}'::jsonb;
  scale := greatest(0, 1 + ((random()*2 - 1) * greatest(coalesce(p_fog,0),0)));
  for i in 1..6 loop
    q := coalesce((trow.garrison->>keys[i])::numeric, 0) * scale;
    if q > 0 then def := def || jsonb_build_object(keys[i], q); end if;
  end loop;
  for i in 1..6 loop a_start := a_start + coalesce((att->>keys[i])::numeric, 0); end loop;
  seed := (extract(epoch from now())*1000)::bigint + p_node * 131;
  sim := _wow_sim(att, def, dwall, seed,
                  1 + 0.04 * coalesce((own->>'forge')::numeric,0),
                  1 + 0.04 * dfor,
                  1 + 0.04 * coalesce((own->>'fort')::numeric,0),
                  1 + 0.04 * dfort,
                  _wow_madam_bonus(p_id),
                  case when trow.holder is not null then _wow_madam_bonus(trow.holder) else 0 end,
                  null, null, 0, 0);
  for i in 1..6 loop a_left := a_left + coalesce((sim->'a_left'->>keys[i])::numeric, 0); end loop;
  if a_start > 0 then loss := greatest(0, 1 - (a_left / a_start)); end if;
  return jsonb_build_object(
    'ok', true,
    'win', (sim->>'winner') = 'attacker',
    'loss_pct', round(loss * 100)::int,
    'atk_power', _wow_bot_power(att),
    'def_power', _wow_bot_power(def),
    'att_left', sim->'a_left',
    'def_left', sim->'d_left',
    'rounds', coalesce(jsonb_array_length(sim->'rounds'), 0),
    'kind', trow.kind, 'name', trow.name, 'holder', trow.holder, 'holder_ally', trow.holder_ally
  );
end $$;
revoke all on function public._wow_bot_sim_node(text, integer, jsonb, numeric) from public, anon, authenticated;

-- umbral de bajas aceptables segun cautela y tolerancia al riesgo
create or replace function public._wow_bot_loss_ok(p_id text, p_loss_pct int)
returns boolean language sql stable security definer set search_path to 'public' as $$
  select coalesce(p_loss_pct, 100) <= greatest(5, least(70,
    40 - 0.4 * (coalesce((select caution from wow_bots where user_id = p_id), 50) - 50)
       + 0.3 * (coalesce((select risk_tolerance from wow_bots where user_id = p_id), 50) - 50)))
$$;
revoke all on function public._wow_bot_loss_ok(text, int) from public, anon, authenticated;
