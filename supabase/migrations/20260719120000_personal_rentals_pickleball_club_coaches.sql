-- Personal court rentals for approved accounts without a club/coach link,
-- pickleball pricing, card-on-file at the profile level, and admin-managed
-- club coach assignments.

-- 1) Pickleball rate ---------------------------------------------------------------
ALTER TABLE public.facility_config
  ADD COLUMN IF NOT EXISTS pickleball_hourly_rate numeric(8, 2)
  CHECK (pickleball_hourly_rate IS NULL OR pickleball_hourly_rate >= 0);

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
      pickleball_hourly_rate = coalesce((payload->>'pickleballHourlyRate')::numeric, pickleball_hourly_rate),
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

-- 2) Card on file for individual profiles -------------------------------------------
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS card_processor_customer_id text,
  ADD COLUMN IF NOT EXISTS card_brand text,
  ADD COLUMN IF NOT EXISTS card_last4 text CHECK (card_last4 IS NULL OR card_last4 ~ '^[0-9]{4}$'),
  ADD COLUMN IF NOT EXISTS card_on_file_at timestamptz;

CREATE OR REPLACE FUNCTION public.admin_set_profile_card(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  target public.profiles%ROWTYPE;
BEGIN
  UPDATE public.profiles
  SET card_processor_customer_id = nullif(payload->>'processorCustomerId', ''),
      card_brand = nullif(payload->>'cardBrand', ''),
      card_last4 = nullif(payload->>'cardLast4', ''),
      card_on_file_at = CASE WHEN nullif(payload->>'processorCustomerId', '') IS NULL THEN NULL ELSE now() END
  WHERE id = (payload->>'profileId')::uuid
  RETURNING * INTO target;
  IF target.id IS NULL THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = '22023';
  END IF;
  PERFORM public.audit_log('update', 'profile', target.id, target.username,
    NULL, jsonb_build_object('cardOnFile', target.card_processor_customer_id IS NOT NULL, 'cardLast4', target.card_last4),
    jsonb_build_object('source', 'admin-profile-card'));
  RETURN jsonb_build_object('id', target.id, 'cardOnFile', target.card_processor_customer_id IS NOT NULL,
    'cardBrand', target.card_brand, 'cardLast4', target.card_last4);
END;
$$;

-- 3) Personal rentals: sport column + create/cancel support --------------------------
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS rental_sport text
  CHECK (rental_sport IS NULL OR rental_sport IN ('volleyball', 'pickleball'));

CREATE OR REPLACE FUNCTION public.member_create_personal_reservation(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.member_require_approved();
  profile public.profiles%ROWTYPE;
  config public.facility_config%ROWTYPE;
  v_sport text := coalesce(nullif(payload->>'rentalSport', ''), 'volleyball');
  local_date date := (payload->>'startDate')::date;
  slot_start_time time := (payload->>'startTime')::time;
  duration_minutes integer := coalesce((payload->>'durationMinutes')::integer, 60);
  v_court_number integer := nullif(replace(coalesce(payload->>'courtId', ''), 'court-', ''), '')::integer;
  slot_start_at timestamptz;
  slot_end_at timestamptz;
  selected_rate numeric(8, 2);
  reservation public.reservations%ROWTYPE;
BEGIN
  SELECT * INTO profile FROM public.profiles WHERE id = caller;
  SELECT * INTO config FROM public.facility_config WHERE id = true;

  IF profile.card_processor_customer_id IS NULL THEN
    RAISE EXCEPTION 'A credit card on file is required for court rentals. Please contact the front desk to add one.' USING ERRCODE = '42501';
  END IF;
  IF v_sport NOT IN ('volleyball', 'pickleball') THEN
    RAISE EXCEPTION 'Sport must be volleyball or pickleball' USING ERRCODE = '22023';
  END IF;
  IF v_court_number IS NULL OR v_court_number NOT BETWEEN 1 AND config.court_count THEN
    RAISE EXCEPTION 'Select a court between 1 and %', config.court_count USING ERRCODE = '22023';
  END IF;

  slot_start_at := ((local_date::text || ' ' || slot_start_time::text)::timestamp AT TIME ZONE config.timezone);
  slot_end_at := slot_start_at + make_interval(mins => duration_minutes);

  IF slot_start_at <= now() THEN
    RAISE EXCEPTION 'Reservations must be in the future' USING ERRCODE = '22023';
  END IF;
  IF duration_minutes < config.min_reservation_minutes OR duration_minutes % config.reservation_step_minutes <> 0 THEN
    RAISE EXCEPTION 'Reservations must be at least 1 hour in 30-minute steps' USING ERRCODE = '22023';
  END IF;
  IF duration_minutes > 240 THEN
    RAISE EXCEPTION 'Personal court rentals are limited to 4 hours' USING ERRCODE = '22023';
  END IF;

  IF slot_start_time < (SELECT open_time FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer)
    OR (slot_start_time + make_interval(mins => duration_minutes))::time > (SELECT close_time FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer)
    OR coalesce((SELECT is_closed FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer), true) THEN
    RAISE EXCEPTION 'Reservation is outside business hours' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.closures closure
    WHERE closure."Deleted" = 0
      AND closure.start_at < slot_end_at AND slot_start_at < closure.end_at
      AND (closure.resource_type = 'all' OR closure.resource_type = 'court')
      AND (closure.court_number IS NULL OR closure.court_number = v_court_number)
  ) THEN
    RAISE EXCEPTION 'The facility is closed during that time' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('a2z-court-' || v_court_number::text));
  IF EXISTS (
    SELECT 1 FROM public.reservations existing
    WHERE existing."Deleted" = 0 AND existing.status <> 'cancelled'
      AND existing.resource_type = 'court' AND existing.court_number = v_court_number
      AND existing.start_at < slot_end_at AND slot_start_at < existing.end_at
  ) OR EXISTS (
    SELECT 1 FROM public.fixed_reservations fixed
    WHERE fixed."Deleted" = 0 AND fixed.resource_type = 'court' AND fixed.court_number = v_court_number
      AND extract(dow FROM local_date)::integer = ANY(fixed.days_of_week)
      AND local_date BETWEEN fixed.start_date AND fixed.end_date
      AND fixed.start_time < (slot_start_time + make_interval(mins => duration_minutes))::time
      AND slot_start_time < fixed.end_time
  ) THEN
    RAISE EXCEPTION 'Court is already reserved' USING ERRCODE = '23505';
  END IF;

  selected_rate := CASE WHEN v_sport = 'pickleball'
    THEN coalesce(config.pickleball_hourly_rate, config.court_hourly_rate)
    ELSE config.court_hourly_rate END;

  INSERT INTO public.reservations
    (user_id, subject_id, team_name, resource_type, court_number, start_at, end_at,
     hourly_rate, amount, status, payment_status, reservation_source, rental_sport)
  VALUES
    (caller, NULL, coalesce(profile.display_name, profile.username), 'court', v_court_number,
     slot_start_at, slot_end_at, selected_rate,
     round(selected_rate * duration_minutes / 60.0, 2), 'confirmed', 'due', 'booking', v_sport)
  RETURNING * INTO reservation;

  PERFORM public.audit_log('create', 'reservation', reservation.id, reservation.team_name,
    NULL, jsonb_build_object('rentalSport', v_sport, 'amount', reservation.amount),
    jsonb_build_object('source', 'member-personal'));

  PERFORM public.queue_reservation_notification('reservation_created', reservation, profile.email);

  RETURN jsonb_build_object(
    'id', reservation.id, 'courtNumber', reservation.court_number,
    'start', reservation.start_at, 'end', reservation.end_at,
    'rentalSport', v_sport, 'hourlyRate', reservation.hourly_rate, 'amount', reservation.amount
  );
END;
$$;

-- Cancel: personal rentals join private lessons under the same fee tiers.
CREATE OR REPLACE FUNCTION public.member_cancel_reservation(p_reservation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.member_require_approved();
  reservation public.reservations%ROWTYPE;
  subject public.subjects%ROWTYPE;
  caller_email text;
  hours_out numeric;
  fee_percent integer;
  fee_amount numeric(8, 2);
  fee_status text;
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
  IF reservation.lesson_player_bracket IS NULL AND reservation.rental_sport IS NULL THEN
    RAISE EXCEPTION 'Team practices can only be changed by the front desk.' USING ERRCODE = '42501';
  END IF;
  IF reservation.start_at <= now() THEN
    RAISE EXCEPTION 'This reservation has already started. Contact the front desk.' USING ERRCODE = '22023';
  END IF;
  IF reservation.payment_status = 'paid' THEN
    RAISE EXCEPTION 'Paid reservations must be cancelled by the front desk.' USING ERRCODE = '22023';
  END IF;

  hours_out := extract(epoch FROM reservation.start_at - now()) / 3600.0;
  fee_percent := CASE WHEN hours_out > 36 THEN 0 WHEN hours_out > 24 THEN 50 ELSE 100 END;
  fee_amount := round(coalesce(reservation.amount, 0) * fee_percent / 100.0, 2);

  IF reservation.subject_id IS NOT NULL THEN
    SELECT * INTO subject FROM public.subjects WHERE id = reservation.subject_id;
  END IF;
  fee_status := CASE
    WHEN fee_percent = 0 THEN 'none'
    WHEN subject.billing_terms = 'monthly' THEN 'invoiced'
    ELSE 'pending_charge'
  END;

  UPDATE public.reservations
  SET status = 'cancelled',
      cancellation_fee_percent = fee_percent,
      cancellation_fee_amount = fee_amount,
      cancellation_fee_status = fee_status
  WHERE id = reservation.id
  RETURNING * INTO reservation;

  PERFORM public.audit_log('update', 'reservation', reservation.id, reservation.team_name,
    jsonb_build_object('status', 'confirmed'),
    jsonb_build_object('status', 'cancelled', 'cancellationFeePercent', fee_percent,
      'cancellationFeeAmount', fee_amount, 'cancellationFeeStatus', fee_status),
    jsonb_build_object('source', 'member-cancel'));

  SELECT email INTO caller_email FROM public.profiles WHERE id = caller;
  PERFORM public.queue_reservation_notification('reservation_cancelled', reservation, caller_email);

  RETURN jsonb_build_object('id', reservation.id, 'status', 'cancelled',
    'cancellationFeePercent', fee_percent, 'cancellationFeeAmount', fee_amount,
    'cancellationFeeStatus', fee_status);
END;
$$;

-- 4) Portal: personal context, per-booking sport, pickleball rate ---------------------
CREATE OR REPLACE FUNCTION public.member_get_portal(
  p_start_date date DEFAULT current_date,
  p_days integer DEFAULT 14
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT public.member_get_portal_base(p_start_date, p_days) AS j
  ), me AS (
    SELECT * FROM public.profiles WHERE id = auth.uid()
  )
  SELECT jsonb_set(
           jsonb_set(
             j,
             '{contexts}',
             coalesce((
               SELECT jsonb_agg(
                 ctx || jsonb_build_object(
                   'billingTerms', s.billing_terms,
                   'cardOnFile', s.card_processor_customer_id IS NOT NULL,
                   'cardLast4', s.card_last4
                 )
               )
               FROM jsonb_array_elements(j->'contexts') AS ctx
               JOIN public.subjects s ON s.id = (ctx->>'subjectId')::uuid
             ), '[]'::jsonb)
             || jsonb_build_array(
               jsonb_build_object(
                 'key', 'personal', 'type', 'personal',
                 'label', 'Myself — court rental',
                 'billingTerms', 'card_on_file',
                 'cardOnFile', (SELECT card_processor_customer_id IS NOT NULL FROM me),
                 'cardLast4', (SELECT card_last4 FROM me)
               )
             )
           ),
           '{myReservations}',
           coalesce((
             SELECT jsonb_agg(entry || jsonb_build_object('rentalSport', r.rental_sport))
             FROM jsonb_array_elements(j->'myReservations') AS entry
             JOIN public.reservations r ON r.id = (entry->>'id')::uuid
           ), '[]'::jsonb)
         )
         || jsonb_build_object(
              'bracketPrices', public.member_get_bracket_prices(),
              'pickleballHourlyRate', (SELECT pickleball_hourly_rate FROM public.facility_config WHERE id = true)
            )
  FROM base;
$$;

-- 5) Club coach management ------------------------------------------------------------
ALTER TABLE public.subject_memberships
  DROP CONSTRAINT IF EXISTS subject_memberships_membership_role_check;
ALTER TABLE public.subject_memberships
  ADD CONSTRAINT subject_memberships_membership_role_check
  CHECK (membership_role IN ('owner', 'scheduler', 'billing', 'viewer', 'coach'));

CREATE OR REPLACE FUNCTION public.admin_search_profiles(p_query text)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN public.admin_require_approved() IS NOT NULL THEN
    coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', p.id, 'username', p.username, 'email', p.email,
        'displayName', p.display_name, 'approvalStatus', p.approval_status))
      FROM (
        SELECT * FROM public.profiles
        WHERE approval_status = 'approved'
          AND (username ILIKE '%' || p_query || '%' OR email ILIKE '%' || p_query || '%' OR display_name ILIKE '%' || p_query || '%')
        ORDER BY username LIMIT 8
      ) p
    ), '[]'::jsonb)
  END;
$$;

CREATE OR REPLACE FUNCTION public.admin_add_club_coach(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.subjects%ROWTYPE;
  target public.profiles%ROWTYPE;
  membership public.subject_memberships%ROWTYPE;
BEGIN
  SELECT * INTO subject FROM public.subjects WHERE id = (payload->>'subjectId')::uuid AND "Deleted" = 0;
  SELECT * INTO target FROM public.profiles WHERE id = (payload->>'profileId')::uuid;
  IF subject.id IS NULL OR target.id IS NULL THEN
    RAISE EXCEPTION 'Client or profile not found' USING ERRCODE = '22023';
  END IF;
  IF target.approval_status <> 'approved' THEN
    RAISE EXCEPTION 'Only approved accounts can be assigned as coaches' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO membership FROM public.subject_memberships
  WHERE subject_id = subject.id AND profile_id = target.id;

  IF membership.id IS NULL THEN
    INSERT INTO public.subject_memberships (subject_id, profile_id, membership_role, status, can_book)
    VALUES (subject.id, target.id, 'coach', 'active', true)
    RETURNING * INTO membership;
  ELSIF membership.membership_role <> 'coach' AND membership."Deleted" = 0 THEN
    RAISE EXCEPTION 'Profile already has the % role for this client', membership.membership_role
      USING ERRCODE = '22023';
  ELSE
    UPDATE public.subject_memberships
    SET membership_role = 'coach', status = 'active', can_book = true, "Deleted" = 0
    WHERE id = membership.id
    RETURNING * INTO membership;
  END IF;

  PERFORM public.audit_log('update', 'subject', subject.id, subject.display_name,
    NULL, jsonb_build_object('coachAdded', target.username), jsonb_build_object('source', 'admin-club-coach'));

  RETURN jsonb_build_object('membershipId', membership.id, 'subjectId', subject.id,
    'profileId', target.id, 'role', membership.membership_role, 'status', membership.status);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_remove_club_coach(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  membership public.subject_memberships%ROWTYPE;
BEGIN
  UPDATE public.subject_memberships
  SET status = 'disabled', can_book = false, "Deleted" = 1
  WHERE subject_id = (payload->>'subjectId')::uuid
    AND profile_id = (payload->>'profileId')::uuid
    AND membership_role = 'coach'
  RETURNING * INTO membership;
  IF membership.id IS NULL THEN
    RAISE EXCEPTION 'Coach assignment not found' USING ERRCODE = '22023';
  END IF;
  PERFORM public.audit_log('update', 'subject', membership.subject_id, NULL,
    NULL, jsonb_build_object('coachRemoved', membership.profile_id), jsonb_build_object('source', 'admin-club-coach'));
  RETURN jsonb_build_object('membershipId', membership.id, 'status', membership.status);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_list_club_coaches(p_subject_id uuid)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN public.admin_require_approved() IS NOT NULL THEN
    coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'profileId', p.id, 'username', p.username, 'email', p.email,
        'displayName', p.display_name, 'role', m.membership_role) ORDER BY p.username)
      FROM public.subject_memberships m
      JOIN public.profiles p ON p.id = m.profile_id
      WHERE m.subject_id = p_subject_id
        AND m.membership_role = 'coach'
        AND m."Deleted" = 0
        AND m.status = 'active'
    ), '[]'::jsonb)
  END;
$$;

-- Grants --------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.member_create_personal_reservation(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_cancel_reservation(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_get_portal(date, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_profile_card(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_search_profiles(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_add_club_coach(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_remove_club_coach(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_list_club_coaches(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.member_create_personal_reservation(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.member_cancel_reservation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.member_get_portal(date, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_profile_card(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_search_profiles(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_add_club_coach(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_remove_club_coach(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_club_coaches(uuid) TO authenticated;

-- 6) Expose pickleballHourlyRate in the admin dashboard settings payload -------------
DO $do$
DECLARE
  rec record;
  fn text;
BEGIN
  FOR rec IN
    SELECT oid FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND pg_get_functiondef(oid) LIKE '%''gymHourlyRate''%'
      AND pg_get_functiondef(oid) LIKE '%''pricing''%'
  LOOP
    fn := pg_get_functiondef(rec.oid);
    IF fn NOT LIKE '%pickleballHourlyRate%' THEN
      fn := replace(fn,
        $q$'gymHourlyRate', config_row.gym_hourly_rate$q$,
        $q$'gymHourlyRate', config_row.gym_hourly_rate,
      'pickleballHourlyRate', config_row.pickleball_hourly_rate$q$);
      fn := replace(fn,
        $q$'gymHourlyRate', config.gym_hourly_rate$q$,
        $q$'gymHourlyRate', config.gym_hourly_rate,
      'pickleballHourlyRate', config.pickleball_hourly_rate$q$);
      EXECUTE fn;
    END IF;
  END LOOP;
END;
$do$;
