-- ================================================================
-- RULETA EL DORADO (taberna -> beber -> apostar)
--   Ruleta global para todos los reinos. Entrada de 10 CUP y
--   rondas de 10 minutos (configurable por el admin).
--   Reparto: 90% al ganador, 5% a la administracion y 5% entre
--   tronos y aldeas (igual que los contratos de la Madam).
--   El cierre de ronda lo hace pg_cron cada minuto y ademas se
--   resuelve al consultar el estado (settle perezoso).
-- ================================================================

insert into wow_settings(key,val) values
  ('rlt_cost','10'),
  ('rlt_minutes','10'),
  ('rlt_pct_winner','90'),
  ('rlt_pct_admin','5'),
  ('rlt_pct_shared','5'),
  ('rlt_enabled','1'),
  ('rlt_rounds','0'),
  ('rlt_earned','0'),
  ('rlt_paid','0'),
  ('rlt_admin_earned','0'),
  ('rlt_shared_earned','0')
on conflict (key) do nothing;

create table if not exists public.wow_roulette(
  id integer primary key default 1 check (id = 1),
  start_ms bigint not null default 0,
  ends_ms bigint not null default 0,
  participants jsonb not null default '[]'::jsonb,
  finished boolean not null default true,
  winner_id text,
  winner_name text,
  winner_index integer not null default -1,
  pot numeric(16,2) not null default 0,
  prize numeric(16,2) not null default 0,
  admin_cut numeric(16,2) not null default 0,
  shared_cut numeric(16,2) not null default 0,
  cost numeric(16,2) not null default 10,
  pct_winner numeric(6,2) not null default 90,
  pct_admin numeric(6,2) not null default 5,
  pct_shared numeric(6,2) not null default 5,
  finished_at bigint not null default 0
);
alter table public.wow_roulette enable row level security;
revoke all on table public.wow_roulette from public, anon, authenticated;

create table if not exists public.wow_roulette_wins(
  id bigserial primary key,
  winner_id text,
  winner_name text,
  players integer not null default 0,
  pot numeric(16,2) not null default 0,
  prize numeric(16,2) not null default 0,
  admin_cut numeric(16,2) not null default 0,
  shared_cut numeric(16,2) not null default 0,
  created_ms bigint not null default 0
);
alter table public.wow_roulette_wins enable row level security;
revoke all on table public.wow_roulette_wins from public, anon, authenticated;

create or replace function public._wow_rlt_cost()
returns numeric language sql stable set search_path to 'public' as $$
  select greatest(1, least(10000, coalesce((select val::numeric from wow_settings where key='rlt_cost'), 10)));
$$;
revoke all on function public._wow_rlt_cost() from public, anon, authenticated;

create or replace function public._wow_rlt_minutes()
returns numeric language sql stable set search_path to 'public' as $$
  select greatest(1, least(1440, coalesce((select val::numeric from wow_settings where key='rlt_minutes'), 10)));
$$;
revoke all on function public._wow_rlt_minutes() from public, anon, authenticated;

create or replace function public._wow_rlt_pct(p_which text)
returns numeric language sql stable set search_path to 'public' as $$
  select greatest(0, least(100, coalesce((select val::numeric from wow_settings where key = 'rlt_pct_' || p_which),
    case p_which when 'winner' then 90 when 'admin' then 5 when 'shared' then 5 else 0 end)));
$$;
revoke all on function public._wow_rlt_pct(text) from public, anon, authenticated;

create or replace function public._wow_rlt_enabled()
returns boolean language sql stable set search_path to 'public' as $$
  select coalesce((select val::numeric from wow_settings where key='rlt_enabled'), 1) > 0;
$$;
revoke all on function public._wow_rlt_enabled() from public, anon, authenticated;

create or replace function public._wow_rlt_add(p_key text, p_amt numeric)
returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if coalesce(p_amt,0) = 0 then return; end if;
  insert into wow_settings(key,val) values (p_key, p_amt::text)
    on conflict (key) do update set val = (coalesce(wow_settings.val::numeric,0) + p_amt)::text;
end $$;
revoke all on function public._wow_rlt_add(text, numeric) from public, anon, authenticated;

-- abre una ronda nueva con el coste y los porcentajes vigentes
create or replace function public._wow_rlt_open(p_now bigint)
returns void language plpgsql security definer set search_path to 'public' as $$
declare c numeric; m numeric;
begin
  c := _wow_rlt_cost();
  m := _wow_rlt_minutes();
  insert into wow_roulette as r(
    id, start_ms, ends_ms, participants, finished, winner_id, winner_name, winner_index,
    pot, prize, admin_cut, shared_cut, cost, pct_winner, pct_admin, pct_shared, finished_at)
  values (1, p_now, p_now + (m * 60000)::bigint, '[]'::jsonb, false, null, null, -1,
    0, 0, 0, 0, c, _wow_rlt_pct('winner'), _wow_rlt_pct('admin'), _wow_rlt_pct('shared'), 0)
  on conflict (id) do update set
    start_ms = excluded.start_ms, ends_ms = excluded.ends_ms, participants = '[]'::jsonb,
    finished = false, winner_id = null, winner_name = null, winner_index = -1,
    pot = 0, prize = 0, admin_cut = 0, shared_cut = 0, cost = excluded.cost,
    pct_winner = excluded.pct_winner, pct_admin = excluded.pct_admin,
    pct_shared = excluded.pct_shared, finished_at = 0;
end $$;
revoke all on function public._wow_rlt_open(bigint) from public, anon, authenticated;

-- cierra la ronda vencida y paga
create or replace function public._wow_rlt_settle()
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare r wow_roulette; ps jsonb; n integer; wi integer; w jsonb;
        total numeric; pz numeric; ac numeric; sh numeric; rep numeric; ms bigint;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  select * into r from wow_roulette where id = 1 for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'sin_ronda'); end if;
  if r.finished then return jsonb_build_object('ok', false, 'reason', 'terminada'); end if;
  if ms < r.ends_ms then return jsonb_build_object('ok', false, 'reason', 'abierta'); end if;
  ps := coalesce(r.participants, '[]'::jsonb);
  n := jsonb_array_length(ps);
  perform public._wow_rlt_add('rlt_rounds', 1);
  if n = 0 then
    update wow_roulette set finished = true, winner_id = null, winner_name = null,
      winner_index = -1, pot = 0, prize = 0, admin_cut = 0, shared_cut = 0, finished_at = ms
      where id = 1;
    return jsonb_build_object('ok', true, 'players', 0, 'winner_index', -1, 'prize', 0);
  end if;
  wi := floor(random() * n)::int;
  w := ps->wi;
  total := round(n * r.cost, 2);
  pz := round(total * r.pct_winner / 100.0, 2);
  ac := round(total * r.pct_admin / 100.0, 2);
  sh := greatest(0, total - pz - ac);
  if pz > 0 then
    update wow_users set cup = coalesce(cup,0) + pz where id = w->>'id';
  end if;
  if ac > 0 then
    update wow_users set cup = coalesce(cup,0) + ac where is_admin = true;
  end if;
  rep := 0;
  if sh > 0 then rep := _wow_tavern_distribute(sh, 'cup'); end if;
  insert into wow_roulette_wins(winner_id, winner_name, players, pot, prize, admin_cut, shared_cut, created_ms)
    values (w->>'id', w->>'name', n, total, pz, ac, coalesce(rep,0), ms);
  perform public._wow_rlt_add('rlt_earned', total);
  perform public._wow_rlt_add('rlt_paid', pz);
  perform public._wow_rlt_add('rlt_admin_earned', ac);
  perform public._wow_rlt_add('rlt_shared_earned', coalesce(rep,0));
  update wow_roulette set finished = true, winner_id = w->>'id', winner_name = w->>'name',
    winner_index = wi, pot = total, prize = pz, admin_cut = ac, shared_cut = coalesce(rep,0),
    finished_at = ms
    where id = 1;
  return jsonb_build_object('ok', true, 'players', n, 'winner_id', w->>'id',
    'winner_name', w->>'name', 'winner_index', wi, 'pot', total, 'prize', pz,
    'admin_cut', ac, 'shared', coalesce(rep,0));
end $$;
revoke all on function public._wow_rlt_settle() from public, anon, authenticated;

-- tic: resuelve la ronda vencida y abre otra si toca
create or replace function public._wow_rlt_tick()
returns void language plpgsql security definer set search_path to 'public' as $$
declare r wow_roulette; ms bigint;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  select * into r from wow_roulette where id = 1 for update;
  if not found then
    if _wow_rlt_enabled() then perform _wow_rlt_open(ms); end if;
    return;
  end if;
  if not r.finished and ms >= r.ends_ms then
    perform _wow_rlt_settle();
    select * into r from wow_roulette where id = 1;
  end if;
  if r.finished and _wow_rlt_enabled() and coalesce(r.finished_at,0) > 0
     and ms - r.finished_at >= 15000 then
    perform _wow_rlt_open(ms);
  end if;
end $$;
revoke all on function public._wow_rlt_tick() from public, anon, authenticated;

create or replace function public.wow_roulette_state(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; r wow_roulette; ms bigint; ps jsonb; n integer; joined boolean; recent jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  perform _wow_rlt_tick();
  select * into r from wow_roulette where id = 1;
  if not found then
    return jsonb_build_object('ok', true, 'enabled', _wow_rlt_enabled(), 'now', ms,
      'finished', true, 'participants', '[]'::jsonb, 'count', 0, 'cost', _wow_rlt_cost(),
      'pot', 0, 'prize_est', 0, 'ms_left', 0, 'next_in', 0,
      'pct_winner', _wow_rlt_pct('winner'), 'pct_admin', _wow_rlt_pct('admin'),
      'pct_shared', _wow_rlt_pct('shared'), 'cup', coalesce(u.cup,0), 'joined', false,
      'recent', '[]'::jsonb);
  end if;
  ps := coalesce(r.participants, '[]'::jsonb);
  n := jsonb_array_length(ps);
  joined := exists (select 1 from jsonb_array_elements(ps) e where e->>'id' = u.id);
  select coalesce(jsonb_agg(jsonb_build_object('name', t.winner_name, 'prize', t.prize,
           'players', t.players, 'created', t.created_ms) order by t.id desc), '[]'::jsonb)
    into recent
    from (select id, winner_name, prize, players, created_ms
            from wow_roulette_wins where winner_name is not null
           order by id desc limit 5) t;
  return jsonb_build_object('ok', true,
    'enabled', _wow_rlt_enabled(), 'now', ms,
    'finished', r.finished,
    'start', r.start_ms, 'ends', r.ends_ms,
    'ms_left', greatest(0, r.ends_ms - ms),
    'next_in', case when r.finished then greatest(0, 15000 - (ms - coalesce(r.finished_at,0))) else 0 end,
    'participants', ps, 'count', n,
    'cost', r.cost, 'pot', round(n * r.cost, 2),
    'prize_est', round(n * r.cost * r.pct_winner / 100.0, 2),
    'pct_winner', r.pct_winner, 'pct_admin', r.pct_admin, 'pct_shared', r.pct_shared,
    'winner_id', r.winner_id, 'winner_name', r.winner_name,
    'winner_index', r.winner_index, 'prize', r.prize,
    'admin_cut', r.admin_cut, 'shared_cut', r.shared_cut, 'finished_at', r.finished_at,
    'cup', coalesce(u.cup,0), 'joined', joined, 'recent', recent);
end $$;
revoke all on function public.wow_roulette_state(text) from public;
grant execute on function public.wow_roulette_state(text) to anon, authenticated;

create or replace function public.wow_roulette_join(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; r wow_roulette; ms bigint; ps jsonb; n integer; c numeric;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'La cuenta de administración no puede participar.'; end if;
  if not _wow_rlt_enabled() then raise exception 'La ruleta está cerrada por el momento.'; end if;
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  perform _wow_rlt_tick();
  select * into r from wow_roulette where id = 1 for update;
  if not found then raise exception 'La ronda se está cargando. Intenta de nuevo.'; end if;
  if r.finished or ms >= r.ends_ms then
    raise exception 'La ronda está terminando. Espera a la siguiente.';
  end if;
  ps := coalesce(r.participants, '[]'::jsonb);
  if exists (select 1 from jsonb_array_elements(ps) e where e->>'id' = u.id) then
    raise exception 'Ya estás participando en esta ronda.';
  end if;
  c := r.cost;
  if coalesce(u.cup,0) < c then
    raise exception 'Necesitas % CUP para participar.', c::float8;
  end if;
  update wow_users set cup = cup - c where id = u.id;
  ps := ps || jsonb_build_array(jsonb_build_object('id', u.id, 'name', u.name));
  update wow_roulette set participants = ps where id = 1;
  n := jsonb_array_length(ps);
  return jsonb_build_object('ok', true, 'cost', c, 'count', n,
    'pot', round(n * c, 2), 'ends', r.ends_ms,
    'cup', (select cup from wow_users where id = u.id), 'joined', true);
end $$;
revoke all on function public.wow_roulette_join(text) from public;
grant execute on function public.wow_roulette_join(text) to anon, authenticated;

create or replace function public.wow_admin_setroulette(p_token text, p_cost numeric, p_minutes numeric,
  p_pct_winner numeric, p_pct_admin numeric, p_pct_shared numeric, p_enabled numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if not (p_cost >= 1 and p_cost <= 10000) then raise exception 'La entrada debe estar entre 1 y 10.000 CUP.'; end if;
  if not (p_minutes >= 1 and p_minutes <= 1440) then raise exception 'La duración debe estar entre 1 y 1.440 minutos.'; end if;
  if not (p_pct_winner >= 0 and p_pct_winner <= 100) then raise exception 'El porcentaje del ganador debe estar entre 0 y 100.'; end if;
  if not (p_pct_admin >= 0 and p_pct_admin <= 100) then raise exception 'El porcentaje del admin debe estar entre 0 y 100.'; end if;
  if not (p_pct_shared >= 0 and p_pct_shared <= 100) then raise exception 'El porcentaje de tronos y aldeas debe estar entre 0 y 100.'; end if;
  if abs((p_pct_winner + p_pct_admin + p_pct_shared) - 100) > 0.01 then
    raise exception 'Los porcentajes del ganador, admin y tronos/aldeas deben sumar 100.';
  end if;
  if p_enabled not in (0,1) then raise exception 'El estado debe ser 0 o 1.'; end if;
  insert into wow_settings(key,val) values ('rlt_cost', p_cost::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('rlt_minutes', p_minutes::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('rlt_pct_winner', p_pct_winner::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('rlt_pct_admin', p_pct_admin::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('rlt_pct_shared', p_pct_shared::text) on conflict (key) do update set val = excluded.val;
  insert into wow_settings(key,val) values ('rlt_enabled', p_enabled::text) on conflict (key) do update set val = excluded.val;
  return jsonb_build_object('ok', true, 'cost', _wow_rlt_cost(), 'minutes', _wow_rlt_minutes(),
    'pct_winner', _wow_rlt_pct('winner'), 'pct_admin', _wow_rlt_pct('admin'),
    'pct_shared', _wow_rlt_pct('shared'), 'enabled', _wow_rlt_enabled());
end $$;
revoke all on function public.wow_admin_setroulette(text, numeric, numeric, numeric, numeric, numeric, numeric) from public;
grant execute on function public.wow_admin_setroulette(text, numeric, numeric, numeric, numeric, numeric, numeric) to anon, authenticated;

create or replace function public.wow_admin_roulette_stats(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; r wow_roulette;
begin
  a := _wow_admin(p_token);
  select * into r from wow_roulette where id = 1;
  return jsonb_build_object('ok', true,
    'cost', _wow_rlt_cost(), 'minutes', _wow_rlt_minutes(),
    'pct_winner', _wow_rlt_pct('winner'), 'pct_admin', _wow_rlt_pct('admin'),
    'pct_shared', _wow_rlt_pct('shared'), 'enabled', _wow_rlt_enabled(),
    'rounds', coalesce((select val::numeric from wow_settings where key='rlt_rounds'),0),
    'earned', coalesce((select val::numeric from wow_settings where key='rlt_earned'),0),
    'paid', coalesce((select val::numeric from wow_settings where key='rlt_paid'),0),
    'admin_earned', coalesce((select val::numeric from wow_settings where key='rlt_admin_earned'),0),
    'shared_earned', coalesce((select val::numeric from wow_settings where key='rlt_shared_earned'),0),
    'round', case when r.id is null then null else jsonb_build_object(
      'finished', r.finished, 'ends', r.ends_ms, 'start', r.start_ms,
      'participants', coalesce(r.participants,'[]'::jsonb),
      'count', jsonb_array_length(coalesce(r.participants,'[]'::jsonb)),
      'pot', round(jsonb_array_length(coalesce(r.participants,'[]'::jsonb)) * r.cost, 2),
      'winner_name', r.winner_name, 'prize', r.prize, 'finished_at', r.finished_at) end,
    'recent', coalesce((select jsonb_agg(jsonb_build_object('name', t.winner_name, 'prize', t.prize,
        'players', t.players, 'created', t.created_ms) order by t.id desc)
      from (select id, winner_name, prize, players, created_ms from wow_roulette_wins
             order by id desc limit 10) t), '[]'::jsonb));
end $$;
revoke all on function public.wow_admin_roulette_stats(text) from public;
grant execute on function public.wow_admin_roulette_stats(text) to anon, authenticated;

-- cierre automatico cada minuto (ademas del settle perezoso al consultar)
do $do$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    begin
      perform cron.unschedule('wow_roulette');
    exception when others then null;
    end;
    perform cron.schedule('wow_roulette', '* * * * *', 'select public._wow_rlt_tick();');
  end if;
end $do$;
