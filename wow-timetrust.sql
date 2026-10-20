-- ================================================================
-- APENDICE CONFIANZA DE TIEMPO: el reino no puede ganar tiempo
-- manipulando el reloj de su ordenador.
--   - wow_register (override): created y last_ms los pone el
--     SERVIDOR (now()), nunca el cliente. Se mantiene el parametro
--     p_now por compatibilidad, pero se ignora.
--   - _wow_tick (override): recorta la produccion por refresco a
--     _wow_tick_max() horas. Si un reino lleva mucho sin entrar
--     (o alguien intenta colar tiempo), no acumula mas que ese
--     tope en una sola peticion: entra y sigue acumulando.
--   - _wow_tick_max(): tope configurable en wow_settings (por
--     defecto 3 horas).
--   - wow_admin_timeaudit: lista reinos con created/last_ms
--     sospechosos (en el futuro o desfase grande) para revisar.
--   - Saneado: last_ms/created en el futuro se corrigen a now().
-- ================================================================

-- tope de horas de produccion que se pueden acreditar en un refresco
create or replace function public._wow_tick_max()
returns numeric language sql stable security definer set search_path to 'public' as $$
  select least(greatest(coalesce((select val::numeric from wow_settings where key = 'tick_max_h'), 3), 1), 72)
$$;
revoke all on function public._wow_tick_max() from public, anon, authenticated;

-- registro: la hora la pone el servidor (se ignora p_now)
create or replace function public.wow_register(p_name text, p_realm text, p_faction text, p_salt text, p_hash text, p_now bigint default null)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare vname text; vrealm text; vkey text; vfac text;
       vpos integer; vc integer; vn integer; vs integer; ms bigint;
begin
  vname := btrim(coalesce(p_name,'')); vkey := _wow_key(vname); vrealm := btrim(coalesce(p_realm,''));
  if length(vkey) < 2 then raise exception 'Escribe un nombre de rey (así entrarás después).'; end if;
  if length(vrealm) < 2 then raise exception 'Escribe el nombre de tu reino.'; end if;
  if vname ~ '[<>&"''\\]' or vname ~ '[[:cntrl:]]' or length(vname) > 24 then
    raise exception 'El nombre de rey solo puede llevar letras, números, espacios y guiones.'; end if;
  if vrealm ~ '[<>&"''\\]' or vrealm ~ '[[:cntrl:]]' or length(vrealm) > 24 then
    raise exception 'El nombre del reino solo puede llevar letras, números, espacios y guiones.'; end if;
  vfac := lower(btrim(coalesce(p_faction,'')));
  if vfac not in ('alianza','horda') then raise exception 'Elige Alianza o Horda.'; end if;
  if coalesce(p_salt,'') = '' or coalesce(p_hash,'') = '' then raise exception 'Faltan datos de seguridad.'; end if;
  if exists(select 1 from wow_users where name_key = vkey) then
    raise exception 'Ese nombre de rey ya está en uso. Prueba con otro.'; end if;
  vc := 0; vn := -1;
  for i in 0..3 loop
    select count(*) into vs from wow_users where active and pos >= i*20 and pos < i*20 + 20;
    if vn < 0 or vs < vn then vn := vs; vc := i; end if;
  end loop;
  vpos := null;
  for i in 0..3 loop
    for j in 0..19 loop
      if not exists(select 1 from wow_users where active and pos = vc*20 + j) then
        vpos := vc*20 + j; exit;
      end if;
    end loop;
    exit when vpos is not null;
    vc := (vc + 1) % 4;
  end loop;
  if vpos is null then raise exception 'El mundo está lleno: ya hay 80 reinos.'; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  if p_now is not null and abs(p_now - ms) > 300000 then
    begin
      insert into wow_events(kind, txt, created) values ('clock', 'Reloj raro al registrar "' || vname || '": desfase ' || round((p_now - ms)/60000.0) || ' min.', ms);
    exception when others then null;
    end;
  end if;
  insert into wow_users (id, name, name_key, faction, salt, hash, active, created, last_ms, gold, wood, ore, pos, alliance)
  values (vkey, vrealm, vkey, vfac, p_salt, p_hash, true, ms, ms, 500, 500, 500, vpos, null);
  return jsonb_build_object('ok', true, 'id', vkey, 'pos', vpos);
end $$;
grant execute on function public.wow_register(text, text, text, text, text, bigint) to anon, authenticated;

-- tick: recorta la produccion por refresco al tope
create or replace function public._wow_tick(p_owner text)
returns wow_users language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; ms bigint; el numeric; cap numeric; rate jsonb; q wow_queue; done integer;
begin
  select * into u from wow_users where id = p_owner for update;
  if u.id is null then return u; end if;
  ms := (extract(epoch from now())*1000)::bigint;
  el := greatest(ms - least(u.last_ms, ms), 0)::numeric;
  el := least(el, _wow_tick_max() * 3600000);
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
  select * into q from wow_queue where owner_id = p_owner;
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

-- auditoria: reinos con la hora rara (para el panel de admin)
create or replace function public.wow_admin_timeaudit(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; ms bigint;
begin
  a := _wow_admin(p_token);
  ms := (extract(epoch from now())*1000)::bigint;
  return jsonb_build_object('ok', true, 'now', ms, 'top', _wow_tick_max(), 'rows', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', w.id, 'name', w.name,
      'created', w.created, 'last', w.last_ms,
      'created_off_min', round((w.created - ms)/60000.0),
      'last_off_min', round((w.last_ms - ms)/60000.0)
    ) order by abs(w.created - ms) desc)
    from wow_users w
    where w.created > ms + 300000 or w.last_ms > ms + 300000
       or w.created < ms - 365::bigint*86400000
  ), '[]'::jsonb));
end $$;
grant execute on function public.wow_admin_timeaudit(text) to anon, authenticated;

-- saneado: ninguna cuenta puede tener created/last_ms en el futuro
update wow_users set created = (extract(epoch from now())*1000)::bigint
 where created > (extract(epoch from now())*1000)::bigint + 300000;
update wow_users set last_ms = (extract(epoch from now())*1000)::bigint
 where last_ms > (extract(epoch from now())*1000)::bigint + 300000;

-- deja el tope por defecto en la configuracion (no pisa un valor ya elegido)
insert into wow_settings(key, val) values ('tick_max_h', '3')
  on conflict (key) do nothing;
