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
