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
create or replace function public.wow_admin_grant(p_token text, p_id text, p_gold numeric, p_wood numeric, p_ore numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users;
begin
  a := _wow_admin(p_token);
  if not exists(select 1 from wow_users where id = p_id) then raise exception 'Ese reino ya no existe.'; end if;
  update wow_users set
      gold = greatest(0, gold + coalesce(p_gold,0)),
      wood = greatest(0, wood + coalesce(p_wood,0)),
      ore  = greatest(0, ore  + coalesce(p_ore,0))
    where id = p_id;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_admin_grant(text, text, numeric, numeric, numeric) to anon, authenticated;

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
