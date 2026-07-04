CREATE OR REPLACE FUNCTION public.admin_update_team_season_price(p_price_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  subject public.admin_subjects%ROWTYPE;
  price public.team_season_prices%ROWTYPE;
  next_subject_id uuid;
  next_season text;
  next_season_year integer;
  next_hourly_rate numeric;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT *
  INTO price
  FROM public.team_season_prices
  WHERE id = p_price_id
    AND "Deleted" = 0;

  IF price.id IS NULL THEN
    RAISE EXCEPTION 'Season price not found' USING ERRCODE = '22023';
  END IF;

  next_subject_id := coalesce(nullif(payload->>'subjectId', '')::uuid, price.subject_id);
  next_season := coalesce(nullif(trim(payload->>'season'), ''), price.season);
  next_season_year := coalesce(nullif(payload->>'seasonYear', '')::integer, price.season_year);
  next_hourly_rate := coalesce(nullif(payload->>'hourlyRate', '')::numeric, price.hourly_rate);

  SELECT *
  INTO subject
  FROM public.admin_subjects
  WHERE id = next_subject_id
    AND subject_type = 'team'
    AND "Deleted" = 0;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Team record not found' USING ERRCODE = '22023';
  END IF;

  IF next_season_year NOT BETWEEN 2000 AND 2100 THEN
    RAISE EXCEPTION 'Season year must be between 2000 and 2100' USING ERRCODE = '22023';
  END IF;

  IF next_hourly_rate < 0 THEN
    RAISE EXCEPTION 'Hourly rate must be zero or greater' USING ERRCODE = '22023';
  END IF;

  UPDATE public.team_season_prices
  SET subject_id = subject.id,
      season = next_season,
      season_year = next_season_year,
      hourly_rate = next_hourly_rate,
      "updatedDT" = now()
  WHERE id = p_price_id
    AND "Deleted" = 0
  RETURNING * INTO price;

  RETURN public.admin_team_season_price_json(price);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_team_season_price(p_price_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  price public.team_season_prices%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  UPDATE public.team_season_prices
  SET "Deleted" = 1,
      "updatedDT" = now()
  WHERE id = p_price_id
    AND "Deleted" = 0
  RETURNING * INTO price;

  IF price.id IS NULL THEN
    RAISE EXCEPTION 'Season price not found' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_team_season_price_json(price);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_update_team_season_price(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_team_season_price(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_update_team_season_price(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_team_season_price(uuid) TO authenticated;
