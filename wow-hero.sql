-- ============================================
-- SISTEMA DEL REY EQUIPABLE
-- ============================================

create table if not exists public.wow_heroes(
  owner_id text primary key references public.wow_users(id) on delete cascade,
  name text not null default 'Rey',
  level integer not null default 1,
  xp integer not null default 0,
  atk integer not null default 0,
  def integer not null default 0,
  created bigint not null default 0
);

create table if not exists public.wow_hero_items(
  id serial primary key,
  slot text not null, -- arma, escudo, casco, armadura, botas, anillo
  name text not null,
  icon text not null default '⚔️',
  atk integer not null default 0,
  def integer not null default 0,
  price_gold numeric not null default 0,
  price_wood numeric not null default 0,
  price_ore  numeric not null default 0,
  price_cup  numeric not null default 0,
  req_level  integer not null default 1,
  active boolean not null default true
);

create table if not exists public.wow_hero_inventory(
  id bigserial primary key,
  owner_id text not null references public.wow_users(id) on delete cascade,
  item_id integer not null references public.wow_hero_items(id) on delete cascade,
  qty integer not null default 1,
  unique(owner_id, item_id)
);

create table if not exists public.wow_hero_equipped(
  owner_id text primary key references public.wow_users(id) on delete cascade,
  arma     integer references public.wow_hero_items(id),
  escudo   integer references public.wow_hero_items(id),
  casco    integer references public.wow_hero_items(id),
  armadura integer references public.wow_hero_items(id),
  botas    integer references public.wow_hero_items(id),
  anillo   integer references public.wow_hero_items(id)
);

-- Items básicos
insert into public.wow_hero_items(slot,name,icon,atk,def,price_gold,price_wood,price_ore,price_cup,req_level) values
('arma','Espada Oxidada','⚔️',2,0,150,50,30,0,1),
('arma','Espada de Acero','⚔️',5,0,500,200,150,0,1),
('arma','Hoja de Guerra','⚔️',9,0,1200,500,400,0,1),
('escudo','Escudo de Madera','🛡️',0,2,120,80,40,0,1),
('escudo','Escudo de Acero','🛡️',0,5,450,200,160,0,1),
('casco','Yelmo de Cuero','⛑️',0,2,100,60,30,0,1),
('casco','Yelmo de Acero','⛑️',1,4,350,150,120,0,1),
('armadura','Cota de Cuero','👕',0,3,200,100,60,0,1),
('armadura','Cota de Malla','👕',1,6,650,300,250,0,1),
('botas','Botas de Cuero','👢',0,2,90,60,30,0,1),
('botas','Botas Reforzadas','👢',1,4,320,140,110,0,1),
('anillo','Anillo de Valor','💍',2,2,800,0,0,5,1)
on conflict do nothing;

alter table public.wow_heroes enable row level security;
alter table public.wow_hero_items enable row level security;
alter table public.wow_hero_inventory enable row level security;
alter table public.wow_hero_equipped enable row level security;

-- Crear heroe si no existe
create or replace function public.wow_hero_init(p_owner text)
returns void language plpgsql security definer set search_path to 'public' as $$
declare ms bigint := (extract(epoch from now())*1000)::bigint;
begin
  insert into public.wow_heroes(owner_id,name,level,xp,atk,def,created)
    values (p_owner, (select name from wow_users where id=p_owner), 1, 0, 0, 0, ms)
    on conflict (owner_id) do nothing;
  insert into public.wow_hero_equipped(owner_id) values (p_owner) on conflict (owner_id) do nothing;
end $$;
revoke all on function public.wow_hero_init(text) from public, anon, authenticated;

-- Bonus total del rey equipado
create or replace function public.wow_hero_bonus(p_owner text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare e record; i record; hatk integer := 0; hdef integer := 0;
begin
  perform public.wow_hero_init(p_owner);
  select * into e from public.wow_hero_equipped where owner_id = p_owner;
  if e.arma is not null then select atk,def into i from public.wow_hero_items where id=e.arma; hatk := hatk + coalesce(i.atk,0); hdef := hdef + coalesce(i.def,0); end if;
  if e.escudo is not null then select atk,def into i from public.wow_hero_items where id=e.escudo; hatk := hatk + coalesce(i.atk,0); hdef := hdef + coalesce(i.def,0); end if;
  if e.casco is not null then select atk,def into i from public.wow_hero_items where id=e.casco; hatk := hatk + coalesce(i.atk,0); hdef := hdef + coalesce(i.def,0); end if;
  if e.armadura is not null then select atk,def into i from public.wow_hero_items where id=e.armadura; hatk := hatk + coalesce(i.atk,0); hdef := hdef + coalesce(i.def,0); end if;
  if e.botas is not null then select atk,def into i from public.wow_hero_items where id=e.botas; hatk := hatk + coalesce(i.atk,0); hdef := hdef + coalesce(i.def,0); end if;
  if e.anillo is not null then select atk,def into i from public.wow_hero_items where id=e.anillo; hatk := hatk + coalesce(i.atk,0); hdef := hdef + coalesce(i.def,0); end if;
  return jsonb_build_object('atk', hatk, 'def', hdef);
end $$;
revoke all on function public.wow_hero_bonus(text) from public, anon, authenticated;

-- Info del palacio
create or replace function public.wow_hero_info(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; h record; e record; inv jsonb; shop jsonb; bonus jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform public.wow_hero_init(u.id);
  select * into h from public.wow_heroes where owner_id=u.id;
  select * into e from public.wow_hero_equipped where owner_id=u.id;
  bonus := public.wow_hero_bonus(u.id);
  select coalesce(jsonb_agg(jsonb_build_object('inv_id',iv.id,'item_id',it.id,'slot',it.slot,'name',it.name,'icon',it.icon,'atk',it.atk,'def',it.def)),'[]') into inv
    from public.wow_hero_inventory iv join public.wow_hero_items it on it.id=iv.item_id where iv.owner_id=u.id and iv.qty>0;
  select coalesce(jsonb_agg(jsonb_build_object('id',it.id,'slot',it.slot,'name',it.name,'icon',it.icon,'atk',it.atk,'def',it.def,'price_gold',it.price_gold,'price_wood',it.price_wood,'price_ore',it.price_ore,'price_cup',it.price_cup,'req_level',it.req_level) order by it.slot, it.atk+it.def),'[]') into shop
    from public.wow_hero_items it where it.active=true;
  return jsonb_build_object('ok',true,'hero',jsonb_build_object('name',h.name,'level',h.level,'xp',h.xp),'eq',jsonb_build_object('arma',e.arma,'escudo',e.escudo,'casco',e.casco,'armadura',e.armadura,'botas',e.botas,'anillo',e.anillo),'bonus',bonus,'inv',inv,'shop',shop,'me',jsonb_build_object('gold',u.gold,'wood',u.wood,'ore',u.ore,'cup',coalesce(u.cup,0)));
end $$;
grant execute on function public.wow_hero_info(text) to anon, authenticated;

-- Comprar
create or replace function public.wow_hero_buy(p_token text, p_item integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; it record; have integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform public.wow_hero_init(u.id);
  select * into it from public.wow_hero_items where id=p_item and active;
  if it.id is null then raise exception 'Objeto no válido.'; end if;
  if u.gold < it.price_gold then raise exception 'No tienes suficiente Oro.'; end if;
  if u.wood < it.price_wood then raise exception 'No tienes suficiente Madera.'; end if;
  if u.ore < it.price_ore then raise exception 'No tienes suficiente Mineral.'; end if;
  if coalesce(u.cup,0) < it.price_cup then raise exception 'No tienes suficientes CUP.'; end if;
  update wow_users set gold=gold-it.price_gold, wood=wood-it.price_wood, ore=ore-it.price_ore, cup=coalesce(cup,0)-it.price_cup where id=u.id;
  insert into public.wow_hero_inventory(owner_id,item_id,qty) values (u.id,it.id,1) on conflict (owner_id,item_id) do update set qty=wow_hero_inventory.qty+1;
  return jsonb_build_object('ok',true);
end $$;
grant execute on function public.wow_hero_buy(text, integer) to anon, authenticated;

-- Equipar
create or replace function public.wow_hero_equip(p_token text, p_item integer)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; it record; have integer;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform public.wow_hero_init(u.id);
  select * into it from public.wow_hero_items where id=p_item;
  if it.id is null then raise exception 'Objeto no válido.'; end if;
  select qty into have from public.wow_hero_inventory where owner_id=u.id and item_id=p_item;
  if coalesce(have,0) < 1 then raise exception 'No tienes ese objeto.'; end if;
  execute format('update public.wow_hero_equipped set %I = $1 where owner_id = $2', it.slot) using p_item, u.id;
  return jsonb_build_object('ok',true);
end $$;
grant execute on function public.wow_hero_equip(text, integer) to anon, authenticated;

-- Desequipar
create or replace function public.wow_hero_unequip(p_token text, p_slot text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  perform public.wow_hero_init(u.id);
  if p_slot not in ('arma','escudo','casco','armadura','botas','anillo') then raise exception 'Ranura no válida.'; end if;
  execute format('update public.wow_hero_equipped set %I = null where owner_id = $1', p_slot) using u.id;
  return jsonb_build_object('ok',true);
end $$;
grant execute on function public.wow_hero_unequip(text, text) to anon, authenticated;
