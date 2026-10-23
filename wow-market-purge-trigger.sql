create or replace function public._wow_users_res_purge()
returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if (old.gold <> new.gold or old.wood <> new.wood or old.ore <> new.ore or coalesce(old.cup,0) <> coalesce(new.cup,0)) then
    if (new.gold < old.gold or new.wood < old.wood or new.ore < old.ore or coalesce(new.cup,0) < coalesce(old.cup,0)) then
      begin
        perform public._wow_market_purge(new.id);
      exception when others then
        null;
      end;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists wow_users_res_purge_trg on public.wow_users;
create trigger wow_users_res_purge_trg
  after update of gold, wood, ore, cup on public.wow_users
  for each row execute function public._wow_users_res_purge();

revoke all on function public._wow_users_res_purge() from public, anon, authenticated;
grant execute on function public._wow_users_res_purge() to service_role;
