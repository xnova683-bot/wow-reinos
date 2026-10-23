-- Mercado sin escrow: los recursos se quedan en el reino
-- Al gastar se cancelan las ventas que ya no se puedan cubrir

-- helper: total reservado activo por (vendedor, recurso)
create or replace function public._wow_market_reserved(p_seller text, p_res text)
returns numeric
language plpgsql
security definer
set search_path to 'public'
as $$
declare r numeric := 0;
begin
  if p_seller is null or p_res is null then return 0; end if;
  select coalesce(sum(give_left),0) into r
    from public.wow_market_offers
   where seller = p_seller
     and active = true
     and give_key = p_res
     and expires_ms > (extract(epoch from now())*1000)::bigint;
  return r;
end;
$$;

-- cancelar ofertas que ya no se puedan cubrir tras gastar recursos
create or replace function public._wow_market_purge(p_owner text)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $$
declare o record;
declare bal_gold numeric; bal_wood numeric; bal_ore numeric; bal_cup numeric;
declare res_gold numeric; res_wood numeric; res_ore numeric; res_cup numeric;
declare cancelled integer := 0;
begin
  if p_owner is null or p_owner = '' then return 0; end if;
  select gold, wood, ore, cup into bal_gold, bal_wood, bal_ore, bal_cup
    from public.wow_users where id = p_owner;
  res_gold := coalesce(public._wow_market_reserved(p_owner,'gold'),0);
  res_wood := coalesce(public._wow_market_reserved(p_owner,'wood'),0);
  res_ore  := coalesce(public._wow_market_reserved(p_owner,'ore'),0);
  res_cup  := coalesce(public._wow_market_reserved(p_owner,'cup'),0);
  -- cancelar por recurso
  for o in select * from public.wow_market_offers where seller = p_owner and active = true order by id for update loop
    if o.give_key = 'gold' and coalesce(bal_gold,0) < o.give_left then
      update public.wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
      cancelled := cancelled + 1;
    elsif o.give_key = 'wood' and coalesce(bal_wood,0) < o.give_left then
      update public.wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
      cancelled := cancelled + 1;
    elsif o.give_key = 'ore' and coalesce(bal_ore,0) < o.give_left then
      update public.wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
      cancelled := cancelled + 1;
    elsif o.give_key = 'cup' and coalesce(bal_cup,0) < o.give_left then
      update public.wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
      cancelled := cancelled + 1;
    end if;
  end loop;
  return cancelled;
end;
$$;

revoke all on function public._wow_market_reserved(text,text) from public, anon, authenticated;
revoke all on function public._wow_market_purge(text) from public, anon, authenticated;
grant execute on function public._wow_market_reserved(text,text) to service_role;
grant execute on function public._wow_market_purge(text) to service_role;
