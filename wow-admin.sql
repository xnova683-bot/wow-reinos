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

-- borrar cuenta (cascade limpia todo)
create or replace function public.wow_admin_delete(p_token text, p_id text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if p_id = a.id then raise exception 'No puedes borrar tu propia cuenta de administrador.'; end if;
  if not exists(select 1 from wow_users where id = p_id) then raise exception 'Ese reino ya no existe.'; end if;
  delete from wow_users where id = p_id;
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
declare u wow_users; t wow_users; ms bigint; e record; v integer; travel integer; sent jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  if p_target = u.id then raise exception 'No puedes atacarte a ti mismo.'; end if;
  select * into t from wow_users where id = p_target and active;
  if t.id is null then raise exception 'Ese reino ya no existe.'; end if;
  if t.is_admin then raise exception 'No puedes atacar a un administrador.'; end if;
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
