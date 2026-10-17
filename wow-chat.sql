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
