CREATE TABLE IF NOT EXISTS public.reservation_groups (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  label text NOT NULL,
  subject_id uuid REFERENCES public.subjects(id) ON DELETE RESTRICT,
  subject_team_id uuid REFERENCES public.subject_teams(id) ON DELETE RESTRICT,
  bulk_operation_id uuid UNIQUE REFERENCES public.admin_bulk_operations(id) ON DELETE SET NULL,
  resource_type text NOT NULL CHECK (resource_type IN ('court', 'trainer')),
  start_date date NOT NULL,
  end_date date NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'cancelled', 'deleted')),
  requested_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  preview_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES public.profiles(id),
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (start_date <= end_date)
);

CREATE INDEX IF NOT EXISTS reservation_groups_subject_idx
  ON public.reservation_groups(subject_id)
  WHERE "Deleted" = 0;

CREATE INDEX IF NOT EXISTS reservation_groups_subject_team_idx
  ON public.reservation_groups(subject_team_id)
  WHERE "Deleted" = 0;

CREATE INDEX IF NOT EXISTS reservation_groups_window_idx
  ON public.reservation_groups(start_date, end_date)
  WHERE "Deleted" = 0;

DROP TRIGGER IF EXISTS reservation_groups_set_updated_dt ON public.reservation_groups;
CREATE TRIGGER reservation_groups_set_updated_dt BEFORE UPDATE ON public.reservation_groups
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();

ALTER TABLE public.reservation_groups ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read active reservation groups"
  ON public.reservation_groups FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert reservation groups"
  ON public.reservation_groups FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update reservation groups"
  ON public.reservation_groups FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS reservation_group_id uuid;

ALTER TABLE public.reservations
  DROP CONSTRAINT IF EXISTS reservations_reservation_group_id_fkey,
  ADD CONSTRAINT reservations_reservation_group_id_fkey
    FOREIGN KEY (reservation_group_id) REFERENCES public.reservation_groups(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS reservations_reservation_group_idx
  ON public.reservations(reservation_group_id)
  WHERE "Deleted" = 0;

CREATE UNIQUE INDEX IF NOT EXISTS subject_teams_unique_active_name_idx
  ON public.subject_teams(subject_id, lower(name))
  WHERE "Deleted" = 0;

INSERT INTO public.reservation_groups (
  label,
  subject_id,
  subject_team_id,
  bulk_operation_id,
  resource_type,
  start_date,
  end_date,
  status,
  requested_payload,
  preview_payload,
  created_by,
  "Deleted",
  "createdDT",
  "updatedDT",
  created_at,
  updated_at
)
SELECT
  operation.label,
  operation.subject_id,
  (
    SELECT reservation.subject_team_id
    FROM public.reservations reservation
    WHERE reservation.bulk_operation_id = operation.id
      AND reservation.subject_team_id IS NOT NULL
    ORDER BY reservation."createdDT"
    LIMIT 1
  ),
  operation.id,
  coalesce(nullif(operation.requested_payload->>'resourceType', ''), 'court'),
  operation.start_date,
  operation.end_date,
  CASE WHEN operation."Deleted" = 1 THEN 'deleted' ELSE 'active' END,
  coalesce(operation.requested_payload, '{}'::jsonb),
  coalesce(operation.preview_payload, '{}'::jsonb),
  operation.created_by,
  operation."Deleted",
  operation."createdDT",
  operation."updatedDT",
  operation."createdDT",
  operation."updatedDT"
FROM public.admin_bulk_operations operation
WHERE operation.operation_type = 'reservation_create'
ON CONFLICT (bulk_operation_id) DO NOTHING;

UPDATE public.reservations reservation
SET reservation_group_id = reservation_group.id
FROM public.reservation_groups reservation_group
WHERE reservation_group.bulk_operation_id = reservation.bulk_operation_id
  AND reservation.reservation_group_id IS NULL;

CREATE OR REPLACE FUNCTION public.admin_reservation_group_json(reservation_group public.reservation_groups)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', reservation_group.id,
    'label', reservation_group.label,
    'subjectId', reservation_group.subject_id,
    'subjectTeamId', reservation_group.subject_team_id,
    'bulkOperationId', reservation_group.bulk_operation_id,
    'resourceType', reservation_group.resource_type,
    'startDate', reservation_group.start_date,
    'endDate', reservation_group.end_date,
    'status', reservation_group.status,
    'deleted', reservation_group."Deleted" = 1,
    'createdDT', reservation_group."createdDT",
    'updatedDT', reservation_group."updatedDT"
  );
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
    'subjectTeamId', reservation.subject_team_id,
    'teamName', team.name,
    'teamShortName', team.short_name,
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
    'reservationSource', reservation.reservation_source,
    'deleted', reservation."Deleted" = 1,
    'bulkOperationId', reservation.bulk_operation_id,
    'reservationGroupId', reservation.reservation_group_id,
    'createdDT', reservation."createdDT",
    'updatedDT', reservation."updatedDT"
  )
  FROM public.reservations base
  LEFT JOIN public.subject_teams team ON team.id = reservation.subject_team_id
  WHERE base.id = reservation.id;
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
  reservation_group public.reservation_groups%ROWTYPE;
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

  INSERT INTO public.reservation_groups (
    label,
    subject_id,
    subject_team_id,
    bulk_operation_id,
    resource_type,
    start_date,
    end_date,
    status,
    requested_payload,
    preview_payload,
    created_by
  ) VALUES (
    operation.label,
    operation.subject_id,
    nullif(payload->>'subjectTeamId', '')::uuid,
    operation.id,
    coalesce(nullif(payload->>'resourceType', ''), 'court'),
    operation.start_date,
    operation.end_date,
    'active',
    payload,
    preview,
    actor_id
  ) RETURNING * INTO reservation_group;

  FOR item IN SELECT value FROM jsonb_array_elements(preview->'items')
  LOOP
    IF item->>'status' = 'conflict' THEN
      INSERT INTO public.admin_bulk_operation_items (
        bulk_operation_id, action, subject_id, subject_team_id, resource_type, court_number, start_at, end_at, season_price_id, season_label, hourly_rate, amount_due, paid, status, conflict_reason
      ) VALUES (
        operation.id, 'create', nullif(item->>'subjectId', '')::uuid, nullif(item->>'subjectTeamId', '')::uuid, item->>'resourceType', nullif(replace(coalesce(item->>'courtId', ''), 'court-', ''), '')::integer,
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
        user_id, team_name, subject_id, subject_team_id, resource_type, court_number, start_at, end_at, status, payment_status, season_price_id, season_label, hourly_rate, amount, created_by, bulk_operation_id, reservation_group_id, reservation_source
      ) VALUES (
        NULL,
        coalesce(item->>'teamName', item->>'subjectName'),
        nullif(item->>'subjectId', '')::uuid,
        nullif(item->>'subjectTeamId', '')::uuid,
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
        operation.id,
        reservation_group.id,
        coalesce(nullif(payload->>'source', ''), 'bulk')
      ) RETURNING * INTO reservation;

      INSERT INTO public.admin_bulk_operation_items (
        bulk_operation_id, reservation_id, action, subject_id, subject_team_id, resource_type, court_number, start_at, end_at, season_price_id, season_label, hourly_rate, amount_due, paid, status
      ) VALUES (
        operation.id, reservation.id, 'create', reservation.subject_id, reservation.subject_team_id, reservation.resource_type, reservation.court_number, reservation.start_at, reservation.end_at,
        reservation.season_price_id, reservation.season_label, reservation.hourly_rate, reservation.amount, CASE WHEN reservation.payment_status = 'paid' THEN 1 ELSE 0 END, 'applied'
      );

      PERFORM public.audit_log(
        'create',
        'reservation',
        reservation.id,
        reservation.team_name,
        NULL,
        public.admin_reservation_json(reservation),
        jsonb_build_object(
          'source', coalesce(nullif(payload->>'source', ''), 'bulk'),
          'bulkOperationId', operation.id,
          'reservationGroupId', reservation_group.id
        )
      );

      created := created || jsonb_build_array(public.admin_reservation_json(reservation));
    END LOOP;
  END LOOP;

  PERFORM public.audit_log('create', 'reservation_group', reservation_group.id, reservation_group.label, NULL, public.admin_reservation_group_json(reservation_group));
  PERFORM public.audit_log('create', 'bulk_reservation', operation.id, operation.label, NULL, public.admin_bulk_operation_json(operation));

  RETURN jsonb_build_object(
    'operation', public.admin_bulk_operation_json(operation),
    'reservationGroup', public.admin_reservation_group_json(reservation_group),
    'created', created,
    'items', preview->'items'
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_reservation_group_json(public.reservation_groups) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_apply_bulk_reservations(jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_reservation_group_json(public.reservation_groups) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_bulk_reservations(jsonb) TO authenticated;
