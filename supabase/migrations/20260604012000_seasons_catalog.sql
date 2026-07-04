CREATE OR REPLACE FUNCTION public.season_display_name(p_start_year integer)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT p_start_year::text || '/' || lpad(((p_start_year + 1) % 100)::text, 2, '0');
$$;

CREATE TABLE IF NOT EXISTS public.seasons (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  start_year integer NOT NULL CHECK (start_year BETWEEN 2000 AND 2100),
  display_name text NOT NULL,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS seasons_unique_active_start_year_idx
  ON public.seasons(start_year)
  WHERE "Deleted" = 0;

ALTER TABLE public.seasons ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read active seasons" ON public.seasons;
DROP POLICY IF EXISTS "Admins insert seasons" ON public.seasons;
DROP POLICY IF EXISTS "Admins update seasons" ON public.seasons;

CREATE POLICY "Admins read active seasons"
  ON public.seasons FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert seasons"
  ON public.seasons FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update seasons"
  ON public.seasons FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

INSERT INTO public.seasons (start_year, display_name)
SELECT 2026, public.season_display_name(2026)
WHERE NOT EXISTS (
  SELECT 1 FROM public.seasons season
  WHERE season.start_year = 2026
    AND season."Deleted" = 0
);

INSERT INTO public.seasons (start_year, display_name)
SELECT DISTINCT price.season_year, public.season_display_name(price.season_year)
FROM public.team_season_prices price
WHERE price."Deleted" = 0
  AND NOT EXISTS (
    SELECT 1 FROM public.seasons season
    WHERE season.start_year = price.season_year
      AND season."Deleted" = 0
  );

ALTER TABLE public.team_season_prices
  ADD COLUMN IF NOT EXISTS season_id uuid REFERENCES public.seasons(id);

UPDATE public.team_season_prices price
SET season_id = season.id,
    season = season.display_name,
    "updatedDT" = now()
FROM public.seasons season
WHERE price.season_id IS NULL
  AND price.season_year = season.start_year
  AND price."Deleted" = 0
  AND season."Deleted" = 0;

CREATE INDEX IF NOT EXISTS team_season_prices_season_id_idx
  ON public.team_season_prices(season_id)
  WHERE "Deleted" = 0;

CREATE OR REPLACE FUNCTION public.admin_season_json(season public.seasons)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', season.id,
    'startYear', season.start_year,
    'displayName', season.display_name,
    'deleted', season."Deleted" = 1,
    'createdDT', season."createdDT",
    'updatedDT', season."updatedDT"
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_team_season_price_json(price public.team_season_prices)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', price.id,
    'subjectId', price.subject_id,
    'teamName', subject.display_name,
    'seasonId', season.id,
    'season', coalesce(season.display_name, price.season),
    'seasonDisplayName', coalesce(season.display_name, price.season),
    'seasonYear', coalesce(season.start_year, price.season_year),
    'hourlyRate', price.hourly_rate,
    'deleted', price."Deleted" = 1,
    'createdDT', price."createdDT",
    'updatedDT', price."updatedDT"
  )
  FROM public.admin_subjects subject
  LEFT JOIN public.seasons season
    ON season.id = price.season_id
  WHERE subject.id = price.subject_id;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_season(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  season public.seasons%ROWTYPE;
  next_start_year integer := (payload->>'startYear')::integer;
  next_display_name text := coalesce(nullif(trim(payload->>'displayName'), ''), public.season_display_name((payload->>'startYear')::integer));
BEGIN
  PERFORM public.admin_require_approved();

  IF next_start_year NOT BETWEEN 2000 AND 2100 THEN
    RAISE EXCEPTION 'Season year must be between 2000 and 2100' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.seasons (start_year, display_name)
  VALUES (next_start_year, next_display_name)
  RETURNING * INTO season;

  RETURN public.admin_season_json(season);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_season(p_season_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  season public.seasons%ROWTYPE;
  next_start_year integer;
  next_display_name text;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT *
  INTO season
  FROM public.seasons
  WHERE id = p_season_id
    AND "Deleted" = 0;

  IF season.id IS NULL THEN
    RAISE EXCEPTION 'Season not found' USING ERRCODE = '22023';
  END IF;

  next_start_year := coalesce(nullif(payload->>'startYear', '')::integer, season.start_year);
  next_display_name := coalesce(nullif(trim(payload->>'displayName'), ''), public.season_display_name(next_start_year));

  IF next_start_year NOT BETWEEN 2000 AND 2100 THEN
    RAISE EXCEPTION 'Season year must be between 2000 and 2100' USING ERRCODE = '22023';
  END IF;

  UPDATE public.seasons
  SET start_year = next_start_year,
      display_name = next_display_name,
      "updatedDT" = now()
  WHERE id = p_season_id
    AND "Deleted" = 0
  RETURNING * INTO season;

  UPDATE public.team_season_prices
  SET season = season.display_name,
      season_year = season.start_year,
      "updatedDT" = now()
  WHERE season_id = season.id
    AND "Deleted" = 0;

  RETURN public.admin_season_json(season);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_season(p_season_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  season public.seasons%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  IF EXISTS (
    SELECT 1
    FROM public.team_season_prices price
    WHERE price.season_id = p_season_id
      AND price."Deleted" = 0
  ) THEN
    RAISE EXCEPTION 'Season is used by team pricing' USING ERRCODE = '22023';
  END IF;

  UPDATE public.seasons
  SET "Deleted" = 1,
      "updatedDT" = now()
  WHERE id = p_season_id
    AND "Deleted" = 0
  RETURNING * INTO season;

  IF season.id IS NULL THEN
    RAISE EXCEPTION 'Season not found' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_season_json(season);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_team_season_price(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.admin_subjects%ROWTYPE;
  season public.seasons%ROWTYPE;
  price public.team_season_prices%ROWTYPE;
BEGIN
  SELECT *
  INTO subject
  FROM public.admin_subjects
  WHERE id = (payload->>'subjectId')::uuid
    AND subject_type = 'team'
    AND "Deleted" = 0;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Team record not found' USING ERRCODE = '22023';
  END IF;

  SELECT *
  INTO season
  FROM public.seasons
  WHERE id = (payload->>'seasonId')::uuid
    AND "Deleted" = 0;

  IF season.id IS NULL THEN
    RAISE EXCEPTION 'Season record not found' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.team_season_prices (
    subject_id, season_id, season, season_year, hourly_rate, created_by
  ) VALUES (
    subject.id,
    season.id,
    season.display_name,
    season.start_year,
    (payload->>'hourlyRate')::numeric,
    actor_id
  )
  RETURNING * INTO price;

  RETURN public.admin_team_season_price_json(price);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_team_season_price(p_price_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  subject public.admin_subjects%ROWTYPE;
  season public.seasons%ROWTYPE;
  price public.team_season_prices%ROWTYPE;
  next_subject_id uuid;
  next_season_id uuid;
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
  next_season_id := coalesce(nullif(payload->>'seasonId', '')::uuid, price.season_id);
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

  SELECT *
  INTO season
  FROM public.seasons
  WHERE id = next_season_id
    AND "Deleted" = 0;

  IF season.id IS NULL THEN
    RAISE EXCEPTION 'Season record not found' USING ERRCODE = '22023';
  END IF;

  IF next_hourly_rate < 0 THEN
    RAISE EXCEPTION 'Hourly rate must be zero or greater' USING ERRCODE = '22023';
  END IF;

  UPDATE public.team_season_prices
  SET subject_id = subject.id,
      season_id = season.id,
      season = season.display_name,
      season_year = season.start_year,
      hourly_rate = next_hourly_rate,
      "updatedDT" = now()
  WHERE id = p_price_id
    AND "Deleted" = 0
  RETURNING * INTO price;

  RETURN public.admin_team_season_price_json(price);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_get_dashboard()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  config_row public.facility_config%ROWTYPE;
  settings_json jsonb;
  users_json jsonb;
  pending_json jsonb;
  bookings_json jsonb;
  subjects_json jsonb;
  seasons_json jsonb;
  season_prices_json jsonb;
  operations_json jsonb;
BEGIN
  SELECT * INTO config_row FROM public.facility_config WHERE id = true;

  SELECT jsonb_build_object(
    'courtCount', config_row.court_count,
    'trainerCapacity', config_row.trainer_capacity,
    'slotIntervalMinutes', config_row.reservation_step_minutes,
    'minBookingMinutes', config_row.min_reservation_minutes,
    'pricing', jsonb_build_object(
      'courtHourlyRate', config_row.court_hourly_rate,
      'gymHourlyRate', config_row.gym_hourly_rate
    ),
    'operatingHours', coalesce((
      SELECT jsonb_object_agg(
        hours.day_of_week::text,
        jsonb_build_object('open', to_char(hours.open_time, 'HH24:MI'), 'close', to_char(hours.close_time, 'HH24:MI'), 'closed', hours.is_closed)
      )
      FROM public.operating_hours hours
    ), '{}'::jsonb),
    'closures', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', closure.id,
        'resourceType', closure.resource_type,
        'courtId', CASE WHEN closure.court_number IS NULL THEN NULL ELSE 'court-' || closure.court_number END,
        'start', closure.start_at,
        'end', closure.end_at,
        'reason', closure.reason
      ) ORDER BY closure.start_at)
      FROM public.closures closure
      WHERE closure."Deleted" = 0
    ), '[]'::jsonb),
    'fixedReservations', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', fixed.id,
        'resourceType', fixed.resource_type,
        'courtId', CASE WHEN fixed.court_number IS NULL THEN NULL ELSE 'court-' || fixed.court_number END,
        'daysOfWeek', fixed.days_of_week,
        'startDate', fixed.start_date,
        'endDate', fixed.end_date,
        'startTime', to_char(fixed.start_time, 'HH24:MI'),
        'endTime', to_char(fixed.end_time, 'HH24:MI'),
        'capacity', fixed.capacity
      ) ORDER BY fixed.start_date, fixed.start_time)
      FROM public.fixed_reservations fixed
      WHERE fixed."Deleted" = 0
    ), '[]'::jsonb)
  ) INTO settings_json;

  SELECT coalesce(jsonb_agg(public.admin_profile_json(profile) ORDER BY profile.approval_status, profile."createdDT"), '[]'::jsonb)
  INTO users_json
  FROM public.profiles profile
  WHERE profile."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_profile_json(profile) ORDER BY profile."createdDT"), '[]'::jsonb)
  INTO pending_json
  FROM public.profiles profile
  WHERE profile.approval_status = 'pending'
    AND profile."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at), '[]'::jsonb)
  INTO bookings_json
  FROM public.reservations reservation
  WHERE reservation."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_subject_json(subject) ORDER BY subject.display_name), '[]'::jsonb)
  INTO subjects_json
  FROM public.admin_subjects subject
  WHERE subject."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_season_json(season) ORDER BY season.start_year DESC), '[]'::jsonb)
  INTO seasons_json
  FROM public.seasons season
  WHERE season."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_team_season_price_json(price) ORDER BY price.season_year DESC, price.season, price."createdDT"), '[]'::jsonb)
  INTO season_prices_json
  FROM public.team_season_prices price
  WHERE price."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_bulk_operation_json(operation) ORDER BY operation."createdDT"), '[]'::jsonb)
  INTO operations_json
  FROM public.admin_bulk_operations operation
  WHERE operation."Deleted" = 0;

  RETURN jsonb_build_object(
    'settings', settings_json,
    'users', users_json,
    'pendingUsers', pending_json,
    'bookings', bookings_json,
    'adminSubjects', subjects_json,
    'seasons', seasons_json,
    'teamSeasonPrices', season_prices_json,
    'bulkOperations', operations_json,
    'actorId', actor_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.season_display_name(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_season_json(public.seasons) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_create_season(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_update_season(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_season(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_create_season(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_season(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_season(uuid) TO authenticated;
