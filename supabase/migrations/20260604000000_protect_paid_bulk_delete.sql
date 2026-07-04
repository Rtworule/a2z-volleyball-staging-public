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
    AND reservation.paid = 0
    AND reservation.payment_status <> 'paid'
    AND (reservation.subject_id = p_subject_id OR reservation.user_id = p_subject_id)
    AND reservation.start_at < delete_end_at
    AND delete_start_at < reservation.end_at;

  SELECT coalesce(jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at), '[]'::jsonb)
  INTO skipped_paid
  FROM public.reservations reservation
  WHERE reservation."Deleted" = 0
    AND reservation.status <> 'cancelled'
    AND (reservation.paid = 1 OR reservation.payment_status = 'paid')
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
    AND (reservation.paid = 1 OR reservation.payment_status = 'paid')
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
      AND target.paid = 0
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
      deleted_reservation.paid,
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
