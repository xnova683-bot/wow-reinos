
-- ampliar admin para personalidad
drop function if exists public.wow_admin_bot_set(text, text, integer, text);
create or replace function public.wow_admin_bot_set(p_token text, p_id text, p_level integer default null, p_preset text default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; b wow_bots;
begin
  a := _wow_admin(p_token);
  select * into b from wow_bots where user_id = p_id;
  if b.user_id is null then raise exception 'Ese bot no existe.'; end if;
  if p_level is not null then
    update wow_bots set level = greatest(1, least(5, p_level)) where user_id = p_id;
  end if;
  if p_preset is not null then
    perform _wow_bot_apply_preset(p_id, p_preset);
  end if;
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.wow_admin_bot_set(text, text, integer, text) to anon, authenticated;
