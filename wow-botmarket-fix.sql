-- Ajustar bots al nuevo mercado sin escrow

-- el reino automatico pone una oferta de venta (sin retirar recursos)
create or replace function public._wow_bot_market(p_id text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  b wow_bots; it text; plo numeric; phi numeric; price numeric; stock numeric;
  sell numeric; want numeric; n integer; ms bigint; cand text[] := '{}';
  cur numeric;
begin
  select * into b from wow_bots where user_id = p_id and active;
  if b.user_id is null then return; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  select count(*) into n from wow_market_offers where seller = p_id and active;
  if n >= 2 then return; end if;
  if random() > 0.35 then return; end if;
  foreach it in array _wow_bot_items() loop
    select p.lo, p.hi into plo, phi from wow_bot_prices p where p.item = it;
    if coalesce(phi,0) <= 0 then continue; end if;
    if it in ('gold','wood','ore') then
      select case it when 'gold' then gold when 'wood' then wood else ore end
        into stock from wow_users where id = p_id;
      if coalesce(stock,0) < 400 then continue; end if;
    else
      select qty into stock from wow_troops where owner_id = p_id and tkey = it;
      if coalesce(stock,0) < 30 then continue; end if;
    end if;
    cand := cand || it;
  end loop;
  if array_length(cand, 1) is null then return; end if;
  it := cand[1 + floor(random() * array_length(cand, 1))::int];
  select p.lo, p.hi into plo, phi from wow_bot_prices p where p.item = it;
  if it in ('gold','wood','ore') then
    select case it when 'gold' then gold when 'wood' then wood else ore end
      into stock from wow_users where id = p_id;
    sell := floor(stock * 0.25);
    if sell > 1000 then sell := 1000; end if;
  else
    select qty into stock from wow_troops where owner_id = p_id and tkey = it;
    sell := greatest(5, floor(stock * 0.10));
    if sell > 200 then sell := 200; end if;
  end if;
  if coalesce(sell,0) <= 0 then return; end if;
  -- comprobar saldo (sin retirar)
  if it in ('gold','wood','ore') then
    select case it when 'gold' then gold when 'wood' then wood else ore end into cur from wow_users where id = p_id;
    if coalesce(cur,0) < sell then return; end if;
  else
    select qty into cur from wow_troops where owner_id = p_id and tkey = it;
    if coalesce(cur,0) < sell then return; end if;
  end if;
  price := plo + random() * (phi - plo);
  if coalesce(price,0) <= 0 then return; end if;
  want := round(sell * price, 2);
  if coalesce(want,0) <= 0 then return; end if;
  insert into wow_market_offers(seller, seller_name, give_key, give_qty, give_left, want_key, want_qty, want_left, created, expires_ms, active)
    values (p_id, (select name from wow_users where id = p_id), it, sell, sell, 'cup', want, want, ms, ms + 86400000, true);
end $$;
revoke all on function public._wow_bot_market(text) from public, anon, authenticated;
