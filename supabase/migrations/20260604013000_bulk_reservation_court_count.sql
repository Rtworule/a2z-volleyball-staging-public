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
  paid_flag boolean := coalesce((payload->>'paid')::boolean, false);
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

    court_ids := CASE
      WHEN item->>'resourceType' = 'court' THEN coalesce(item->'courtIds', jsonb_build_array(item->>'courtId'))
      ELSE jsonb_build_array(NULL)
    END;

    FOR court_id IN SELECT value FROM jsonb_array_elements_text(court_ids)
    LOOP
      INSERT INTO public.reservations (
        user_id, team_name, subject_id, resource_type, court_number, start_at, end_at, status, payment_status, paid, season_price_id, season_label, hourly_rate, amount_due, created_by, bulk_operation_id
      ) VALUES (
        NULL,
        item->>'subjectName',
        (item->>'subjectId')::uuid,
        item->>'resourceType',
        nullif(replace(coalesce(court_id, ''), 'court-', ''), '')::integer,
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
  END LOOP;

  RETURN jsonb_build_object('operation', public.admin_bulk_operation_json(operation), 'created', created, 'items', preview->'items');
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_bulk_preview_items(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_apply_bulk_reservations(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_bulk_preview_items(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_bulk_reservations(jsonb) TO authenticated;
