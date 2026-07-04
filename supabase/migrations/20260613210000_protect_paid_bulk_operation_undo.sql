CREATE OR REPLACE FUNCTION public.admin_undo_bulk_operation(p_operation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  operation public.admin_bulk_operations%ROWTYPE;
  target_reservation public.reservations%ROWTYPE;
  deleted_group public.reservation_groups%ROWTYPE;
  deleted jsonb := '[]'::jsonb;
  skipped_paid jsonb := '[]'::jsonb;
  deleted_reservation_groups jsonb := '[]'::jsonb;
  affected_group_ids uuid[] := ARRAY[]::uuid[];
  active_children_count integer := 0;
BEGIN
  SELECT *
  INTO operation
  FROM public.admin_bulk_operations
  WHERE id = p_operation_id
    AND "Deleted" = 0;

  IF operation.id IS NULL THEN
    RAISE EXCEPTION 'Bulk operation not found' USING ERRCODE = '22023';
  END IF;

  IF operation.status <> 'applied' THEN
    RAISE EXCEPTION 'Only applied bulk operations can be undone' USING ERRCODE = '22023';
  END IF;

  IF operation.operation_type = 'reservation_create' THEN
    SELECT coalesce(jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at), '[]'::jsonb)
    INTO skipped_paid
    FROM public.reservations reservation
    WHERE reservation.bulk_operation_id = operation.id
      AND reservation."Deleted" = 0
      AND reservation.status <> 'cancelled'
      AND reservation.payment_status = 'paid';

    FOR target_reservation IN
      UPDATE public.reservations AS reservation
      SET "Deleted" = 1,
          updated_by = actor_id,
          updated_at = now()
      WHERE reservation.bulk_operation_id = operation.id
        AND reservation."Deleted" = 0
        AND reservation.status <> 'cancelled'
        AND reservation.payment_status <> 'paid'
      RETURNING reservation.*
    LOOP
      IF target_reservation.reservation_group_id IS NOT NULL
        AND NOT target_reservation.reservation_group_id = ANY(affected_group_ids) THEN
        affected_group_ids := array_append(affected_group_ids, target_reservation.reservation_group_id);
      END IF;

      UPDATE public.admin_bulk_operation_items item
      SET status = 'undone',
          updated_by = actor_id,
          updated_at = now()
      WHERE item.bulk_operation_id = operation.id
        AND item.reservation_id = target_reservation.id;

      deleted := deleted || jsonb_build_array(public.admin_reservation_json(target_reservation));
    END LOOP;

    FOR deleted_group IN
      UPDATE public.reservation_groups AS reservation_group
      SET "Deleted" = 1,
          status = 'deleted',
          updated_by = actor_id,
          updated_at = now()
      WHERE reservation_group."Deleted" = 0
        AND reservation_group.id = ANY(affected_group_ids)
        AND NOT EXISTS (
          SELECT 1
          FROM public.reservations reservation
          WHERE reservation.reservation_group_id = reservation_group.id
            AND reservation."Deleted" = 0
            AND reservation.status <> 'cancelled'
        )
      RETURNING reservation_group.*
    LOOP
      deleted_reservation_groups := deleted_reservation_groups || jsonb_build_array(public.admin_reservation_group_json(deleted_group));
      PERFORM public.audit_log('delete', 'reservation_group', deleted_group.id, deleted_group.label, to_jsonb(deleted_group), NULL);
    END LOOP;

    SELECT count(*)
    INTO active_children_count
    FROM public.reservations reservation
    WHERE reservation.bulk_operation_id = operation.id
      AND reservation."Deleted" = 0
      AND reservation.status <> 'cancelled';

    IF active_children_count = 0 THEN
      UPDATE public.admin_bulk_operations
      SET status = 'undone',
          undone_by = actor_id,
          "undoneDT" = now(),
          updated_by = actor_id,
          updated_at = now()
      WHERE id = operation.id
      RETURNING * INTO operation;
    ELSE
      UPDATE public.admin_bulk_operations
      SET updated_by = actor_id,
          updated_at = now()
      WHERE id = operation.id
      RETURNING * INTO operation;
    END IF;
  ELSIF operation.operation_type = 'reservation_delete' THEN
    UPDATE public.reservations
    SET "Deleted" = 0,
        updated_by = actor_id,
        updated_at = now()
    WHERE id IN (
      SELECT item.reservation_id
      FROM public.admin_bulk_operation_items item
      WHERE item.bulk_operation_id = operation.id
        AND item.reservation_id IS NOT NULL
    );

    UPDATE public.admin_bulk_operation_items
    SET status = 'undone',
        updated_by = actor_id,
        updated_at = now()
    WHERE bulk_operation_id = operation.id;

    UPDATE public.admin_bulk_operations
    SET status = 'undone',
        undone_by = actor_id,
        "undoneDT" = now(),
        updated_by = actor_id,
        updated_at = now()
    WHERE id = operation.id
    RETURNING * INTO operation;
  END IF;

  RETURN jsonb_build_object(
    'operation', public.admin_bulk_operation_json(operation),
    'deleted', deleted,
    'skippedPaid', skipped_paid,
    'deletedReservationGroups', deleted_reservation_groups
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_undo_bulk_operation(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_undo_bulk_operation(uuid) TO authenticated;
