ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS season_price_id uuid,
  ADD COLUMN IF NOT EXISTS season_label text,
  ADD COLUMN IF NOT EXISTS hourly_rate numeric(8, 2),
  ADD COLUMN IF NOT EXISTS amount_due numeric(10, 2);

CREATE TABLE IF NOT EXISTS public.team_season_prices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL REFERENCES public.admin_subjects(id),
  season text NOT NULL,
  season_year integer NOT NULL CHECK (season_year BETWEEN 2000 AND 2100),
  hourly_rate numeric(8, 2) NOT NULL CHECK (hourly_rate >= 0),
  created_by uuid REFERENCES public.profiles(id),
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE public.reservations
  DROP CONSTRAINT IF EXISTS reservations_season_price_id_fkey,
  ADD CONSTRAINT reservations_season_price_id_fkey
    FOREIGN KEY (season_price_id) REFERENCES public.team_season_prices(id);

ALTER TABLE public.admin_bulk_operation_items
  ADD COLUMN IF NOT EXISTS season_price_id uuid,
  ADD COLUMN IF NOT EXISTS season_label text,
  ADD COLUMN IF NOT EXISTS hourly_rate numeric(8, 2),
  ADD COLUMN IF NOT EXISTS amount_due numeric(10, 2);

CREATE UNIQUE INDEX IF NOT EXISTS team_season_prices_unique_active_idx
  ON public.team_season_prices(subject_id, season_year, season)
  WHERE "Deleted" = 0;

CREATE INDEX IF NOT EXISTS team_season_prices_subject_year_idx
  ON public.team_season_prices(subject_id, season_year DESC)
  WHERE "Deleted" = 0;

ALTER TABLE public.team_season_prices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read active team season prices" ON public.team_season_prices;
DROP POLICY IF EXISTS "Admins insert team season prices" ON public.team_season_prices;
DROP POLICY IF EXISTS "Admins update team season prices" ON public.team_season_prices;

CREATE POLICY "Admins read active team season prices"
  ON public.team_season_prices FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert team season prices"
  ON public.team_season_prices FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update team season prices"
  ON public.team_season_prices FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

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
    'season', price.season,
    'seasonYear', price.season_year,
    'hourlyRate', price.hourly_rate,
    'deleted', price."Deleted" = 1,
    'createdDT', price."createdDT",
    'updatedDT', price."updatedDT"
  )
  FROM public.admin_subjects subject
  WHERE subject.id = price.subject_id;
$$;

CREATE OR REPLACE FUNCTION public.admin_reservation_json(reservation public.reservations)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', reservation.id,
    'userId', reservation.user_id,
    'teamId', reservation.team_name,
    'subjectId', reservation.subject_id,
    'resourceType', reservation.resource_type,
    'courtId', CASE WHEN reservation.court_number IS NULL THEN NULL ELSE 'court-' || reservation.court_number END,
    'start', reservation.start_at,
    'end', reservation.end_at,
    'status', reservation.status,
    'paymentStatus', reservation.payment_status,
    'paid', reservation.paid = 1,
    'seasonPriceId', reservation.season_price_id,
    'seasonLabel', reservation.season_label,
    'hourlyRate', reservation.hourly_rate,
    'amountDue', reservation.amount_due,
    'deleted', reservation."Deleted" = 1,
    'bulkOperationId', reservation.bulk_operation_id,
    'createdDT', reservation."createdDT",
    'updatedDT', reservation."updatedDT"
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_update_subject(p_subject_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  subject public.admin_subjects%ROWTYPE;
  next_type text := coalesce(nullif(payload->>'subjectType', ''), 'team');
BEGIN
  PERFORM public.admin_require_approved();

  IF next_type NOT IN ('team', 'coach') THEN
    RAISE EXCEPTION 'Type must be team or coach' USING ERRCODE = '22023';
  END IF;

  UPDATE public.admin_subjects
  SET subject_type = next_type,
      display_name = coalesce(nullif(payload->>'displayName', ''), display_name),
      contact_email = nullif(payload->>'contactEmail', ''),
      "updatedDT" = now()
  WHERE id = p_subject_id
    AND "Deleted" = 0
  RETURNING * INTO subject;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Team or coach record not found' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_subject_json(subject);
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

  INSERT INTO public.team_season_prices (
    subject_id, season, season_year, hourly_rate, created_by
  ) VALUES (
    subject.id,
    trim(payload->>'season'),
    (payload->>'seasonYear')::integer,
    (payload->>'hourlyRate')::numeric,
    actor_id
  )
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
    'teamSeasonPrices', season_prices_json,
    'bulkOperations', operations_json,
    'actorId', actor_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_bulk_preview_items(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.admin_subjects%ROWTYPE;
  season_price public.team_season_prices%ROWTYPE;
  config public.facility_config%ROWTYPE;
  local_date date := (payload->>'startDate')::date;
  end_date date := coalesce((payload->>'endDate')::date, (payload->>'startDate')::date);
  slot_start_time time := (payload->>'startTime')::time;
  duration_minutes integer := coalesce((payload->>'durationMinutes')::integer, 60);
  resource text := coalesce(payload->>'resourceType', 'court');
  requested_court integer := nullif(replace(coalesce(payload->>'courtId', ''), 'court-', ''), '')::integer;
  conflict_resolution text := coalesce(payload->>'conflictResolution', 'skip_conflicts');
  paid_flag boolean := coalesce((payload->>'paid')::boolean, false);
  selected_rate numeric(8, 2);
  selected_label text;
  allowed_days integer[];
  slot_start_at timestamptz;
  slot_end_at timestamptz;
  resolved_court integer;
  item_status text;
  conflict_reason text;
  trainer_usage integer;
  items jsonb := '[]'::jsonb;
BEGIN
  IF actor_id IS NULL THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;

  IF resource NOT IN ('court', 'trainer') THEN
    RAISE EXCEPTION 'resourceType must be court or trainer' USING ERRCODE = '22023';
  END IF;

  IF end_date < local_date THEN
    RAISE EXCEPTION 'End date must be on or after start date' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO subject
  FROM public.admin_subjects
  WHERE id = (payload->>'subjectId')::uuid
    AND "Deleted" = 0;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Team or coach record not found' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO config FROM public.facility_config WHERE id = true;

  IF nullif(payload->>'seasonPriceId', '') IS NOT NULL THEN
    SELECT * INTO season_price
    FROM public.team_season_prices
    WHERE id = (payload->>'seasonPriceId')::uuid
      AND subject_id = subject.id
      AND "Deleted" = 0;

    IF season_price.id IS NULL THEN
      RAISE EXCEPTION 'Season price not found for selected team' USING ERRCODE = '22023';
    END IF;
  END IF;

  selected_rate := coalesce(season_price.hourly_rate, nullif(payload->>'hourlyRate', '')::numeric, CASE WHEN resource = 'trainer' THEN config.gym_hourly_rate ELSE config.court_hourly_rate END);
  selected_label := coalesce(nullif(payload->>'seasonLabel', ''), CASE WHEN season_price.id IS NULL THEN NULL ELSE season_price.season || ' ' || season_price.season_year END);

  IF duration_minutes < config.min_reservation_minutes OR duration_minutes % config.reservation_step_minutes <> 0 THEN
    RAISE EXCEPTION 'Duration must follow reservation rules' USING ERRCODE = '22023';
  END IF;

  SELECT coalesce(array_agg(value::integer), ARRAY[1, 2, 3, 4, 5])
  INTO allowed_days
  FROM jsonb_array_elements_text(coalesce(payload->'daysOfWeek', '[1,2,3,4,5]'::jsonb)) AS value;

  WHILE local_date <= end_date LOOP
    IF extract(dow FROM local_date)::integer = ANY(allowed_days) THEN
      slot_start_at := ((local_date::text || ' ' || slot_start_time::text)::timestamp AT TIME ZONE config.timezone);
      slot_end_at := slot_start_at + make_interval(mins => duration_minutes);
      resolved_court := requested_court;
      item_status := 'preview';
      conflict_reason := null;

      IF slot_start_time < (SELECT open_time FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer)
        OR (slot_start_time + make_interval(mins => duration_minutes))::time > (SELECT close_time FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer)
        OR coalesce((SELECT is_closed FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer), true) THEN
        item_status := 'conflict';
        conflict_reason := 'Outside operating hours';
      END IF;

      IF item_status = 'preview' AND EXISTS (
        SELECT 1 FROM public.closures closure
        WHERE closure."Deleted" = 0
          AND closure.start_at < slot_end_at
          AND slot_start_at < closure.end_at
          AND (closure.resource_type = 'all' OR closure.resource_type = resource)
          AND (resource <> 'court' OR closure.court_number IS NULL OR closure.court_number = resolved_court)
      ) THEN
        item_status := 'conflict';
        conflict_reason := 'Facility closure';
      END IF;

      IF item_status = 'preview' AND resource = 'court' THEN
        IF resolved_court IS NULL THEN
          SELECT court_number INTO resolved_court
          FROM generate_series(1, config.court_count) AS available_court(court_number)
          WHERE NOT EXISTS (
            SELECT 1 FROM public.reservations reservation
            WHERE reservation."Deleted" = 0
              AND reservation.status <> 'cancelled'
              AND reservation.resource_type = 'court'
              AND reservation.court_number = court_number
              AND reservation.start_at < slot_end_at
              AND slot_start_at < reservation.end_at
          )
          AND NOT EXISTS (
            SELECT 1 FROM public.fixed_reservations fixed
            WHERE fixed."Deleted" = 0
              AND fixed.resource_type = 'court'
              AND fixed.court_number = court_number
              AND extract(dow FROM local_date)::integer = ANY(fixed.days_of_week)
              AND local_date BETWEEN fixed.start_date AND fixed.end_date
              AND fixed.start_time < (slot_start_time + make_interval(mins => duration_minutes))::time
              AND slot_start_time < fixed.end_time
          )
          ORDER BY court_number
          LIMIT 1;
        ELSIF EXISTS (
          SELECT 1 FROM public.reservations reservation
          WHERE reservation."Deleted" = 0
            AND reservation.status <> 'cancelled'
            AND reservation.resource_type = 'court'
            AND reservation.court_number = resolved_court
            AND reservation.start_at < slot_end_at
            AND slot_start_at < reservation.end_at
        ) OR EXISTS (
          SELECT 1 FROM public.fixed_reservations fixed
          WHERE fixed."Deleted" = 0
            AND fixed.resource_type = 'court'
            AND fixed.court_number = resolved_court
            AND extract(dow FROM local_date)::integer = ANY(fixed.days_of_week)
            AND local_date BETWEEN fixed.start_date AND fixed.end_date
            AND fixed.start_time < (slot_start_time + make_interval(mins => duration_minutes))::time
            AND slot_start_time < fixed.end_time
        ) THEN
          item_status := 'conflict';
          conflict_reason := 'Court is already reserved';
        END IF;

        IF item_status = 'preview' AND (resolved_court IS NULL OR resolved_court NOT BETWEEN 1 AND config.court_count) THEN
          item_status := 'conflict';
          conflict_reason := 'No court is available';
        END IF;
      END IF;

      IF item_status = 'preview' AND resource = 'trainer' THEN
        SELECT
          (SELECT count(*) FROM public.reservations reservation
           WHERE reservation."Deleted" = 0
             AND reservation.status <> 'cancelled'
             AND reservation.resource_type = 'trainer'
             AND reservation.start_at < slot_end_at
             AND slot_start_at < reservation.end_at)
          + coalesce((
            SELECT sum(fixed.capacity) FROM public.fixed_reservations fixed
            WHERE fixed."Deleted" = 0
              AND fixed.resource_type = 'trainer'
              AND extract(dow FROM local_date)::integer = ANY(fixed.days_of_week)
              AND local_date BETWEEN fixed.start_date AND fixed.end_date
              AND fixed.start_time < (slot_start_time + make_interval(mins => duration_minutes))::time
              AND slot_start_time < fixed.end_time
          ), 0)
        INTO trainer_usage;

        IF trainer_usage >= config.trainer_capacity THEN
          item_status := 'conflict';
          conflict_reason := 'No trainer gym slot is available';
        END IF;
      END IF;

      items := items || jsonb_build_array(jsonb_build_object(
        'subjectId', subject.id,
        'subjectName', subject.display_name,
        'userId', subject.id,
        'resourceType', resource,
        'courtId', CASE WHEN resource = 'court' AND resolved_court IS NOT NULL THEN 'court-' || resolved_court ELSE NULL END,
        'start', slot_start_at,
        'end', slot_end_at,
        'seasonPriceId', season_price.id,
        'seasonLabel', selected_label,
        'hourlyRate', selected_rate,
        'amountDue', round(selected_rate * duration_minutes / 60.0, 2),
        'paid', paid_flag,
        'status', item_status,
        'conflictReason', conflict_reason
      ));
    END IF;

    local_date := local_date + 1;
  END LOOP;

  RETURN items;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_bulk_reservations(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  preview jsonb := public.admin_preview_bulk_reservations(payload);
  conflicts integer := coalesce(jsonb_array_length(jsonb_path_query_array(preview, '$.items[*] ? (@.status == "conflict")')), 0);
  operation public.admin_bulk_operations%ROWTYPE;
  item jsonb;
  reservation public.reservations%ROWTYPE;
  created jsonb := '[]'::jsonb;
BEGIN
  IF conflicts > 0 AND coalesce(payload->>'conflictResolution', 'skip_conflicts') = 'fail_all' THEN
    RAISE EXCEPTION 'Bulk operation has conflicts' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.admin_bulk_operations (
    operation_type, label, subject_id, start_date, end_date, status, paid, conflict_resolution, requested_payload, preview_payload, created_by, applied_by, "appliedDT"
  ) VALUES (
    'reservation_create',
    coalesce(payload->>'label', 'Bulk reservation'),
    (payload->>'subjectId')::uuid,
    (payload->>'startDate')::date,
    coalesce((payload->>'endDate')::date, (payload->>'startDate')::date),
    'applied',
    CASE WHEN coalesce((payload->>'paid')::boolean, false) THEN 1 ELSE 0 END,
    coalesce(payload->>'conflictResolution', 'skip_conflicts'),
    payload,
    preview,
    actor_id,
    actor_id,
    now()
  ) RETURNING * INTO operation;

  FOR item IN SELECT value FROM jsonb_array_elements(preview->'items')
  LOOP
    IF item->>'status' = 'conflict' THEN
      INSERT INTO public.admin_bulk_operation_items (
        bulk_operation_id, action, subject_id, resource_type, court_number, start_at, end_at, season_price_id, season_label, hourly_rate, amount_due, paid, status, conflict_reason
      ) VALUES (
        operation.id, 'create', (item->>'subjectId')::uuid, item->>'resourceType', nullif(replace(coalesce(item->>'courtId', ''), 'court-', ''), '')::integer,
        (item->>'start')::timestamptz, (item->>'end')::timestamptz, nullif(item->>'seasonPriceId', '')::uuid, item->>'seasonLabel',
        nullif(item->>'hourlyRate', '')::numeric, nullif(item->>'amountDue', '')::numeric,
        CASE WHEN coalesce((item->>'paid')::boolean, false) THEN 1 ELSE 0 END, 'skipped', item->>'conflictReason'
      );
      CONTINUE;
    END IF;

    INSERT INTO public.reservations (
      user_id, team_name, subject_id, resource_type, court_number, start_at, end_at, status, payment_status, paid, season_price_id, season_label, hourly_rate, amount_due, created_by, bulk_operation_id
    ) VALUES (
      NULL,
      item->>'subjectName',
      (item->>'subjectId')::uuid,
      item->>'resourceType',
      nullif(replace(coalesce(item->>'courtId', ''), 'court-', ''), '')::integer,
      (item->>'start')::timestamptz,
      (item->>'end')::timestamptz,
      'confirmed',
      CASE WHEN coalesce((item->>'paid')::boolean, false) THEN 'paid' ELSE 'due' END,
      CASE WHEN coalesce((item->>'paid')::boolean, false) THEN 1 ELSE 0 END,
      nullif(item->>'seasonPriceId', '')::uuid,
      item->>'seasonLabel',
      nullif(item->>'hourlyRate', '')::numeric,
      nullif(item->>'amountDue', '')::numeric,
      actor_id,
      operation.id
    ) RETURNING * INTO reservation;

    INSERT INTO public.admin_bulk_operation_items (
      bulk_operation_id, reservation_id, action, subject_id, resource_type, court_number, start_at, end_at, season_price_id, season_label, hourly_rate, amount_due, paid, status
    ) VALUES (
      operation.id, reservation.id, 'create', reservation.subject_id, reservation.resource_type, reservation.court_number, reservation.start_at, reservation.end_at,
      reservation.season_price_id, reservation.season_label, reservation.hourly_rate, reservation.amount_due, reservation.paid, 'applied'
    );

    created := created || jsonb_build_array(public.admin_reservation_json(reservation));
  END LOOP;

  RETURN jsonb_build_object('operation', public.admin_bulk_operation_json(operation), 'created', created, 'items', preview->'items');
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_calculate_monthly_payment_due(p_run_date date DEFAULT current_date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  period_start date := (date_trunc('month', p_run_date)::date - interval '1 month')::date;
  period_end date := date_trunc('month', p_run_date)::date;
BEGIN
  PERFORM public.admin_require_approved();

  RETURN jsonb_build_object(
    'periodStart', period_start,
    'periodEnd', period_end,
    'items', coalesce((
      SELECT jsonb_agg(row_to_json(monthly) ORDER BY monthly.teamName)
      FROM (
        SELECT
          reservation.subject_id AS "subjectId",
          coalesce(subject.display_name, reservation.team_name, reservation.subject_id::text) AS "teamName",
          count(*) AS "reservationCount",
          round(sum(extract(epoch FROM (reservation.end_at - reservation.start_at)) / 3600.0), 2) AS "hours",
          round(sum(coalesce(reservation.amount_due, 0)), 2) AS "amountDue"
        FROM public.reservations reservation
        LEFT JOIN public.admin_subjects subject ON subject.id = reservation.subject_id
        WHERE reservation."Deleted" = 0
          AND reservation.status <> 'cancelled'
          AND reservation.start_at >= period_start::timestamp
          AND reservation.start_at < period_end::timestamp
        GROUP BY reservation.subject_id, coalesce(subject.display_name, reservation.team_name, reservation.subject_id::text)
      ) monthly
    ), '[]'::jsonb)
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_team_season_price_json(public.team_season_prices) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_update_subject(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_create_team_season_price(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_calculate_monthly_payment_due(date) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_update_subject(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_team_season_price(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_calculate_monthly_payment_due(date) TO authenticated;
