-- ================================================================
-- APENDICE RANKING DE TROPAS: los puntos de tropas cuentan aunque
-- las tropas no esten en casa.
--   - _wow_troops_total(p_owner): suma las tropas del reino esten
--     donde esten:
--       * en casa            -> wow_troops
--       * de marcha/ataque   -> wow_fleets.troops (attacker = reino)
--       * aportadas a nodos  -> wow_node_contrib.troops (user_id)
--     No se usa wow_thrones.garrison porque su contenido ya esta
--     contado en wow_node_contrib (evita contar dos veces).
--   - wow_leaderboard (override): usa _wow_troops_total para los
--     puntos y el numero de tropas.
-- ================================================================

-- total de tropas de un reino, esten donde esten
create or replace function public._wow_troops_total(p_owner text)
returns numeric language sql stable security definer set search_path to 'public' as $$
  select coalesce((select sum(qty) from wow_troops where owner_id = p_owner), 0)
       + coalesce((select sum(v) from wow_fleets f,
                     lateral (select coalesce(sum(x.value::int),0) v from jsonb_each_text(f.troops) x) s
                   where f.attacker = p_owner), 0)
       + coalesce((select sum(v) from wow_node_contrib c,
                     lateral (select coalesce(sum(x.value::int),0) v from jsonb_each_text(c.troops) x) s
                   where c.user_id = p_owner), 0)
$$;
revoke all on function public._wow_troops_total(text) from public, anon, authenticated;

-- clasificacion: puntos y tropas contando todas las tropas del reino
create or replace function public.wow_leaderboard(p_token text)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare u wow_users; out jsonb;
begin
  u := _wow_sess(p_token);
  if u.id is null then raise exception 'Sesión expirada. Vuelve a entrar.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'name', s.name, 'faction', s.faction, 'me', s.me, 'created', s.created,
      'alliance', s.atag,
      'points', s.lsum * 100 + s.tsum, 'level_sum', s.lsum, 'troops', s.tsum,
      'thrones', s.thrones, 'aldeas', s.aldeas)
    order by s.thrones desc, s.aldeas desc, (s.lsum * 100 + s.tsum) desc, s.created), '[]'::jsonb)
    into out
    from (
      select w.id, w.name, w.faction, w.created, (w.id = u.id) me, coalesce(al.tag,'') atag,
        coalesce((select sum(b.level) from wow_buildings b where b.owner_id = w.id),0) lsum,
        _wow_troops_total(w.id) tsum,
        (select count(*) from wow_thrones th where th.holder = w.id and th.kind = 'trono') thrones,
        (select count(*) from wow_thrones th where th.holder = w.id and th.kind = 'aldea') aldeas
      from wow_users w left join wow_alliances al on al.id = w.alliance
      where w.active and not coalesce(w.is_admin,false)
    ) s;
  return out;
end $$;
revoke all on function public.wow_leaderboard(text) from public;
grant execute on function public.wow_leaderboard(text) to anon, authenticated;
