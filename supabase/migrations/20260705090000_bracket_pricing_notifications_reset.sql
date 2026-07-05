-- Private-lesson bracket pricing, booking/cancel notification outbox,
-- and updated member RPCs that use both. Additive only.

-- 1) Lesson bracket prices ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.lesson_bracket_prices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bracket text NOT NULL UNIQUE CHECK (bracket IN ('1-2', '3', '4', '5+')),
  court_hourly_rate numeric(8, 2) CHECK (court_hourly_rate IS NULL OR court_hourly_rate >= 0),
  gym_hourly_rate numeric(8, 2) CHECK (gym_hourly_rate IS NULL OR gym_hourly_rate >= 0),
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.lesson_bracket_prices IS
  'Hourly rates for coach private lessons by player-count bracket. Null rate falls back to the facility default for that resource.';

DROP TRIGGER IF EXISTS lesson_bracket_prices_set_updated_dt ON public.lesson_bracket_prices;
CREATE TRIGGER lesson_bracket_prices_set_updated_dt BEFORE UPDATE ON public.lesson_bracket_prices
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();

ALTER TABLE public.lesson_bracket_prices ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Authenticated read lesson bracket prices"
  ON public.lesson_bracket_prices FOR SELECT
  TO authenticated
  USING ("Deleted" = 0);

CREATE POLICY "Admins manage lesson bracket prices"
  ON public.lesson_bracket_prices FOR ALL
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

INSERT INTO public.lesson_bracket_prices (bracket)
VALUES ('1-2'), ('3'), ('4'), ('5+')
ON CONFLICT (bracket) DO NOTHING;

CREATE OR REPLACE FUNCTION public.admin_set_lesson_bracket_price(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  v_bracket text := payload->>'bracket';
  price public.lesson_bracket_prices%ROWTYPE;
BEGIN
  IF v_bracket NOT IN ('1-2', '3', '4', '5+') THEN
    RAISE EXCEPTION 'bracket must be 1-2, 3, 4, or 5+' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.lesson_bracket_prices (bracket, court_hourly_rate, gym_hourly_rate)
  VALUES (v_bracket, nullif(payload->>'courtHourlyRate', '')::numeric, nullif(payload->>'gymHourlyRate', '')::numeric)
  ON CONFLICT (bracket) DO UPDATE SET
    court_hourly_rate = nullif(payload->>'courtHourlyRate', '')::numeric,
    gym_hourly_rate = nullif(payload->>'gymHourlyRate', '')::numeric,
    "Deleted" = 0
  RETURNING * INTO price;

  PERFORM public.audit_log('update', 'lesson_bracket_price', price.id, price.bracket, NULL,
    jsonb_build_object('bracket', price.bracket, 'courtHourlyRate', price.court_hourly_rate, 'gymHourlyRate', price.gym_hourly_rate),
    jsonb_build_object('source', 'admin-bracket-price'));

  RETURN jsonb_build_object(
    'id', price.id,
    'bracket', price.bracket,
    'courtHourlyRate', price.court_hourly_rate,
    'gymHourlyRate', price.gym_hourly_rate
  );
END;
$$;

-- 2) Notification outbox ---------------------------------------------------------------
-- Rows are queued by booking/cancel RPCs. An external sender (Supabase Edge Function
-- or cron, like system_reservation_reminder_job) reads pending rows and marks them sent.
CREATE TABLE IF NOT EXISTS public.notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  notification_type text NOT NULL CHECK (notification_type IN ('reservation_created', 'reservation_cancelled')),
  recipient_email text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sent', 'failed')),
  attempts integer NOT NULL DEFAULT 0,
  sent_at timestamptz,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS notification_outbox_pending_idx
  ON public.notification_outbox(created_at)
  WHERE status = 'pending' AND "Deleted" = 0;

DROP TRIGGER IF EXISTS notification_outbox_set_updated_dt ON public.notification_outbox;
CREATE TRIGGER notification_outbox_set_updated_dt BEFORE UPDATE ON public.notification_outbox
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();

ALTER TABLE public.notification_outbox ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read notification outbox"
  ON public.notification_outbox FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins update notification outbox"
  ON public.notification_outbox FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE OR REPLACE FUNCTION public.queue_reservation_notification(
  p_type text,
  p_reservation public.reservations,
  p_recipient text
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  admin_recipient text;
  body jsonb;
BEGIN
  body := jsonb_build_object(
    'reservationId', p_reservation.id,
    'teamName', p_reservation.team_name,
    'resourceType', p_reservation.resource_type,
    'courtNumber', p_reservation.court_number,
    'start', p_reservation.start_at,
    'end', p_reservation.end_at,
    'lessonPlayerBracket', p_reservation.lesson_player_bracket,
    'hourlyRate', p_reservation.hourly_rate,
    'amount', p_reservation.amount
  );

  IF nullif(trim(coalesce(p_recipient, '')), '') IS NOT NULL THEN
    INSERT INTO public.notification_outbox (notification_type, recipient_email, payload)
    VALUES (p_type, p_recipient, body);
  END IF;

  SELECT nullif(trim(coalesce(admin_email, '')), '') INTO admin_recipient
  FROM public.facility_config WHERE id = true;

  IF admin_recipient IS NOT NULL AND lower(admin_recipient) IS DISTINCT FROM lower(coalesce(p_recipient, '')) THEN
    INSERT INTO public.notification_outbox (notification_type, recipient_email, payload)
    VALUES (p_type, admin_recipient, body || jsonb_build_object('adminCopy', true));
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.system_notification_outbox_job(p_limit integer DEFAULT 50)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object(
    'pending', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', outbox.id,
        'notificationType', outbox.notification_type,
        'recipientEmail', outbox.recipient_email,
        'payload', outbox.payload,
        'attempts', outbox.attempts,
        'createdAt', outbox.created_at
      ) ORDER BY outbox.created_at)
      FROM (
        SELECT * FROM public.notification_outbox
        WHERE status = 'pending' AND "Deleted" = 0
        ORDER BY created_at
        LIMIT least(greatest(coalesce(p_limit, 50), 1), 200)
      ) outbox
    ), '[]'::jsonb)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_mark_notification(p_notification_id uuid, p_success boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  row_out public.notification_outbox%ROWTYPE;
BEGIN
  UPDATE public.notification_outbox
  SET status = CASE WHEN p_success THEN 'sent' ELSE 'failed' END,
      attempts = attempts + 1,
      sent_at = CASE WHEN p_success THEN now() ELSE sent_at END
  WHERE id = p_notification_id
  RETURNING * INTO row_out;

  IF row_out.id IS NULL THEN
    RAISE EXCEPTION 'Notification not found' USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object('id', row_out.id, 'status', row_out.status, 'attempts', row_out.attempts);
END;
$$;

-- 3) member_get_portal: include bracket prices ------------------------------------------
CREATE OR REPLACE FUNCTION public.member_get_bracket_prices()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'bracket', bracket,
    'courtHourlyRate', court_hourly_rate,
    'gymHourlyRate', gym_hourly_rate
  ) ORDER BY CASE bracket WHEN '1-2' THEN 1 WHEN '3' THEN 2 WHEN '4' THEN 3 ELSE 4 END), '[]'::jsonb)
  FROM public.lesson_bracket_prices
  WHERE "Deleted" = 0;
$$;

-- Wrap the existing portal payload and append bracket prices without duplicating it.
DO $$
BEGIN
  IF to_regprocedure('public.member_get_portal_base(date, integer)') IS NULL THEN
    ALTER FUNCTION public.member_get_portal(date, integer) RENAME TO member_get_portal_base;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.member_get_portal(
  p_start_date date DEFAULT current_date,
  p_days integer DEFAULT 14
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT public.member_get_portal_base(p_start_date, p_days)
    || jsonb_build_object('bracketPrices', public.member_get_bracket_prices());
$$;

-- 4) member_create_reservation: bracket pricing + notification -------------------------
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
  bracket_price public.lesson_bracket_prices%ROWTYPE;
  config public.facility_config%ROWTYPE;
  caller_email text;
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

  IF booking_type = 'private' THEN
    SELECT * INTO bracket_price
    FROM public.lesson_bracket_prices
    WHERE bracket = v_bracket AND "Deleted" = 0;
    selected_rate := coalesce(
      CASE WHEN resource = 'trainer' THEN bracket_price.gym_hourly_rate ELSE bracket_price.court_hourly_rate END,
      CASE WHEN resource = 'trainer' THEN config.gym_hourly_rate ELSE config.court_hourly_rate END
    );
    selected_label := NULL;
  ELSE
    SELECT * INTO season_price
    FROM public.team_season_prices
    WHERE subject_id = subject.id AND "Deleted" = 0
    ORDER BY season_year DESC, created_at DESC
    LIMIT 1;
    selected_rate := coalesce(season_price.hourly_rate, CASE WHEN resource = 'trainer' THEN config.gym_hourly_rate ELSE config.court_hourly_rate END);
    selected_label := CASE WHEN season_price.id IS NULL THEN NULL ELSE season_price.season || ' ' || season_price.season_year END;
  END IF;

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

  SELECT email INTO caller_email FROM public.profiles WHERE id = caller;
  PERFORM public.queue_reservation_notification('reservation_created', reservation, caller_email);

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

-- 5) member_cancel_reservation: queue a cancellation notification ------------------------
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
  IF reservation.start_at <= now() THEN
    RAISE EXCEPTION 'Past or in-progress reservations cannot be cancelled online. Contact the front desk.' USING ERRCODE = '22023';
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

-- Grants ---------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.admin_set_lesson_bracket_price(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.queue_reservation_notification(text, public.reservations, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.system_notification_outbox_job(integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_mark_notification(uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_get_bracket_prices() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_get_portal_base(date, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_get_portal(date, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_create_reservation(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_cancel_reservation(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_set_lesson_bracket_price(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mark_notification(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.member_get_portal(date, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.member_create_reservation(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.member_cancel_reservation(uuid) TO authenticated;

COMMENT ON FUNCTION public.system_notification_outbox_job(integer) IS
  'Poll from a Supabase Edge Function or cron with the service role: send each pending email, then call admin_mark_notification(id, success).';

-- Fix pre-existing bug: admin_update_facility_config assigned updated_at twice,
-- which raises "multiple assignments to same column" and breaks every admin
-- facility-settings save. Recreated identically minus the duplicate.
CREATE OR REPLACE FUNCTION public.admin_update_facility_config(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_require_approved();

  UPDATE public.facility_config
  SET court_count = coalesce((payload->>'courtCount')::integer, court_count),
      trainer_capacity = coalesce((payload->>'trainerCapacity')::integer, trainer_capacity),
      court_hourly_rate = coalesce((payload->>'courtHourlyRate')::numeric, court_hourly_rate),
      gym_hourly_rate = coalesce((payload->>'gymHourlyRate')::numeric, gym_hourly_rate),
      min_reservation_minutes = coalesce((payload->>'minBookingMinutes')::integer, min_reservation_minutes),
      reservation_step_minutes = coalesce((payload->>'slotIntervalMinutes')::integer, reservation_step_minutes),
      message_display_seconds = coalesce((payload->>'messageDisplaySeconds')::integer, message_display_seconds),
      admin_email = coalesce(nullif(payload->>'adminEmail', ''), admin_email),
      email_templates = coalesce(payload->'emailTemplates', email_templates),
      updated_at = now()
  WHERE id = true;

  RETURN public.admin_get_dashboard();
END;
$$;
