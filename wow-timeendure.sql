-- Endurecer contra manipulación de hora del cliente
-- Todo se calcula con hora del servidor; se corrigen saltos sospechosos

create or replace function public._wow_tick(p_owner text)
returns wow_users language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ms bigint; el numeric; cap numeric; rate jsonb; q wow_queue; done integer;
        maxel numeric; maxel2 numeric;
begin
  select * into u from wow_users where id = p_owner for update;
  if u.id is null then return u; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  -- Corregir last_ms en el futuro (reloj adelantado)
  if u.last_ms > ms + 60000 then
    begin
      insert into wow_events(kind, txt, created) values ('clock','Reloj futuro corregido para ' || coalesce(u.name,u.id), ms);
    exception when others then null;
    end;
    u.last_ms := ms;
  end if;
  -- Calcular tiempo transcurrido con hora servidor
  el := greatest(ms - least(u.last_ms, ms), 0)::numeric;
  maxel := _wow_tick_max() * 3600000;
  maxel2 := maxel * 2;
  -- Si hay salto muy grande sin venir de lógica normal, limitar
  if el > maxel2 then
    begin
      insert into wow_events(kind, txt, created) values ('clock','Salto de tiempo limitado para ' || coalesce(u.name,u.id) || ' (' || round(el/3600000.0,1) || 'h)', ms);
    exception when others then null;
    end;
    el := maxel;
  end if;
  el := least(el, maxel);
  if exists (select 1 from wow_queue where owner_id = p_owner and kind = 'build' and finish_ms <= ms) then
    update wow_buildings set level = level + 1, finish_ms = 0
     where owner_id = p_owner and bkey = (select ref from wow_queue where owner_id = p_owner and kind = 'build');
    delete from wow_queue where owner_id = p_owner and kind = 'build';
  end if;
  select * into q from wow_queue where owner_id = p_owner and kind = 'train';
  if q is not null and q.owner_id is not null and q.unit_ms > 0 then
    done := least(q.qty, floor((ms - q.start_ms) / q.unit_ms));
    if done > 0 then
      insert into wow_troops(owner_id, tkey, qty) values (p_owner, q.ref, done)
        on conflict (owner_id, tkey) do update set qty = wow_troops.qty + excluded.qty;
      update wow_queue set qty = qty - done, start_ms = start_ms + done * unit_ms
       where owner_id = p_owner and kind = 'train';
      delete from wow_queue where owner_id = p_owner and kind = 'train' and qty <= 0;
    end if;
  end if;
  rate := _wow_rate(p_owner);
  cap := _wow_cap(p_owner);
  update wow_users set
      gold = least(u.gold + el/3600000.0 * (rate->>'gold')::numeric, cap),
      wood = least(u.wood + el/3600000.0 * (rate->>'wood')::numeric, cap),
      ore  = least(u.ore  + el/3600000.0 * (rate->>'ore')::numeric, cap),
      last_ms = ms
    where id = p_owner returning * into u;
  return u;
end $$;
revoke all on function public._wow_tick(text) from public, anon, authenticated;

-- También sanear last_ms/created en el futuro al actualizar
create or replace function public._wow_users_time_sane()
returns trigger language plpgsql security definer set search_path to 'public' as $$
declare ms bigint;
begin
  ms := (extract(epoch from now())*1000)::bigint;
  if new.last_ms > ms + 120000 then new.last_ms := ms; end if;
  if new.created > ms + 120000 then new.created := ms; end if;
  return new;
end $$;

drop trigger if exists wow_users_time_sane_trg on public.wow_users;
create trigger wow_users_time_sane_trg
  before insert or update on public.wow_users
  for each row execute function public._wow_users_time_sane();
