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
