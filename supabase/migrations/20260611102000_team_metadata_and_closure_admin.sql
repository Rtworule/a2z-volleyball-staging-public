ALTER TABLE public.subject_teams
  ADD COLUMN IF NOT EXISTS coach_name text,
  ADD COLUMN IF NOT EXISTS coach_email text,
  ADD COLUMN IF NOT EXISTS coach_phone text,
  ADD COLUMN IF NOT EXISTS coach_safe_sport boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS coach_background_check boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS coach_concussion boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS club_insurance_received boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.admin_subject_team_json(team public.subject_teams)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', team.id,
    'subjectId', team.subject_id,
    'name', team.name,
    'shortName', team.short_name,
    'coachName', coalesce(team.coach_name, ''),
    'coachEmail', coalesce(team.coach_email, ''),
    'coachPhone', coalesce(team.coach_phone, ''),
    'coachSafeSport', coalesce(team.coach_safe_sport, false),
    'coachBackgroundCheck', coalesce(team.coach_background_check, false),
    'coachConcussion', coalesce(team.coach_concussion, false),
    'clubInsuranceReceived', coalesce(team.club_insurance_received, false),
    'deleted', team."Deleted" = 1,
    'createdDT', team."createdDT",
    'updatedDT', team."updatedDT"
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_create_subject_team(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  team public.subject_teams%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  INSERT INTO public.subject_teams (
    subject_id,
    name,
    short_name,
    coach_name,
    coach_email,
    coach_phone,
    coach_safe_sport,
    coach_background_check,
    coach_concussion,
    club_insurance_received
  ) VALUES (
    nullif(payload->>'subjectId', '')::uuid,
    trim(payload->>'name'),
    coalesce(nullif(trim(payload->>'shortName'), ''), left(trim(payload->>'name'), 24)),
    nullif(trim(payload->>'coachName'), ''),
    nullif(trim(payload->>'coachEmail'), ''),
    nullif(trim(payload->>'coachPhone'), ''),
    coalesce((payload->>'coachSafeSport')::boolean, false),
    coalesce((payload->>'coachBackgroundCheck')::boolean, false),
    coalesce((payload->>'coachConcussion')::boolean, false),
    coalesce((payload->>'clubInsuranceReceived')::boolean, false)
  )
  RETURNING * INTO team;

  PERFORM public.audit_log('create', 'client_team', team.id, team.name, NULL, to_jsonb(team));

  RETURN public.admin_subject_team_json(team);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_subject_team(p_team_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  before_row public.subject_teams%ROWTYPE;
  team public.subject_teams%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT * INTO before_row FROM public.subject_teams WHERE id = p_team_id AND "Deleted" = 0;

  UPDATE public.subject_teams
  SET name = coalesce(nullif(trim(payload->>'name'), ''), name),
      short_name = coalesce(nullif(trim(payload->>'shortName'), ''), short_name),
      coach_name = nullif(trim(payload->>'coachName'), ''),
      coach_email = nullif(trim(payload->>'coachEmail'), ''),
      coach_phone = nullif(trim(payload->>'coachPhone'), ''),
      coach_safe_sport = coalesce((payload->>'coachSafeSport')::boolean, coach_safe_sport),
      coach_background_check = coalesce((payload->>'coachBackgroundCheck')::boolean, coach_background_check),
      coach_concussion = coalesce((payload->>'coachConcussion')::boolean, coach_concussion),
      club_insurance_received = coalesce((payload->>'clubInsuranceReceived')::boolean, club_insurance_received),
      "updatedDT" = now()
  WHERE id = p_team_id
    AND "Deleted" = 0
  RETURNING * INTO team;

  IF team.id IS NULL THEN
    RAISE EXCEPTION 'Team not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('update', 'client_team', team.id, team.name, to_jsonb(before_row), to_jsonb(team));

  RETURN public.admin_subject_team_json(team);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_closure(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  closure public.closures%ROWTYPE;
  resource text := coalesce(nullif(payload->>'resourceType', ''), 'all');
  court integer := nullif(replace(coalesce(payload->>'courtId', ''), 'court-', ''), '')::integer;
  start_at timestamptz;
  end_at timestamptz;
BEGIN
  PERFORM public.admin_require_approved();

  IF resource NOT IN ('all', 'court', 'trainer') THEN
    RAISE EXCEPTION 'resourceType must be all, court, or trainer' USING ERRCODE = '22023';
  END IF;

  IF resource <> 'court' THEN
    court := NULL;
  END IF;

  start_at := ((payload->>'startDate')::date::text || ' ' || coalesce(nullif(payload->>'startTime', ''), '00:00'))::timestamp AT TIME ZONE 'America/New_York';
  end_at := ((coalesce(nullif(payload->>'endDate', ''), payload->>'startDate'))::date::text || ' ' || coalesce(nullif(payload->>'endTime', ''), '23:59'))::timestamp AT TIME ZONE 'America/New_York';

  IF end_at <= start_at THEN
    RAISE EXCEPTION 'Closed day end must be after start' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.closures (resource_type, court_number, start_at, end_at, reason)
  VALUES (
    resource,
    court,
    start_at,
    end_at,
    coalesce(nullif(trim(payload->>'reason'), ''), 'Closed')
  )
  RETURNING * INTO closure;

  PERFORM public.audit_log('create', 'closure', closure.id, closure.reason, NULL, to_jsonb(closure));

  RETURN jsonb_build_object(
    'id', closure.id,
    'resourceType', closure.resource_type,
    'courtId', CASE WHEN closure.court_number IS NULL THEN NULL ELSE 'court-' || closure.court_number END,
    'start', closure.start_at,
    'end', closure.end_at,
    'reason', closure.reason
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_closure(p_closure_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  closure public.closures%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  UPDATE public.closures
  SET "Deleted" = 1,
      "updatedDT" = now()
  WHERE id = p_closure_id
    AND "Deleted" = 0
  RETURNING * INTO closure;

  IF closure.id IS NULL THEN
    RAISE EXCEPTION 'Closed day not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('delete', 'closure', closure.id, closure.reason, to_jsonb(closure), NULL);

  RETURN jsonb_build_object('id', closure.id, 'deleted', true);
END;
$$;

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
  court_number integer := nullif(replace(coalesce(payload->>'courtId', ''), 'court-', ''), '')::integer;
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
        AND (resource <> 'court' OR closure.court_number IS NULL OR closure.court_number = court_number)
    ) THEN
    RAISE EXCEPTION 'Reservation is on a closed day' USING ERRCODE = '22023';
  END IF;

  IF resource = 'court' AND EXISTS (
    SELECT 1 FROM public.reservations existing
    WHERE existing."Deleted" = 0
      AND existing.status <> 'cancelled'
      AND existing.resource_type = 'court'
      AND existing.court_number = court_number
      AND existing.start_at < slot_end_at
      AND slot_start_at < existing.end_at
  ) THEN
    RAISE EXCEPTION 'Court is already reserved' USING ERRCODE = '23505';
  END IF;

  IF resource = 'court' AND EXISTS (
    SELECT 1 FROM public.fixed_reservations fixed
    WHERE fixed."Deleted" = 0
      AND fixed.resource_type = 'court'
      AND fixed.court_number = court_number
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
    CASE WHEN resource = 'court' THEN court_number ELSE NULL END,
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

REVOKE EXECUTE ON FUNCTION public.admin_create_closure(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_closure(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_create_single_reservation(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_create_closure(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_closure(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_single_reservation(jsonb) TO authenticated;
