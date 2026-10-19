-- ================================================================
-- APENDICE 4 CONTINENTES: mapa 2x2 (80 casillas de castillo)
--   - Tronos y aldeas de los dos continentes nuevos (derecha).
--   - Los registros nuevos se reparten entre el continente con menos
--     reinos, para que los cuatro se pueblen por igual.
--   - El reparto de casillas (80 = 4 x 20) es el mismo que usa el
--     frontend: pos/20 = continente, pos%20 = slot.
-- ================================================================

alter table public.wow_thrones add column if not exists kind text not null default 'trono';

-- tronos de la columna derecha
insert into public.wow_thrones(node, name) values
  (50, 'TRONO DE NORTHREND'), (75, 'TRONO DE PANDARIA')
  on conflict (node) do nothing;

-- aldeas de la columna derecha (4 por continente, como en los otros dos)
insert into public.wow_thrones(node, name, kind) values
  (71, 'Aldea del Amanecer', 'aldea'),
  (72, 'Aldea del Roble',    'aldea'),
  (73, 'Aldea del Pico',     'aldea'),
  (74, 'Aldea del Raudal',   'aldea'),
  (96, 'Aldea del Puerto',   'aldea'),
  (97, 'Aldea de la Pradera','aldea'),
  (98, 'Aldea de la Arena',  'aldea'),
  (99, 'Aldea de la Nieve',  'aldea')
  on conflict (node) do nothing;

-- ---------- cuenta: hueco en el continente con menos reinos ----------
create or replace function public.wow_register(p_name text, p_realm text, p_faction text, p_salt text, p_hash text, p_now bigint)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare vname text; vrealm text; vkey text; vfac text;
       vpos integer; vc integer; vn integer; vs integer;
begin
  vname := btrim(coalesce(p_name,'')); vkey := _wow_key(vname); vrealm := btrim(coalesce(p_realm,''));
  if length(vkey) < 2 then raise exception 'Escribe un nombre de rey (así entrarás después).'; end if;
  if length(vrealm) < 2 then raise exception 'Escribe el nombre de tu reino.'; end if;
  -- los nombres se ven en el ranking, el mapa y el chat: nada de etiquetas ni símbolos raros
  if vname ~ '[<>&"''\\]' or vname ~ '[[:cntrl:]]' or length(vname) > 24 then
    raise exception 'El nombre de rey solo puede llevar letras, números, espacios y guiones.'; end if;
  if vrealm ~ '[<>&"''\\]' or vrealm ~ '[[:cntrl:]]' or length(vrealm) > 24 then
    raise exception 'El nombre del reino solo puede llevar letras, números, espacios y guiones.'; end if;
  vfac := lower(btrim(coalesce(p_faction,'')));
  if vfac not in ('alianza','horda') then raise exception 'Elige Alianza o Horda.'; end if;
  if coalesce(p_salt,'') = '' or coalesce(p_hash,'') = '' then raise exception 'Faltan datos de seguridad.'; end if;
  if exists(select 1 from wow_users where name_key = vkey) then
    raise exception 'Ese nombre de rey ya está en uso. Prueba con otro.'; end if;

  -- continente con menos reinos (los cuatro se pueblan parejos)
  vc := 0; vn := -1;
  for i in 0..3 loop
    select count(*) into vs from wow_users where active and pos >= i*20 and pos < i*20 + 20;
    if vn < 0 or vs < vn then vn := vs; vc := i; end if;
  end loop;
  -- primer hueco libre; si ese continente se lleno, paso al siguiente
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

  insert into wow_users (id, name, name_key, faction, salt, hash, active, created, last_ms, gold, wood, ore, pos, alliance)
  values (vkey, vrealm, vkey, vfac, p_salt, p_hash, true, p_now, p_now, 500, 500, 500, vpos, null);
  return jsonb_build_object('ok', true, 'id', vkey, 'pos', vpos);
end $$;
