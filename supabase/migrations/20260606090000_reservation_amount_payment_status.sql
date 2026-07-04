ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS amount numeric(10, 2);

DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'reservations'
      AND column_name = 'amount_due'
  ) THEN
    UPDATE public.reservations
    SET amount = amount_due
    WHERE amount IS NULL;
  END IF;
END;
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
    'seasonPriceId', reservation.season_price_id,
    'seasonLabel', reservation.season_label,
    'hourlyRate', reservation.hourly_rate,
    'amount', reservation.amount,
    'deleted', reservation."Deleted" = 1,
    'bulkOperationId', reservation.bulk_operation_id,
    'createdDT', reservation."createdDT",
    'updatedDT', reservation."updatedDT"
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_mark_reservation_paid(p_reservation_id uuid, p_paid boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  reservation public.reservations%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  UPDATE public.reservations
  SET payment_status = CASE WHEN p_paid THEN 'paid' ELSE 'due' END,
      updated_at = now()
  WHERE id = p_reservation_id
    AND "Deleted" = 0
  RETURNING * INTO reservation;

  IF reservation.id IS NULL THEN
    RAISE EXCEPTION 'Reservation not found' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_reservation_json(reservation);
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
  court_count_needed integer := greatest(1, coalesce((payload->>'courtCountNeeded')::integer, 1));
  selected_rate numeric(8, 2);
  selected_label text;
  allowed_days integer[];
  slot_start_at timestamptz;
  slot_end_at timestamptz;
  resolved_courts integer[] := ARRAY[]::integer[];
  item_status text;
  conflict_reason text;
  trainer_usage integer;
  items jsonb := '[]'::jsonb;
BEGIN
  IF actor_id IS NULL THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;

  IF nullif(payload->>'subjectId', '') IS NULL THEN
    RAISE EXCEPTION 'Select a team or coach before previewing bulk reservations' USING ERRCODE = '22023';
  END IF;

  IF resource NOT IN ('court', 'trainer') THEN
    RAISE EXCEPTION 'resourceType must be court or trainer' USING ERRCODE = '22023';
  END IF;

  IF end_date < local_date THEN
    RAISE EXCEPTION 'End date must be on or after start date' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO subject
  FROM public.admin_subjects
  WHERE id = nullif(payload->>'subjectId', '')::uuid
    AND "Deleted" = 0;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Team or coach record not found' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO config FROM public.facility_config WHERE id = true;

  IF nullif(payload->>'seasonPriceId', '') IS NOT NULL THEN
    SELECT * INTO season_price
    FROM public.team_season_prices
    WHERE id = nullif(payload->>'seasonPriceId', '')::uuid
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
      resolved_courts := ARRAY[]::integer[];
      item_status := 'preview';
      conflict_reason := null;

      IF slot_start_time < (SELECT open_time FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer)
        OR (slot_start_time + make_interval(mins => duration_minutes))::time > (SELECT close_time FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer)
        OR coalesce((SELECT is_closed FROM public.operating_hours WHERE day_of_week = extract(dow FROM local_date)::integer), true) THEN
        item_status := 'conflict';
        conflict_reason := 'Outside operating hours';
      END IF;

      IF item_status = 'preview' AND resource = 'court' THEN
        IF requested_court IS NOT NULL THEN
          IF requested_court BETWEEN 1 AND config.court_count
            AND NOT EXISTS (
              SELECT 1 FROM public.reservations reservation
              WHERE reservation."Deleted" = 0
                AND reservation.status <> 'cancelled'
                AND reservation.resource_type = 'court'
                AND reservation.court_number = requested_court
                AND reservation.start_at < slot_end_at
                AND slot_start_at < reservation.end_at
            )
            AND NOT EXISTS (
              SELECT 1 FROM public.fixed_reservations fixed
              WHERE fixed."Deleted" = 0
                AND fixed.resource_type = 'court'
                AND fixed.court_number = requested_court
                AND extract(dow FROM local_date)::integer = ANY(fixed.days_of_week)
                AND local_date BETWEEN fixed.start_date AND fixed.end_date
                AND fixed.start_time < (slot_start_time + make_interval(mins => duration_minutes))::time
                AND slot_start_time < fixed.end_time
            )
            AND NOT EXISTS (
              SELECT 1 FROM public.closures closure
              WHERE closure."Deleted" = 0
                AND closure.start_at < slot_end_at
                AND slot_start_at < closure.end_at
                AND (closure.resource_type = 'all' OR closure.resource_type = 'court')
                AND (closure.court_number IS NULL OR closure.court_number = requested_court)
            ) THEN
            resolved_courts := array_append(resolved_courts, requested_court);
          ELSE
            item_status := 'conflict';
            conflict_reason := 'No Court Available';
          END IF;
        END IF;

        IF item_status = 'preview' AND cardinality(resolved_courts) < court_count_needed THEN
          SELECT resolved_courts || coalesce(array_agg(candidate.court_number ORDER BY candidate.court_number), ARRAY[]::integer[])
          INTO resolved_courts
          FROM (
            SELECT available_court.court_number
            FROM generate_series(1, config.court_count) AS available_court(court_number)
            WHERE available_court.court_number <> ALL(resolved_courts)
              AND NOT EXISTS (
                SELECT 1 FROM public.reservations reservation
                WHERE reservation."Deleted" = 0
                  AND reservation.status <> 'cancelled'
                  AND reservation.resource_type = 'court'
                  AND reservation.court_number = available_court.court_number
                  AND reservation.start_at < slot_end_at
                  AND slot_start_at < reservation.end_at
              )
              AND NOT EXISTS (
                SELECT 1 FROM public.fixed_reservations fixed
                WHERE fixed."Deleted" = 0
                  AND fixed.resource_type = 'court'
                  AND fixed.court_number = available_court.court_number
                  AND extract(dow FROM local_date)::integer = ANY(fixed.days_of_week)
                  AND local_date BETWEEN fixed.start_date AND fixed.end_date
                  AND fixed.start_time < (slot_start_time + make_interval(mins => duration_minutes))::time
                  AND slot_start_time < fixed.end_time
              )
              AND NOT EXISTS (
                SELECT 1 FROM public.closures closure
                WHERE closure."Deleted" = 0
                  AND closure.start_at < slot_end_at
                  AND slot_start_at < closure.end_at
                  AND (closure.resource_type = 'all' OR closure.resource_type = 'court')
                  AND (closure.court_number IS NULL OR closure.court_number = available_court.court_number)
              )
            ORDER BY available_court.court_number
            LIMIT court_count_needed - cardinality(resolved_courts)
          ) candidate;
        END IF;

        IF item_status = 'preview' AND cardinality(resolved_courts) < court_count_needed THEN
          item_status := 'conflict';
          conflict_reason := 'No Court Available';
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
        'courtId', CASE WHEN resource = 'court' AND cardinality(resolved_courts) > 0 THEN 'court-' || resolved_courts[1] ELSE NULL END,
        'courtIds', CASE WHEN resource = 'court' THEN (
          SELECT coalesce(jsonb_agg('court-' || court_number ORDER BY ordinality), '[]'::jsonb)
          FROM unnest(resolved_courts) WITH ORDINALITY AS resolved(court_number, ordinality)
        ) ELSE '[]'::jsonb END,
        'courtCountNeeded', CASE WHEN resource = 'court' THEN court_count_needed ELSE 1 END,
        'start', slot_start_at,
        'end', slot_end_at,
        'seasonPriceId', season_price.id,
        'seasonLabel', selected_label,
        'hourlyRate', selected_rate,
        'amount', round(selected_rate * duration_minutes / 60.0, 2),
        'paymentStatus', coalesce(nullif(payload->>'paymentStatus', ''), 'due'),
        'status', item_status,
        'conflictReason', conflict_reason
      ));
    END IF;

    local_date := local_date + 1;
  END LOOP;

  RETURN items;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_preview_bulk_reservations(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  items jsonb := public.admin_bulk_preview_items(payload);
BEGIN
  RETURN jsonb_build_object(
    'id', payload->>'id',
    'operationType', 'reservation_create',
    'label', coalesce(payload->>'label', 'Bulk reservation'),
    'status', CASE WHEN nullif(payload->>'applyAfter', '') IS NULL THEN 'previewed' ELSE 'scheduled' END,
    'applyAfter', nullif(payload->>'applyAfter', ''),
    'paymentStatus', coalesce(nullif(payload->>'paymentStatus', ''), 'due'),
    'conflictResolution', coalesce(payload->>'conflictResolution', 'skip_conflicts'),
    'requestedPayload', payload,
    'items', items
  );
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
  court_id text;
  court_ids jsonb;
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
    nullif(payload->>'subjectId', '')::uuid,
    (payload->>'startDate')::date,
    coalesce((payload->>'endDate')::date, (payload->>'startDate')::date),
    'applied',
    CASE WHEN coalesce(payload->>'paymentStatus', 'due') = 'paid' THEN 1 ELSE 0 END,
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
        operation.id, 'create', nullif(item->>'subjectId', '')::uuid, item->>'resourceType', nullif(replace(coalesce(item->>'courtId', ''), 'court-', ''), '')::integer,
        (item->>'start')::timestamptz, (item->>'end')::timestamptz, nullif(item->>'seasonPriceId', '')::uuid, item->>'seasonLabel',
        nullif(item->>'hourlyRate', '')::numeric, nullif(item->>'amount', '')::numeric,
        CASE WHEN coalesce(item->>'paymentStatus', 'due') = 'paid' THEN 1 ELSE 0 END, 'skipped', item->>'conflictReason'
      );
      CONTINUE;
    END IF;

    court_ids := CASE
      WHEN item->>'resourceType' = 'court' THEN coalesce(item->'courtIds', jsonb_build_array(item->>'courtId'))
      ELSE jsonb_build_array(NULL)
    END;

    FOR court_id IN SELECT value FROM jsonb_array_elements_text(court_ids)
    LOOP
      INSERT INTO public.reservations (
        user_id, team_name, subject_id, resource_type, court_number, start_at, end_at, status, payment_status, season_price_id, season_label, hourly_rate, amount, created_by, bulk_operation_id
      ) VALUES (
        NULL,
        item->>'subjectName',
        nullif(item->>'subjectId', '')::uuid,
        item->>'resourceType',
        nullif(replace(coalesce(court_id, ''), 'court-', ''), '')::integer,
        (item->>'start')::timestamptz,
        (item->>'end')::timestamptz,
        'confirmed',
        coalesce(nullif(item->>'paymentStatus', ''), 'due'),
        nullif(item->>'seasonPriceId', '')::uuid,
        item->>'seasonLabel',
        nullif(item->>'hourlyRate', '')::numeric,
        nullif(item->>'amount', '')::numeric,
        actor_id,
        operation.id
      ) RETURNING * INTO reservation;

      INSERT INTO public.admin_bulk_operation_items (
        bulk_operation_id, reservation_id, action, subject_id, resource_type, court_number, start_at, end_at, season_price_id, season_label, hourly_rate, amount_due, paid, status
      ) VALUES (
        operation.id, reservation.id, 'create', reservation.subject_id, reservation.resource_type, reservation.court_number, reservation.start_at, reservation.end_at,
        reservation.season_price_id, reservation.season_label, reservation.hourly_rate, reservation.amount, CASE WHEN reservation.payment_status = 'paid' THEN 1 ELSE 0 END, 'applied'
      );

      created := created || jsonb_build_array(public.admin_reservation_json(reservation));
    END LOOP;
  END LOOP;

  RETURN jsonb_build_object('operation', public.admin_bulk_operation_json(operation), 'created', created, 'items', preview->'items');
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_save_bulk_reservations(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  preview jsonb := public.admin_preview_bulk_reservations(payload);
  operation public.admin_bulk_operations%ROWTYPE;
  item jsonb;
BEGIN
  INSERT INTO public.admin_bulk_operations (
    operation_type,
    label,
    subject_id,
    start_date,
    end_date,
    status,
    apply_after,
    paid,
    conflict_resolution,
    requested_payload,
    preview_payload,
    created_by
  ) VALUES (
    'reservation_create',
    coalesce(payload->>'label', 'Bulk reservation'),
    nullif(payload->>'subjectId', '')::uuid,
    (payload->>'startDate')::date,
    coalesce((payload->>'endDate')::date, (payload->>'startDate')::date),
    CASE WHEN nullif(payload->>'applyAfter', '') IS NULL THEN 'previewed' ELSE 'scheduled' END,
    nullif(payload->>'applyAfter', '')::timestamptz,
    CASE WHEN coalesce(payload->>'paymentStatus', 'due') = 'paid' THEN 1 ELSE 0 END,
    coalesce(payload->>'conflictResolution', 'skip_conflicts'),
    payload,
    preview,
    actor_id
  )
  RETURNING * INTO operation;

  FOR item IN SELECT value FROM jsonb_array_elements(preview->'items')
  LOOP
    INSERT INTO public.admin_bulk_operation_items (
      bulk_operation_id,
      action,
      subject_id,
      resource_type,
      court_number,
      start_at,
      end_at,
      season_price_id,
      season_label,
      hourly_rate,
      amount_due,
      paid,
      status,
      conflict_reason
    ) VALUES (
      operation.id,
      'create',
      nullif(item->>'subjectId', '')::uuid,
      item->>'resourceType',
      nullif(replace(coalesce(item->>'courtId', ''), 'court-', ''), '')::integer,
      (item->>'start')::timestamptz,
      (item->>'end')::timestamptz,
      nullif(item->>'seasonPriceId', '')::uuid,
      item->>'seasonLabel',
      nullif(item->>'hourlyRate', '')::numeric,
      nullif(item->>'amount', '')::numeric,
      CASE WHEN coalesce(item->>'paymentStatus', 'due') = 'paid' THEN 1 ELSE 0 END,
      CASE WHEN item->>'status' = 'conflict' THEN 'conflict' ELSE 'preview' END,
      item->>'conflictReason'
    );
  END LOOP;

  RETURN public.admin_bulk_operation_json(operation) || jsonb_build_object('items', preview->'items');
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_preview_delete_reservations(p_subject_id uuid, p_start_date date, p_end_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  facility_timezone text := (SELECT timezone FROM public.facility_config WHERE id = true);
  delete_start_at timestamptz;
  delete_end_at timestamptz;
  deletable jsonb := '[]'::jsonb;
  skipped_paid jsonb := '[]'::jsonb;
BEGIN
  PERFORM public.admin_require_approved();
  delete_start_at := p_start_date::timestamp AT TIME ZONE facility_timezone;
  delete_end_at := (p_end_date + 1)::timestamp AT TIME ZONE facility_timezone;

  SELECT coalesce(jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at), '[]'::jsonb)
  INTO deletable
  FROM public.reservations reservation
  WHERE reservation."Deleted" = 0
    AND reservation.status <> 'cancelled'
    AND reservation.payment_status <> 'paid'
    AND (reservation.subject_id = p_subject_id OR reservation.user_id = p_subject_id)
    AND reservation.start_at < delete_end_at
    AND delete_start_at < reservation.end_at;

  SELECT coalesce(jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at), '[]'::jsonb)
  INTO skipped_paid
  FROM public.reservations reservation
  WHERE reservation."Deleted" = 0
    AND reservation.status <> 'cancelled'
    AND reservation.payment_status = 'paid'
    AND (reservation.subject_id = p_subject_id OR reservation.user_id = p_subject_id)
    AND reservation.start_at < delete_end_at
    AND delete_start_at < reservation.end_at;

  RETURN jsonb_build_object(
    'deletable', deletable,
    'skippedPaid', skipped_paid
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_apply_delete_reservations(p_subject_id uuid, p_start_date date, p_end_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.admin_subjects%ROWTYPE;
  operation public.admin_bulk_operations%ROWTYPE;
  deleted_reservation public.reservations%ROWTYPE;
  deleted jsonb := '[]'::jsonb;
  skipped_paid jsonb := '[]'::jsonb;
  facility_timezone text := (SELECT timezone FROM public.facility_config WHERE id = true);
  delete_start_at timestamptz;
  delete_end_at timestamptz;
BEGIN
  delete_start_at := p_start_date::timestamp AT TIME ZONE facility_timezone;
  delete_end_at := (p_end_date + 1)::timestamp AT TIME ZONE facility_timezone;

  SELECT *
  INTO subject
  FROM public.admin_subjects
  WHERE id = p_subject_id
    AND "Deleted" = 0;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Team or coach record not found' USING ERRCODE = '22023';
  END IF;

  SELECT coalesce(jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at), '[]'::jsonb)
  INTO skipped_paid
  FROM public.reservations reservation
  WHERE reservation."Deleted" = 0
    AND reservation.status <> 'cancelled'
    AND reservation.payment_status = 'paid'
    AND (reservation.subject_id = p_subject_id OR reservation.user_id = p_subject_id)
    AND reservation.start_at < delete_end_at
    AND delete_start_at < reservation.end_at;

  INSERT INTO public.admin_bulk_operations (
    operation_type,
    label,
    subject_id,
    start_date,
    end_date,
    status,
    requested_payload,
    created_by,
    applied_by,
    "appliedDT"
  ) VALUES (
    'reservation_delete',
    'Delete unpaid reservations for ' || subject.display_name,
    subject.id,
    p_start_date,
    p_end_date,
    'applied',
    jsonb_build_object(
      'subjectId', p_subject_id,
      'startDate', p_start_date,
      'endDate', p_end_date,
      'skippedPaidCount', jsonb_array_length(skipped_paid)
    ),
    actor_id,
    actor_id,
    now()
  )
  RETURNING * INTO operation;

  FOR deleted_reservation IN
    UPDATE public.reservations AS target
    SET "Deleted" = 1,
        bulk_operation_id = operation.id,
        updated_at = now()
    WHERE target."Deleted" = 0
      AND target.status <> 'cancelled'
      AND target.payment_status <> 'paid'
      AND (target.subject_id = p_subject_id OR target.user_id = p_subject_id)
      AND target.start_at < delete_end_at
      AND delete_start_at < target.end_at
    RETURNING target.*
  LOOP
    INSERT INTO public.admin_bulk_operation_items (
      bulk_operation_id, reservation_id, action, subject_id, resource_type, court_number, start_at, end_at, paid, status
    ) VALUES (
      operation.id,
      deleted_reservation.id,
      'delete',
      deleted_reservation.subject_id,
      deleted_reservation.resource_type,
      deleted_reservation.court_number,
      deleted_reservation.start_at,
      deleted_reservation.end_at,
      0,
      'applied'
    );

    deleted := deleted || jsonb_build_array(public.admin_reservation_json(deleted_reservation));
  END LOOP;

  RETURN jsonb_build_object(
    'operation', public.admin_bulk_operation_json(operation),
    'deleted', deleted,
    'skippedPaid', skipped_paid
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_reservation(p_reservation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  reservation public.reservations%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  UPDATE public.reservations
  SET "Deleted" = 1,
      updated_at = now()
  WHERE id = p_reservation_id
    AND "Deleted" = 0
    AND payment_status <> 'paid'
    AND start_at >= now()
  RETURNING * INTO reservation;

  IF reservation.id IS NULL THEN
    RAISE EXCEPTION 'Future unpaid reservation not found' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_reservation_json(reservation);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_mark_payment_paid(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  payment public.payments%ROWTYPE;
  reservation_ids uuid[] := coalesce(ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(coalesce(payload->'reservationIds', '[]'::jsonb)) AS value), ARRAY[]::uuid[]);
  payment_key text := coalesce(nullif(payload->>'paymentKey', ''), md5(coalesce(payload->>'subjectId', '') || coalesce(payload->>'billingRule', '') || coalesce(payload->>'periodStart', '') || coalesce(payload->>'periodEnd', '') || reservation_ids::text));
BEGIN
  INSERT INTO public.payments (
    payment_key,
    subject_id,
    subject_name,
    subject_type,
    contact_email,
    billing_rule,
    period_start,
    period_end,
    amount_due,
    minutes,
    reservation_ids,
    status,
    paid_at,
    created_by
  ) VALUES (
    payment_key,
    nullif(payload->>'subjectId', '')::uuid,
    payload->>'subjectName',
    coalesce(payload->>'subjectType', 'user'),
    nullif(payload->>'contactEmail', ''),
    coalesce(payload->>'billingRule', 'manual'),
    nullif(payload->>'periodStart', '')::date,
    nullif(payload->>'periodEnd', '')::date,
    coalesce((payload->>'amount')::numeric, 0),
    coalesce((payload->>'minutes')::integer, 0),
    reservation_ids,
    'paid',
    now(),
    actor_id
  )
  ON CONFLICT (payment_key) DO UPDATE SET
    amount_due = excluded.amount_due,
    minutes = excluded.minutes,
    reservation_ids = excluded.reservation_ids,
    status = 'paid',
    paid_at = coalesce(public.payments.paid_at, now()),
    "updatedDT" = now()
  RETURNING * INTO payment;

  UPDATE public.reservations
  SET payment_status = 'paid',
      updated_at = now()
  WHERE id = ANY(payment.reservation_ids)
    AND "Deleted" = 0;

  IF payment.invoice_id IS NOT NULL THEN
    UPDATE public.invoices
    SET status = 'paid',
        "updatedDT" = now()
    WHERE id = payment.invoice_id;
  END IF;

  RETURN public.admin_payment_json(payment);
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
      SELECT jsonb_agg(row_to_json(monthly) ORDER BY monthly."teamName")
      FROM (
        SELECT
          reservation.subject_id AS "subjectId",
          coalesce(subject.display_name, reservation.team_name, reservation.subject_id::text) AS "teamName",
          count(*) AS "reservationCount",
          round(sum(extract(epoch FROM (reservation.end_at - reservation.start_at)) / 3600.0), 2) AS "hours",
          round(sum(coalesce(reservation.amount, 0)), 2) AS "amount"
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

ALTER TABLE public.reservations
  DROP COLUMN IF EXISTS paid,
  DROP COLUMN IF EXISTS amount_due;

REVOKE EXECUTE ON FUNCTION public.admin_reservation_json(public.reservations) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_mark_reservation_paid(uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_bulk_preview_items(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_preview_bulk_reservations(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_save_bulk_reservations(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_apply_bulk_reservations(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_preview_delete_reservations(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_apply_delete_reservations(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_reservation(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_mark_payment_paid(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_calculate_monthly_payment_due(date) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_reservation_json(public.reservations) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mark_reservation_paid(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_bulk_preview_items(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_preview_bulk_reservations(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_bulk_reservations(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_bulk_reservations(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_preview_delete_reservations(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_delete_reservations(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_reservation(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mark_payment_paid(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_calculate_monthly_payment_due(date) TO authenticated;
