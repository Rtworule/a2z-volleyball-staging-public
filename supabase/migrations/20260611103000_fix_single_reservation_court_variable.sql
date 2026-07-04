CREATE OR REPLACE FUNCTION public.admin_create_single_reservation(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.admin_subjects%ROWTYPE;
  subject_base public.subjects%ROWTYPE;
  client_type public.client_types%ROWTYPE;
  subject_team public.subject_teams%ROWTYPE;
  season_price public.team_season_prices%ROWTYPE;
  config public.facility_config%ROWTYPE;
  local_date date := (payload->>'startDate')::date;
  slot_start_time time := (payload->>'startTime')::time;
  duration_minutes integer := coalesce((payload->>'durationMinutes')::integer, 60);
  resource text := coalesce(payload->>'resourceType', 'court');
  v_court_number integer := nullif(replace(coalesce(payload->>'courtId', ''), 'court-', ''), '')::integer;
  slot_start_at timestamptz;
  slot_end_at timestamptz;
  selected_rate numeric(8, 2);
  selected_label text;
  reservation public.reservations%ROWTYPE;
BEGIN
  IF resource NOT IN ('court', 'trainer') THEN
    RAISE EXCEPTION 'resourceType must be court or trainer' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO subject
  FROM public.admin_subjects
  WHERE id = nullif(payload->>'subjectId', '')::uuid
    AND "Deleted" = 0;

  SELECT * INTO subject_base FROM public.subjects WHERE id = subject.id;
  SELECT * INTO client_type FROM public.client_types WHERE id = subject_base.client_type_id;

  IF subject.id IS NULL OR subject_base.disabled_at IS NOT NULL THEN
    RAISE EXCEPTION 'Active client record not found' USING ERRCODE = '22023';
  END IF;

  IF coalesce(client_type.have_teams, false) THEN
    SELECT * INTO subject_team
    FROM public.subject_teams
    WHERE id = nullif(payload->>'subjectTeamId', '')::uuid
      AND subject_id = subject.id
      AND "Deleted" = 0;

    IF subject_team.id IS NULL THEN
      RAISE EXCEPTION 'Select a team for this client before creating reservations' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT * INTO config FROM public.facility_config WHERE id = true;

  slot_start_at := ((local_date::text || ' ' || slot_start_time::text)::timestamp AT TIME ZONE config.timezone);
  slot_end_at := slot_start_at + make_interval(mins => duration_minutes);

  IF slot_start_time < (SELECT open_time FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer)
    OR (slot_start_time + make_interval(mins => duration_minutes))::time > (SELECT close_time FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer)
    OR coalesce((SELECT is_closed FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer), true) THEN
    RAISE EXCEPTION 'Reservation is outside business hours' USING ERRCODE = '22023';
  END IF;

  IF NOT coalesce((payload->>'allowClosedDay')::boolean, false)
    AND EXISTS (
      SELECT 1 FROM public.closures closure
      WHERE closure."Deleted" = 0
        AND closure.start_at < slot_end_at
        AND slot_start_at < closure.end_at
        AND (closure.resource_type = 'all' OR closure.resource_type = resource)
        AND (resource <> 'court' OR closure.court_number IS NULL OR closure.court_number = v_court_number)
    ) THEN
    RAISE EXCEPTION 'Reservation is on a closed day' USING ERRCODE = '22023';
  END IF;

  IF resource = 'court' AND EXISTS (
    SELECT 1 FROM public.reservations existing
    WHERE existing."Deleted" = 0
      AND existing.status <> 'cancelled'
      AND existing.resource_type = 'court'
      AND existing.court_number = v_court_number
      AND existing.start_at < slot_end_at
      AND slot_start_at < existing.end_at
  ) THEN
    RAISE EXCEPTION 'Court is already reserved' USING ERRCODE = '23505';
  END IF;

  IF resource = 'court' AND EXISTS (
    SELECT 1 FROM public.fixed_reservations fixed
    WHERE fixed."Deleted" = 0
      AND fixed.resource_type = 'court'
      AND fixed.court_number = v_court_number
      AND extract(dow FROM local_date)::integer = ANY(fixed.days_of_week)
      AND local_date BETWEEN fixed.start_date AND fixed.end_date
      AND fixed.start_time < (slot_start_time + make_interval(mins => duration_minutes))::time
      AND slot_start_time < fixed.end_time
  ) THEN
    RAISE EXCEPTION 'Court is already reserved' USING ERRCODE = '23505';
  END IF;

  IF nullif(payload->>'seasonPriceId', '') IS NOT NULL THEN
    SELECT * INTO season_price
    FROM public.team_season_prices
    WHERE id = nullif(payload->>'seasonPriceId', '')::uuid
      AND subject_id = subject.id
      AND "Deleted" = 0;
  END IF;

  selected_rate := coalesce(season_price.hourly_rate, nullif(payload->>'hourlyRate', '')::numeric, CASE WHEN resource = 'trainer' THEN config.gym_hourly_rate ELSE config.court_hourly_rate END);
  selected_label := coalesce(nullif(payload->>'seasonLabel', ''), CASE WHEN season_price.id IS NULL THEN NULL ELSE season_price.season || ' ' || season_price.season_year END);

  INSERT INTO public.reservations (
    user_id, team_name, subject_id, subject_team_id, resource_type, court_number, start_at, end_at, status, payment_status, season_price_id, season_label, hourly_rate, amount, created_by, reservation_source
  ) VALUES (
    NULL,
    coalesce(subject_team.name, subject.display_name),
    subject.id,
    subject_team.id,
    resource,
    CASE WHEN resource = 'court' THEN v_court_number ELSE NULL END,
    slot_start_at,
    slot_end_at,
    'confirmed',
    coalesce(nullif(payload->>'paymentStatus', ''), 'due'),
    season_price.id,
    selected_label,
    selected_rate,
    round(selected_rate * duration_minutes / 60.0, 2),
    actor_id,
    coalesce(nullif(payload->>'source', ''), 'calendar')
  )
  RETURNING * INTO reservation;

  PERFORM public.audit_log('create', 'reservation', reservation.id, reservation.team_name, NULL, public.admin_reservation_json(reservation), jsonb_build_object('source', 'calendar', 'allowClosedDay', coalesce((payload->>'allowClosedDay')::boolean, false)));

  RETURN public.admin_reservation_json(reservation);
END;
$$;
