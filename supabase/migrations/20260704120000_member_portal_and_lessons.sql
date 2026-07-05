-- Member portal: anonymized availability, member booking with validation,
-- private-lesson player brackets, and trainer-capacity fix for single admin reservations.
-- Additive only. No existing tables/rows are altered destructively.

-- 1) Private lesson player bracket -------------------------------------------------
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS lesson_player_bracket text
    CHECK (lesson_player_bracket IS NULL OR lesson_player_bracket IN ('1-2', '3', '4', '5+'));

COMMENT ON COLUMN public.reservations.lesson_player_bracket IS
  'Player-count bracket for coach private lessons. Null for club/team reservations. Admins may update after the lesson.';

-- 2) Helper: require an approved non-admin member ----------------------------------
CREATE OR REPLACE FUNCTION public.member_require_approved()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := auth.uid();
BEGIN
  IF caller IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = caller
      AND approval_status = 'approved'
      AND "Deleted" = 0
  ) THEN
    RAISE EXCEPTION 'Approved account required' USING ERRCODE = '42501';
  END IF;
  RETURN caller;
END;
$$;

-- 3) Member portal payload ----------------------------------------------------------
-- Returns facility settings, anonymized busy blocks for a date window,
-- the caller's booking contexts (memberships), and the caller's own reservations.
-- Names are exposed only for the caller's own reservations or reservations that
-- belong to a client the caller is an active member of.
CREATE OR REPLACE FUNCTION public.member_get_portal(
  p_start_date date DEFAULT current_date,
  p_days integer DEFAULT 14
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.member_require_approved();
  config public.facility_config%ROWTYPE;
  window_days integer := least(greatest(coalesce(p_days, 14), 1), 31);
  window_start timestamptz;
  window_end timestamptz;
BEGIN
  SELECT * INTO config FROM public.facility_config WHERE id = true;
  window_start := (p_start_date::text || ' 00:00')::timestamp AT TIME ZONE config.timezone;
  window_end := window_start + make_interval(days => window_days);

  RETURN jsonb_build_object(
    'settings', jsonb_build_object(
      'courtCount', config.court_count,
      'trainerCapacity', config.trainer_capacity,
      'courtHourlyRate', config.court_hourly_rate,
      'gymHourlyRate', config.gym_hourly_rate,
      'minReservationMinutes', config.min_reservation_minutes,
      'reservationStepMinutes', config.reservation_step_minutes,
      'timezone', config.timezone
    ),
    'operatingHours', coalesce((
      SELECT jsonb_object_agg(day_of_week::text, jsonb_build_object(
        'open', to_char(open_time, 'HH24:MI'),
        'close', to_char(close_time, 'HH24:MI'),
        'closed', is_closed
      ))
      FROM public.operating_hours
    ), '{}'::jsonb),
    'closures', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'resourceType', c.resource_type,
        'courtNumber', c.court_number,
        'start', c.start_at,
        'end', c.end_at,
        'reason', c.reason
      ) ORDER BY c.start_at)
      FROM public.closures c
      WHERE c."Deleted" = 0 AND c.start_at < window_end AND window_start < c.end_at
    ), '[]'::jsonb),
    'fixedReservations', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'resourceType', f.resource_type,
        'courtNumber', f.court_number,
        'daysOfWeek', f.days_of_week,
        'startDate', f.start_date,
        'endDate', f.end_date,
        'startTime', to_char(f.start_time, 'HH24:MI'),
        'endTime', to_char(f.end_time, 'HH24:MI')
      ))
      FROM public.fixed_reservations f
      WHERE f."Deleted" = 0 AND f.start_date <= (p_start_date + window_days) AND f.end_date >= p_start_date
    ), '[]'::jsonb),
    'busy', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', r.id,
        'resourceType', r.resource_type,
        'courtNumber', r.court_number,
        'start', r.start_at,
        'end', r.end_at,
        'mine', r.user_id = caller,
        'label', CASE
          WHEN r.user_id = caller THEN coalesce(r.team_name, 'My reservation')
          WHEN r.subject_id IS NOT NULL AND EXISTS (
            SELECT 1 FROM public.subject_memberships m
            WHERE m.subject_id = r.subject_id
              AND m.profile_id = caller
              AND m.status = 'active'
              AND m."Deleted" = 0
          ) THEN coalesce(r.team_name, 'Club reservation')
          ELSE NULL
        END
      ) ORDER BY r.start_at)
      FROM public.reservations r
      WHERE r."Deleted" = 0
        AND r.status <> 'cancelled'
        AND r.start_at < window_end
        AND window_start < r.end_at
    ), '[]'::jsonb),
    'contexts', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'subjectId', s.id,
        'displayName', s.display_name,
        'clientType', ct.name,
        'haveTeams', coalesce(ct.have_teams, false),
        'isCoach', lower(coalesce(ct.name, '')) = 'coach',
        'canBook', m.can_book,
        'teams', coalesce((
          SELECT jsonb_agg(jsonb_build_object('id', t.id, 'name', t.name) ORDER BY t.name)
          FROM public.subject_teams t
          WHERE t.subject_id = s.id AND t."Deleted" = 0
        ), '[]'::jsonb)
      ) ORDER BY s.display_name)
      FROM public.subject_memberships m
      JOIN public.subjects s ON s.id = m.subject_id AND s."Deleted" = 0 AND s.disabled_at IS NULL
      LEFT JOIN public.client_types ct ON ct.id = s.client_type_id
      WHERE m.profile_id = caller
        AND m.status = 'active'
        AND m.can_book
        AND m."Deleted" = 0
    ), '[]'::jsonb),
    'myReservations', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', r.id,
        'resourceType', r.resource_type,
        'courtNumber', r.court_number,
        'start', r.start_at,
        'end', r.end_at,
        'status', r.status,
        'paymentStatus', r.payment_status,
        'teamName', r.team_name,
        'lessonPlayerBracket', r.lesson_player_bracket,
        'hourlyRate', r.hourly_rate,
        'amount', r.amount
      ) ORDER BY r.start_at)
      FROM public.reservations r
      WHERE r."Deleted" = 0
        AND r.user_id = caller
        AND r.end_at >= now() - interval '30 days'
    ), '[]'::jsonb)
  );
END;
$$;

-- 4) Member reservation creation ----------------------------------------------------
-- payload: { bookingType: 'club'|'private', subjectId, subjectTeamId?, resourceType: 'court'|'trainer',
--            courtId?, startDate, startTime, durationMinutes, lessonPlayerBracket? }
CREATE OR REPLACE FUNCTION public.member_create_reservation(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.member_require_approved();
  booking_type text := coalesce(payload->>'bookingType', 'private');
  resource text := coalesce(payload->>'resourceType', 'court');
  v_subject_id uuid := nullif(payload->>'subjectId', '')::uuid;
  v_team_id uuid := nullif(payload->>'subjectTeamId', '')::uuid;
  v_bracket text := nullif(payload->>'lessonPlayerBracket', '');
  subject public.subjects%ROWTYPE;
  client_type public.client_types%ROWTYPE;
  subject_team public.subject_teams%ROWTYPE;
  season_price public.team_season_prices%ROWTYPE;
  config public.facility_config%ROWTYPE;
  local_date date := (payload->>'startDate')::date;
  slot_start_time time := (payload->>'startTime')::time;
  duration_minutes integer := coalesce((payload->>'durationMinutes')::integer, 60);
  v_court_number integer := nullif(replace(coalesce(payload->>'courtId', ''), 'court-', ''), '')::integer;
  slot_start_at timestamptz;
  slot_end_at timestamptz;
  trainer_usage integer;
  selected_rate numeric(8, 2);
  selected_label text;
  reservation public.reservations%ROWTYPE;
BEGIN
  IF booking_type NOT IN ('club', 'private') THEN
    RAISE EXCEPTION 'bookingType must be club or private' USING ERRCODE = '22023';
  END IF;
  IF resource NOT IN ('court', 'trainer') THEN
    RAISE EXCEPTION 'resourceType must be court or trainer' USING ERRCODE = '22023';
  END IF;
  IF resource = 'court' AND (v_court_number IS NULL OR v_court_number NOT BETWEEN 1 AND 9) THEN
    RAISE EXCEPTION 'Select a court between 1 and 9' USING ERRCODE = '22023';
  END IF;
  IF booking_type = 'private' AND v_bracket IS NULL THEN
    RAISE EXCEPTION 'Select the number of players for a private lesson' USING ERRCODE = '22023';
  END IF;
  IF booking_type = 'private' AND v_bracket NOT IN ('1-2', '3', '4', '5+') THEN
    RAISE EXCEPTION 'Player count must be 1-2, 3, 4, or 5+' USING ERRCODE = '22023';
  END IF;
  IF local_date IS NULL OR slot_start_time IS NULL THEN
    RAISE EXCEPTION 'Reservation date and start time are required' USING ERRCODE = '22023';
  END IF;
  IF local_date < current_date THEN
    RAISE EXCEPTION 'Reservations cannot be created in the past' USING ERRCODE = '22023';
  END IF;

  -- Authorize the booking context: caller must hold an active, can_book membership.
  SELECT s.* INTO subject
  FROM public.subjects s
  JOIN public.subject_memberships m
    ON m.subject_id = s.id
   AND m.profile_id = caller
   AND m.status = 'active'
   AND m.can_book
   AND m."Deleted" = 0
  WHERE s.id = v_subject_id
    AND s."Deleted" = 0
    AND s.disabled_at IS NULL;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'You are not authorized to reserve for this client' USING ERRCODE = '42501';
  END IF;

  SELECT * INTO client_type FROM public.client_types WHERE id = subject.client_type_id;

  IF booking_type = 'club' THEN
    IF coalesce(client_type.have_teams, false) THEN
      SELECT * INTO subject_team
      FROM public.subject_teams
      WHERE id = v_team_id AND subject_id = subject.id AND "Deleted" = 0;
      IF subject_team.id IS NULL THEN
        RAISE EXCEPTION 'Select a team for this club' USING ERRCODE = '22023';
      END IF;
    END IF;
    v_bracket := NULL;
  ELSE
    -- Private lessons never carry a team.
    v_team_id := NULL;
    subject_team := NULL;
  END IF;

  SELECT * INTO config FROM public.facility_config WHERE id = true;
  slot_start_at := ((local_date::text || ' ' || slot_start_time::text)::timestamp AT TIME ZONE config.timezone);
  slot_end_at := slot_start_at + make_interval(mins => duration_minutes);

  IF duration_minutes < config.min_reservation_minutes OR duration_minutes % config.reservation_step_minutes <> 0 THEN
    RAISE EXCEPTION 'Reservations must be at least 1 hour in 30-minute steps' USING ERRCODE = '22023';
  END IF;

  IF slot_start_time < (SELECT open_time FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer)
    OR (slot_start_time + make_interval(mins => duration_minutes))::time > (SELECT close_time FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer)
    OR coalesce((SELECT is_closed FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer), true) THEN
    RAISE EXCEPTION 'Reservation is outside business hours' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.closures closure
    WHERE closure."Deleted" = 0
      AND closure.start_at < slot_end_at
      AND slot_start_at < closure.end_at
      AND (closure.resource_type = 'all' OR closure.resource_type = resource)
      AND (resource <> 'court' OR closure.court_number IS NULL OR closure.court_number = v_court_number)
  ) THEN
    RAISE EXCEPTION 'The facility is closed during that time' USING ERRCODE = '22023';
  END IF;

  IF resource = 'court' THEN
    PERFORM pg_advisory_xact_lock(hashtext('a2z-court-' || v_court_number::text));
    IF EXISTS (
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
    IF EXISTS (
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
  ELSE
    PERFORM pg_advisory_xact_lock(hashtext('a2z-trainer'));
    SELECT count(*) INTO trainer_usage
    FROM public.reservations existing
    WHERE existing."Deleted" = 0
      AND existing.status <> 'cancelled'
      AND existing.resource_type = 'trainer'
      AND existing.start_at < slot_end_at
      AND slot_start_at < existing.end_at;
    IF trainer_usage >= config.trainer_capacity THEN
      RAISE EXCEPTION 'Trainer gym is fully booked for that time' USING ERRCODE = '23505';
    END IF;
  END IF;

  -- Pricing: newest season price for the subject, else facility default rate.
  SELECT * INTO season_price
  FROM public.team_season_prices
  WHERE subject_id = subject.id AND "Deleted" = 0
  ORDER BY season_year DESC, created_at DESC
  LIMIT 1;

  selected_rate := coalesce(season_price.hourly_rate, CASE WHEN resource = 'trainer' THEN config.gym_hourly_rate ELSE config.court_hourly_rate END);
  selected_label := CASE WHEN season_price.id IS NULL THEN NULL ELSE season_price.season || ' ' || season_price.season_year END;

  INSERT INTO public.reservations (
    user_id, team_name, subject_id, subject_team_id, resource_type, court_number,
    start_at, end_at, status, payment_status, season_price_id, season_label,
    hourly_rate, amount, lesson_player_bracket, created_by, reservation_source
  ) VALUES (
    caller,
    CASE WHEN booking_type = 'private'
      THEN subject.display_name || ' (private lesson)'
      ELSE coalesce(subject_team.name, subject.display_name)
    END,
    subject.id,
    subject_team.id,
    resource,
    CASE WHEN resource = 'court' THEN v_court_number ELSE NULL END,
    slot_start_at,
    slot_end_at,
    'confirmed',
    'due',
    season_price.id,
    selected_label,
    selected_rate,
    round(selected_rate * duration_minutes / 60.0, 2),
    v_bracket,
    caller,
    'booking'
  )
  RETURNING * INTO reservation;

  PERFORM public.audit_log('create', 'reservation', reservation.id, reservation.team_name, NULL,
    jsonb_build_object('id', reservation.id, 'start', reservation.start_at, 'end', reservation.end_at,
      'resourceType', reservation.resource_type, 'courtNumber', reservation.court_number,
      'bookingType', booking_type, 'lessonPlayerBracket', reservation.lesson_player_bracket),
    jsonb_build_object('source', 'member-booking'));

  RETURN jsonb_build_object(
    'id', reservation.id,
    'start', reservation.start_at,
    'end', reservation.end_at,
    'resourceType', reservation.resource_type,
    'courtNumber', reservation.court_number,
    'teamName', reservation.team_name,
    'lessonPlayerBracket', reservation.lesson_player_bracket,
    'hourlyRate', reservation.hourly_rate,
    'amount', reservation.amount,
    'paymentStatus', reservation.payment_status
  );
END;
$$;

-- 5) Member cancellation (own, future, unpaid) ---------------------------------------
CREATE OR REPLACE FUNCTION public.member_cancel_reservation(p_reservation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.member_require_approved();
  reservation public.reservations%ROWTYPE;
BEGIN
  SELECT * INTO reservation
  FROM public.reservations
  WHERE id = p_reservation_id AND user_id = caller AND "Deleted" = 0;

  IF reservation.id IS NULL THEN
    RAISE EXCEPTION 'Reservation not found' USING ERRCODE = '22023';
  END IF;
  IF reservation.status = 'cancelled' THEN
    RETURN jsonb_build_object('id', reservation.id, 'status', 'cancelled');
  END IF;
  IF reservation.start_at <= now() THEN
    RAISE EXCEPTION 'Past or in-progress reservations cannot be cancelled online. Contact the front desk.' USING ERRCODE = '22023';
  END IF;
  IF reservation.payment_status = 'paid' THEN
    RAISE EXCEPTION 'Paid reservations must be cancelled by the front desk.' USING ERRCODE = '22023';
  END IF;

  UPDATE public.reservations
  SET status = 'cancelled'
  WHERE id = reservation.id;

  PERFORM public.audit_log('update', 'reservation', reservation.id, reservation.team_name,
    jsonb_build_object('status', reservation.status), jsonb_build_object('status', 'cancelled'),
    jsonb_build_object('source', 'member-cancel'));

  RETURN jsonb_build_object('id', reservation.id, 'status', 'cancelled');
END;
$$;

-- 6) Admin: edit private-lesson player count (after class starts too) ----------------
CREATE OR REPLACE FUNCTION public.admin_set_lesson_players(p_reservation_id uuid, p_bracket text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  reservation public.reservations%ROWTYPE;
  old_bracket text;
BEGIN
  IF p_bracket IS NOT NULL AND p_bracket NOT IN ('1-2', '3', '4', '5+') THEN
    RAISE EXCEPTION 'Player count must be 1-2, 3, 4, or 5+' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO reservation FROM public.reservations WHERE id = p_reservation_id AND "Deleted" = 0;
  IF reservation.id IS NULL THEN
    RAISE EXCEPTION 'Reservation not found' USING ERRCODE = '22023';
  END IF;

  old_bracket := reservation.lesson_player_bracket;
  UPDATE public.reservations SET lesson_player_bracket = p_bracket WHERE id = p_reservation_id
  RETURNING * INTO reservation;

  PERFORM public.audit_log('update', 'reservation', reservation.id, reservation.team_name,
    jsonb_build_object('lessonPlayerBracket', old_bracket),
    jsonb_build_object('lessonPlayerBracket', p_bracket),
    jsonb_build_object('source', 'admin-lesson-players'));

  RETURN jsonb_build_object('id', reservation.id, 'lessonPlayerBracket', reservation.lesson_player_bracket);
END;
$$;

-- 7) Fix: enforce trainer pooled capacity in admin single reservations ----------------
-- The bulk path already enforces trainer capacity; the single path did not.
CREATE OR REPLACE FUNCTION public.admin_check_trainer_capacity(p_start timestamptz, p_end timestamptz)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  config public.facility_config%ROWTYPE;
  trainer_usage integer;
BEGIN
  SELECT * INTO config FROM public.facility_config WHERE id = true;
  SELECT count(*) INTO trainer_usage
  FROM public.reservations existing
  WHERE existing."Deleted" = 0
    AND existing.status <> 'cancelled'
    AND existing.resource_type = 'trainer'
    AND existing.start_at < p_end
    AND p_start < existing.end_at;
  IF trainer_usage >= config.trainer_capacity THEN
    RAISE EXCEPTION 'Trainer gym is at capacity for that time' USING ERRCODE = '23505';
  END IF;
END;
$$;

-- Grants ------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.member_require_approved() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_get_portal(date, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_create_reservation(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_cancel_reservation(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_lesson_players(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_check_trainer_capacity(timestamptz, timestamptz) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.member_get_portal(date, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.member_create_reservation(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.member_cancel_reservation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_lesson_players(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_check_trainer_capacity(timestamptz, timestamptz) TO authenticated;

-- Recreate admin_create_single_reservation with the trainer-capacity check added.
-- Identical to 20260611103000 except for the capacity guard.
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

  IF resource = 'trainer' THEN
    PERFORM public.admin_check_trainer_capacity(slot_start_at, slot_end_at);
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
