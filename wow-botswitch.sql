-- ================================================================
-- APENDICE INTERRUPTOR DE REINOS AUTOMATICOS (un solo boton)
--   - wow_admin_bot_auto: activa o apaga TODOS los reinos
--     automaticos de golpe.
--       * Activar: todos vuelven a jugar ya y se ven siempre en
--         linea mientras el interruptor este encendido.
--       * Apagar: dejan de jugar y salen del contador en linea al
--         instante.
--   - wow_bots_tick (override):
--       * late (last_ms) de todos los que juegan -> siempre "en
--         linea", aunque su umbral (online_min) sea corto.
--       * sin siestas: nadie deja de actuar mas de 1.5x su ritmo
--         (el nivel sigue marcando la frecuencia: nivel 3 = base 4).
--   - El cron wow_bots ya llama a wow_bots_tick: no hay que tocarlo.
-- ================================================================

-- activar / apagar todos los reinos automaticos
create or replace function public.wow_admin_bot_auto(p_token text, p_on boolean)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare a wow_users; on_ boolean; ms bigint; n integer := 0;
begin
  a := _wow_admin(p_token);
  on_ := coalesce(p_on, false);
  insert into wow_settings(key, val) values ('bot_auto', case when on_ then '1' else '0' end)
    on conflict (key) do update set val = excluded.val;
  ms := (extract(epoch from now())*1000)::bigint;
  if on_ then
    -- vuelven a jugar ya y se ven en linea
    update wow_bots set active = true, next_ms = 0 where active is distinct from true or next_ms is distinct from 0;
    update wow_users set last_ms = ms where id in (select user_id from wow_bots);
  else
    -- dejan de jugar y salen del contador en linea ya mismo
    update wow_bots set active = false where active is distinct from false;
    update wow_users set last_ms = 0 where id in (select user_id from wow_bots);
  end if;
  select count(*) into n from wow_bots;
  return jsonb_build_object('ok', true, 'auto', on_, 'bots', n);
end $$;
grant execute on function public.wow_admin_bot_auto(text, boolean) to anon, authenticated;

-- turno global: avanza el mundo y actua sobre los que les toca
create or replace function public.wow_bots_tick(p_force boolean default false)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare b record; ms bigint; n integer := 0; mx bigint;
begin
  perform _wow_resolve();       -- las flotas aterrizan aunque no haya nadie conectado
  if _wow_bot_auto() = 0 then return jsonb_build_object('ok', true, 'auto', false, 'acted', 0); end if;
  ms := (extract(epoch from now())*1000)::bigint;
  -- siempre en linea: latido de todos los reinos automaticos que juegan
  update wow_users set last_ms = ms
   where active and id in (select user_id from wow_bots where active);
  for b in select user_id, level from wow_bots where active and (p_force or next_ms <= ms) loop
    begin
      perform _wow_bot_act(b.user_id);
      n := n + 1;
    exception when others then
      -- un reino con problemas no debe detener a los demas
      update wow_bots set next_ms = ms + 60000 where user_id = b.user_id;
    end;
    -- sin siestas: nunca espera mas de 1.5x su ritmo
    mx := ms + (((_wow_bot_level(b.level)->>'min')::int * 90000))::bigint;
    update wow_bots set next_ms = least(next_ms, mx) where user_id = b.user_id;
  end loop;
  return jsonb_build_object('ok', true, 'auto', true, 'acted', n);
end $$;
revoke all on function public.wow_bots_tick(boolean) from public, anon, authenticated;
