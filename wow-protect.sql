-- Protección de recursos contra saqueo
-- Almacén +2% por nivel, Fortaleza +3% por nivel, máx 60%

create or replace function public._wow_protected(p_owner text)
returns numeric
language plpgsql
security definer
set search_path to 'public'
as $$
declare la integer;
declare lf integer;
declare p numeric := 0;
begin
  if p_owner is null or btrim(p_owner) = '' then
    return 0;
  end if;
  select coalesce(max(level),0) into la
    from public.wow_buildings
   where owner_id = p_owner and bkey = 'almacen';
  select coalesce(max(level),0) into lf
    from public.wow_buildings
   where owner_id = p_owner and bkey = 'fortaleza';
  p := la * 0.02 + lf * 0.03;
  if p < 0 then p := 0; end if;
  if p > 0.60 then p := 0.60; end if;
  return p;
end;
$$;

revoke all on function public._wow_protected(text) from public, anon, authenticated;
grant execute on function public._wow_protected(text) to service_role;
