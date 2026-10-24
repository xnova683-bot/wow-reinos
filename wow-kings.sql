-- Sistema de Reyes por Reino (suben de nivel con batallas del Trono)
BEGIN;

-- Tabla de reyes por reino
CREATE TABLE IF NOT EXISTS public.wow_kings (
  owner_id text PRIMARY KEY REFERENCES public.wow_users(id) ON DELETE CASCADE,
  level integer NOT NULL DEFAULT 1,
  xp integer NOT NULL DEFAULT 0,
  xp_next integer NOT NULL DEFAULT 100,
  atk integer NOT NULL DEFAULT 55,
  hp integer NOT NULL DEFAULT 75,
  wins integer NOT NULL DEFAULT 0,
  losses integer NOT NULL DEFAULT 0,
  throne_wins integer NOT NULL DEFAULT 0,
  throne_defends integer NOT NULL DEFAULT 0,
  throne_losses integer NOT NULL DEFAULT 0,
  title text,
  updated_ms bigint
);

ALTER TABLE public.wow_kings ENABLE ROW LEVEL SECURITY;

-- Inicializar reyes para todos los usuarios existentes
INSERT INTO public.wow_kings (owner_id, level, xp, atk, hp, updated_ms)
SELECT id, 1, 0, 55, 75, (extract(epoch from now())*1000)::bigint
FROM public.wow_users
WHERE NOT EXISTS (SELECT 1 FROM public.wow_kings k WHERE k.owner_id = wow_users.id);

-- Función para obtener stats del rey por nivel
CREATE OR REPLACE FUNCTION public._wow_king_stats(p_level integer)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
  RETURN jsonb_build_object(
    'atk', 55 + (p_level - 1) * 4,
    'hp', 75 + (p_level - 1) * 6,
    'xp_next', 100 + (p_level - 1) * 25
  );
END;
$$;

-- Función para otorgar XP al rey por batalla de trono
CREATE OR REPLACE FUNCTION public._wow_king_gain_xp(p_owner text, p_victory boolean, p_defense boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  k wow_kings; ns jsonb; gain integer; leveled boolean := false;
  new_level integer; new_xp integer; new_atk integer; new_hp integer; new_xp_next integer;
BEGIN
  INSERT INTO public.wow_kings (owner_id, level, xp, atk, hp, updated_ms)
  VALUES (p_owner, 1, 0, 55, 75, (extract(epoch from now())*1000)::bigint)
  ON CONFLICT (owner_id) DO NOTHING;
  
  SELECT * INTO k FROM public.wow_kings WHERE owner_id = p_owner FOR UPDATE;
  IF k.owner_id IS NULL THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  
  -- Calcular XP ganado
  IF p_defense AND p_victory THEN
    gain := 80;
    UPDATE public.wow_kings SET throne_defends = throne_defends + 1, wins = wins + 1 WHERE owner_id = p_owner;
  ELSIF NOT p_defense AND p_victory THEN
    gain := 60;
    UPDATE public.wow_kings SET throne_wins = throne_wins + 1, wins = wins + 1 WHERE owner_id = p_owner;
  ELSIF p_defense AND NOT p_victory THEN
    gain := 30;
    UPDATE public.wow_kings SET throne_losses = throne_losses + 1, losses = losses + 1 WHERE owner_id = p_owner;
  ELSE
    gain := 15;
    UPDATE public.wow_kings SET throne_losses = throne_losses + 1, losses = losses + 1 WHERE owner_id = p_owner;
  END IF;
  
  SELECT * INTO k FROM public.wow_kings WHERE owner_id = p_owner FOR UPDATE;
  new_xp := k.xp + gain;
  new_level := k.level;
  leveled := false;
  
  -- Subir niveles
  WHILE new_xp >= (100 + (new_level - 1) * 25) AND new_level < 30 LOOP
    new_xp := new_xp - (100 + (new_level - 1) * 25);
    new_level := new_level + 1;
    leveled := true;
  END LOOP;
  
  ns := public._wow_king_stats(new_level);
  new_atk := (ns->>'atk')::integer;
  new_hp := (ns->>'hp')::integer;
  new_xp_next := (ns->>'xp_next')::integer;
  
  UPDATE public.wow_kings SET 
    level = new_level, 
    xp = new_xp,
    xp_next = new_xp_next,
    atk = new_atk, 
    hp = new_hp,
    updated_ms = (extract(epoch from now())*1000)::bigint
  WHERE owner_id = p_owner;
  
  RETURN jsonb_build_object('ok', true, 'gain', gain, 'level', new_level, 'leveled', leveled, 'xp', new_xp);
END;
$$;

-- Bonus pasivo del rey al ejército (aplica en batallas PvP)
CREATE OR REPLACE FUNCTION public._wow_king_army_bonus(p_owner text)
RETURNS numeric LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  k wow_kings;
BEGIN
  SELECT * INTO k FROM public.wow_kings WHERE owner_id = p_owner;
  IF k.owner_id IS NULL THEN RETURN 0; END IF;
  -- +1% cada 5 niveles, max +5%
  RETURN LEAST(floor(k.level / 5.0) * 0.01, 0.05);
END;
$$;

-- Obtener info del rey
CREATE OR REPLACE FUNCTION public.wow_king_info(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public' AS $$
DECLARE
  u wow_users; k wow_kings; ns jsonb; bonus numeric;
BEGIN
  u := _wow_sess(p_token);
  IF u.id IS NULL THEN RAISE EXCEPTION 'Sesión expirada.'; END IF;
  INSERT INTO public.wow_kings (owner_id, level, xp, atk, hp, updated_ms)
  VALUES (u.id, 1, 0, 55, 75, (extract(epoch from now())*1000)::bigint)
  ON CONFLICT (owner_id) DO NOTHING;
  SELECT * INTO k FROM public.wow_kings WHERE owner_id = u.id;
  ns := public._wow_king_stats(k.level);
  bonus := public._wow_king_army_bonus(u.id);
  RETURN jsonb_build_object(
    'owner', u.id,
    'name', u.name,
    'level', k.level,
    'xp', k.xp,
    'xp_next', k.xp_next,
    'atk', k.atk,
    'hp', k.hp,
    'wins', k.wins,
    'losses', k.losses,
    'throne_wins', k.throne_wins,
    'throne_defends', k.throne_defends,
    'throne_losses', k.throne_losses,
    'bonus_pct', round(bonus * 100)::int,
    'title', CASE
      WHEN k.level >= 20 THEN 'Rey Legendario'
      WHEN k.level >= 16 THEN 'Rey Veterano'
      WHEN k.level >= 11 THEN 'Rey Belicoso'
      WHEN k.level >= 6 THEN 'Señor de Guerra'
      ELSE 'Rey Novato'
    END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.wow_king_info(text) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public._wow_king_gain_xp(text, boolean, boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION public._wow_king_army_bonus(text) TO anon, authenticated;

COMMIT;
