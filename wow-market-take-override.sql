-- Override take para compatibilidad con mercado sin escrow
create or replace function public.wow_market_take(p_token text, p_id bigint, p_qty numeric)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  u wow_users; v wow_users; o wow_market_offers; ms bigint;
  take numeric; want_part numeric; fee numeric; net numeric; new_left numeric;
  vcur numeric; share numeric := 0; tt record;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  if u.is_admin then raise exception 'Los administradores no comercian.'; end if;
  perform _wow_resolve();
  u := _wow_tick(u.id);
  ms := (extract(epoch from now())*1000)::bigint;
  select * into o from wow_market_offers where id = p_id for update;
  if o.id is null or not o.active then raise exception 'Esa oferta ya no está disponible.'; end if;
  if o.expires_ms <= ms then
    update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
    raise exception 'Esa oferta ha caducado.'; end if;
  if o.seller = u.id then raise exception 'Esa oferta es tuya.'; end if;
  select * into v from wow_users where id = o.seller for update;
  if v.id is null then
    update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
    raise exception 'Esa oferta ya no está disponible.'; end if;
  if o.give_key in ('gold','wood','ore','cup') then
    vcur := case o.give_key when 'gold' then v.gold when 'wood' then v.wood when 'ore' then v.ore else coalesce(v.cup,0) end;
    if coalesce(vcur,0) < coalesce(o.give_left,0) then
      update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
      raise exception 'El vendedor ya no tiene esos recursos. La venta se ha cancelado.';
    end if;
  else
    select qty into vcur from wow_troops where owner_id = o.seller and tkey = o.give_key;
    if coalesce(vcur,0) < coalesce(o.give_left,0) then
      delete from wow_troops where owner_id = o.seller and tkey = o.give_key and qty <= 0;
      update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
      raise exception 'El vendedor ya no tiene esas tropas. La venta se ha cancelado.';
    end if;
  end if;
  take := coalesce(p_qty, 0);
  if take <= 0 then raise exception 'Cantidad inválida.'; end if;
  if take >= o.give_left then
    take := o.give_left;
    want_part := o.want_left;
  else
    if _wow_mkt_is_troop(o.give_key) then take := floor(take); end if;
    if take <= 0 then raise exception 'Cantidad inválida.'; end if;
    want_part := o.want_left * (take / o.give_left);
    if _wow_mkt_is_troop(o.want_key) then
      want_part := greatest(1, round(want_part));
    else
      want_part := round(want_part, 2);
    end if;
    if want_part > o.want_left then want_part := o.want_left; end if;
    if want_part <= 0 then raise exception 'Cantidad demasiado pequeña.'; end if;
  end if;
  if o.give_key in ('gold','wood','ore','cup') then
    vcur := case o.give_key when 'gold' then (select gold from wow_users where id = o.seller) when 'wood' then (select wood from wow_users where id = o.seller) when 'ore' then (select ore from wow_users where id = o.seller) else (select coalesce(cup,0) from wow_users where id = o.seller) end;
    if coalesce(vcur,0) < take then
      update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
      raise exception 'El vendedor ya no tiene esos recursos. La venta se ha cancelado.';
    end if;
  else
    select qty into vcur from wow_troops where owner_id = o.seller and tkey = o.give_key;
    if coalesce(vcur,0) < take then
      update wow_market_offers set active = false, give_left = 0, want_left = 0 where id = o.id;
      raise exception 'El vendedor ya no tiene esas tropas. La venta se ha cancelado.';
    end if;
  end if;
  perform _wow_mkt_sub(u.id, o.want_key, want_part);
  perform _wow_mkt_sub(o.seller, o.give_key, take);
  perform _wow_mkt_add(u.id, o.give_key, take);
  fee := _wow_mkt_fee();
  net := want_part * (1 - fee/100.0);
  if _wow_mkt_is_troop(o.want_key) then net := round(net); end if;
  if net < 0 then net := 0; end if;
  if o.want_key = 'cup' and exists(select 1 from wow_bots where user_id = o.seller) then
    perform _wow_bot_bank_add(net, o.seller);
  else
    perform _wow_mkt_add(o.seller, o.want_key, net);
  end if;
  share := 0;
  for tt in select node from wow_thrones where holder is not null order by node loop
    share := want_part * least(_wow_node_pct(tt.node), fee) / 100.0;
    if _wow_mkt_is_troop(o.want_key) then share := round(share); end if;
    if share > 0 then perform _wow_throne_add(tt.node, o.want_key, share); end if;
  end loop;
  new_left := o.give_left - take;
  if new_left <= 0.0001 then
    update wow_market_offers set give_left = 0, want_left = 0, active = false where id = o.id;
  else
    update wow_market_offers set give_left = new_left, want_left = greatest(0, o.want_left - want_part) where id = o.id;
  end if;
  return jsonb_build_object('ok', true, 'took', take, 'paid', want_part, 'fee', fee, 'net', net, 'throne_share', share);
end $$;
revoke all on function public.wow_market_take(text, bigint, numeric) from public, anon, authenticated;
grant execute on function public.wow_market_take(text, bigint, numeric) to anon, authenticated;
