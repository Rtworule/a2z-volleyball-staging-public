-- Coach self-service rules:
--  * Team/club practices can NOT be edited or cancelled by coaches (front desk only).
--  * Private lessons CAN be edited or cancelled by their coach, but only while the
--    reservation is more than 36 hours away (and not yet paid).

-- Allow an 'updated' notification type in the outbox.
ALTER TABLE public.notification_outbox
  DROP CONSTRAINT IF EXISTS notification_outbox_notification_type_check;
ALTER TABLE public.notification_outbox
  ADD CONSTRAINT notification_outbox_notification_type_check
  CHECK (notification_type IN ('reservation_created', 'reservation_cancelled', 'reservation_updated'));

-- Cancellation: private lessons only, > 36 hours out, unpaid.
CREATE OR REPLACE FUNCTION public.member_cancel_reservation(p_reservation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.member_require_approved();
  reservation public.reservations%ROWTYPE;
  caller_email text;
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
  IF reservation.lesson_player_bracket IS NULL THEN
    RAISE EXCEPTION 'Team practices can only be changed by the front desk.' USING ERRCODE = '42501';
  END IF;
  IF reservation.start_at <= now() + interval '36 hours' THEN
    RAISE EXCEPTION 'Private lessons can only be cancelled online more than 36 hours in advance. Contact the front desk.' USING ERRCODE = '22023';
  END IF;
  IF reservation.payment_status = 'paid' THEN
    RAISE EXCEPTION 'Paid reservations must be cancelled by the front desk.' USING ERRCODE = '22023';
  END IF;

  UPDATE public.reservations
  SET status = 'cancelled'
  WHERE id = reservation.id
  RETURNING * INTO reservation;

  PERFORM public.audit_log('update', 'reservation', reservation.id, reservation.team_name,
    jsonb_build_object('status', 'confirmed'), jsonb_build_object('status', 'cancelled'),
    jsonb_build_object('source', 'member-cancel'));

  SELECT email INTO caller_email FROM public.profiles WHERE id = caller;
  PERFORM public.queue_reservation_notification('reservation_cancelled', reservation, caller_email);

  RETURN jsonb_build_object('id', reservation.id, 'status', 'cancelled');
END;
$$;

-- Editing: private lessons only, > 36 hours out, unpaid. New slot revalidated
-- exactly like a new booking, excluding the reservation itself from conflicts.
CREATE OR REPLACE FUNCTION public.member_update_reservation(p_reservation_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.member_require_approved();
  reservation public.reservations%ROWTYPE;
  config public.facility_config%ROWTYPE;
  bracket_price public.lesson_bracket_prices%ROWTYPE;
  caller_email text;
  resource text;
  v_bracket text;
  local_date date;
  slot_start_time time;
  duration_minutes integer;
  v_court_number integer;
  slot_start_at timestamptz;
  slot_end_at timestamptz;
  trainer_usage integer;
  selected_rate numeric(8, 2);
  old_snapshot jsonb;
BEGIN
  SELECT * INTO reservation
  FROM public.reservations
  WHERE id = p_reservation_id AND user_id = caller AND "Deleted" = 0;

  IF reservation.id IS NULL THEN
    RAISE EXCEPTION 'Reservation not found' USING ERRCODE = '22023';
  END IF;
  IF reservation.status <> 'confirmed' THEN
    RAISE EXCEPTION 'Only active reservations can be changed.' USING ERRCODE = '22023';
  END IF;
  IF reservation.lesson_player_bracket IS NULL THEN
    RAISE EXCEPTION 'Team practices can only be changed by the front desk.' USING ERRCODE = '42501';
  END IF;
  IF reservation.start_at <= now() + interval '36 hours' THEN
    RAISE EXCEPTION 'Private lessons can only be changed online more than 36 hours in advance. Contact the front desk.' USING ERRCODE = '22023';
  END IF;
  IF reservation.payment_status = 'paid' THEN
    RAISE EXCEPTION 'Paid reservations must be changed by the front desk.' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO config FROM public.facility_config WHERE id = true;

  resource := coalesce(nullif(payload->>'resourceType', ''), reservation.resource_type);
  v_bracket := coalesce(nullif(payload->>'lessonPlayerBracket', ''), reservation.lesson_player_bracket);
  local_date := coalesce(nullif(payload->>'startDate', '')::date, (reservation.start_at AT TIME ZONE config.timezone)::date);
  slot_start_time := coalesce(nullif(payload->>'startTime', '')::time, (reservation.start_at AT TIME ZONE config.timezone)::time);
  duration_minutes := coalesce((payload->>'durationMinutes')::integer,
    (extract(epoch FROM reservation.end_at - reservation.start_at) / 60)::integer);
  v_court_number := coalesce(nullif(replace(coalesce(payload->>'courtId', ''), 'court-', ''), '')::integer, reservation.court_number);

  IF resource NOT IN ('court', 'trainer') THEN
    RAISE EXCEPTION 'resourceType must be court or trainer' USING ERRCODE = '22023';
  END IF;
  IF resource = 'court' AND (v_court_number IS NULL OR v_court_number NOT BETWEEN 1 AND 9) THEN
    RAISE EXCEPTION 'Select a court between 1 and 9' USING ERRCODE = '22023';
  END IF;
  IF v_bracket NOT IN ('1-2', '3', '4', '5+') THEN
    RAISE EXCEPTION 'Player count must be 1-2, 3, 4, or 5+' USING ERRCODE = '22023';
  END IF;

  slot_start_at := ((local_date::text || ' ' || slot_start_time::text)::timestamp AT TIME ZONE config.timezone);
  slot_end_at := slot_start_at + make_interval(mins => duration_minutes);

  IF slot_start_at <= now() THEN
    RAISE EXCEPTION 'Reservations cannot be moved into the past' USING ERRCODE = '22023';
  END IF;
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
        AND existing.id <> reservation.id
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
      AND existing.id <> reservation.id
      AND existing.status <> 'cancelled'
      AND existing.resource_type = 'trainer'
      AND existing.start_at < slot_end_at
      AND slot_start_at < existing.end_at;
    IF trainer_usage >= config.trainer_capacity THEN
      RAISE EXCEPTION 'Trainer gym is fully booked for that time' USING ERRCODE = '23505';
    END IF;
  END IF;

  SELECT * INTO bracket_price
  FROM public.lesson_bracket_prices
  WHERE bracket = v_bracket AND "Deleted" = 0;
  selected_rate := coalesce(
    CASE WHEN resource = 'trainer' THEN bracket_price.gym_hourly_rate ELSE bracket_price.court_hourly_rate END,
    CASE WHEN resource = 'trainer' THEN config.gym_hourly_rate ELSE config.court_hourly_rate END
  );

  old_snapshot := jsonb_build_object(
    'start', reservation.start_at, 'end', reservation.end_at,
    'resourceType', reservation.resource_type, 'courtNumber', reservation.court_number,
    'lessonPlayerBracket', reservation.lesson_player_bracket, 'amount', reservation.amount
  );

  UPDATE public.reservations
  SET resource_type = resource,
      court_number = CASE WHEN resource = 'court' THEN v_court_number ELSE NULL END,
      start_at = slot_start_at,
      end_at = slot_end_at,
      lesson_player_bracket = v_bracket,
      hourly_rate = selected_rate,
      amount = round(selected_rate * duration_minutes / 60.0, 2)
  WHERE id = reservation.id
  RETURNING * INTO reservation;

  PERFORM public.audit_log('update', 'reservation', reservation.id, reservation.team_name,
    old_snapshot,
    jsonb_build_object('start', reservation.start_at, 'end', reservation.end_at,
      'resourceType', reservation.resource_type, 'courtNumber', reservation.court_number,
      'lessonPlayerBracket', reservation.lesson_player_bracket, 'amount', reservation.amount),
    jsonb_build_object('source', 'member-update'));

  SELECT email INTO caller_email FROM public.profiles WHERE id = caller;
  PERFORM public.queue_reservation_notification('reservation_updated', reservation, caller_email);

  RETURN jsonb_build_object(
    'id', reservation.id,
    'start', reservation.start_at,
    'end', reservation.end_at,
    'resourceType', reservation.resource_type,
    'courtNumber', reservation.court_number,
    'lessonPlayerBracket', reservation.lesson_player_bracket,
    'hourlyRate', reservation.hourly_rate,
    'amount', reservation.amount
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.member_update_reservation(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.member_update_reservation(uuid, jsonb) TO authenticated;
