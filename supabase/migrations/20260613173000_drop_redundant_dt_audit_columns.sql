DO $$
DECLARE
  audit_table text;
  audit_tables text[] := ARRAY[
    'admin_bulk_operation_items',
    'admin_bulk_operations',
    'admin_menu_items',
    'audit_events',
    'auth_provider_options',
    'client_types',
    'closures',
    'facility_config',
    'fixed_reservations',
    'invoices',
    'operating_hours',
    'payments',
    'profiles',
    'reservation_groups',
    'reservations',
    'resources',
    'seasons',
    'subject_memberships',
    'subject_teams',
    'subjects',
    'team_season_prices'
  ];
  has_created_dt boolean;
  has_updated_dt boolean;
BEGIN
  FOREACH audit_table IN ARRAY audit_tables
  LOOP
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS created_at timestamptz', audit_table);
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS updated_at timestamptz', audit_table);

    SELECT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = audit_table
        AND column_name = 'createdDT'
    ) INTO has_created_dt;

    SELECT EXISTS (
      SELECT 1
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND table_name = audit_table
        AND column_name = 'updatedDT'
    ) INTO has_updated_dt;

    IF has_created_dt THEN
      EXECUTE format('UPDATE public.%I SET created_at = "createdDT" WHERE created_at IS NULL', audit_table);
    END IF;

    IF has_updated_dt THEN
      EXECUTE format('UPDATE public.%I SET updated_at = "updatedDT" WHERE updated_at IS NULL', audit_table);
    END IF;

    EXECUTE format('UPDATE public.%I SET created_at = now() WHERE created_at IS NULL', audit_table);
    EXECUTE format('UPDATE public.%I SET updated_at = coalesce(created_at, now()) WHERE updated_at IS NULL', audit_table);
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN created_at SET DEFAULT now()', audit_table);
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN updated_at SET DEFAULT now()', audit_table);
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN created_at SET NOT NULL', audit_table);
    EXECUTE format('ALTER TABLE public.%I ALTER COLUMN updated_at SET NOT NULL', audit_table);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.set_updated_dt()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_audit_fields()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor_id uuid := auth.uid();
  audit_patch jsonb := jsonb_build_object(
    'updated_at', now()
  );
BEGIN
  IF actor_id IS NOT NULL THEN
    audit_patch := audit_patch || jsonb_build_object('updated_by', actor_id);
  END IF;

  IF TG_OP = 'INSERT' THEN
    audit_patch := audit_patch || jsonb_build_object(
      'created_at', now()
    );

    IF actor_id IS NOT NULL THEN
      audit_patch := audit_patch || jsonb_build_object('created_by', actor_id);
    END IF;
  END IF;

  NEW := jsonb_populate_record(NEW, audit_patch);
  RETURN NEW;
END;
$$;

DROP VIEW IF EXISTS public.admin_subjects CASCADE;

CREATE OR REPLACE VIEW public.admin_subjects
WITH (security_invoker = true)
AS
SELECT
  id,
  subject_type,
  display_name,
  contact_name,
  contact_email,
  contact_phone,
  notes,
  created_by,
  "Deleted",
  created_at,
  updated_at
FROM public.subjects;

CREATE OR REPLACE FUNCTION public.admin_bulk_operation_json(operation public.admin_bulk_operations)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', operation.id,
    'operationType', operation.operation_type,
    'label', operation.label,
    'subjectId', operation.subject_id,
    'startDate', operation.start_date,
    'endDate', operation.end_date,
    'status', operation.status,
    'applyAfter', operation.apply_after,
    'paid', operation.paid = 1,
    'conflictResolution', operation.conflict_resolution,
    'requestedPayload', operation.requested_payload,
    'previewPayload', operation.preview_payload,
    'appliedDT', operation."appliedDT",
    'undoneDT', operation."undoneDT",
    'created_at', operation."created_at",
    'updated_at', operation."updated_at"
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_client_type_json(client_type public.client_types)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', client_type.id,
    'name', client_type.name,
    'haveTeams', client_type.have_teams,
    'sortOrder', client_type.sort_order,
    'deleted', client_type."Deleted" = 1,
    'created_at', client_type."created_at",
    'updated_at', client_type."updated_at"
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_create_invoice(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  saved public.invoices%ROWTYPE;
  payment public.payments%ROWTYPE;
  invoices_json jsonb;
  payments_json jsonb;
  reservation_ids uuid[] := coalesce(ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(coalesce(payload->'reservationIds', '[]'::jsonb)) AS value), ARRAY[]::uuid[]);
  v_payment_key text := coalesce(nullif(payload->>'paymentKey', ''), md5(coalesce(payload->>'subjectId', '') || coalesce(payload->>'billingRule', '') || coalesce(payload->>'periodStart', '') || coalesce(payload->>'periodEnd', '') || reservation_ids::text));
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
    created_by
  ) VALUES (
    v_payment_key,
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
    'invoiced',
    actor_id
  )
  ON CONFLICT (payment_key) DO UPDATE SET
    amount_due = excluded.amount_due,
    minutes = excluded.minutes,
    reservation_ids = excluded.reservation_ids,
    status = CASE WHEN public.payments.status = 'paid' THEN public.payments.status ELSE 'invoiced' END,
    "updated_at" = now()
  RETURNING * INTO payment;

  IF payment.invoice_id IS NOT NULL THEN
    RAISE EXCEPTION 'Invoice already exists for this payment' USING ERRCODE = '23505';
  END IF;

  INSERT INTO public.invoices (
    payment_id,
    payment_key,
    invoice_number,
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
    created_by
  ) VALUES (
    payment.id,
    payment.payment_key,
    coalesce(nullif(payload->>'invoiceNumber', ''), 'A2Z-' || to_char(now() AT TIME ZONE 'America/New_York', 'YYYYMMDDHH24MISS')),
    payment.subject_id,
    payment.subject_name,
    payment.subject_type,
    payment.contact_email,
    payment.billing_rule,
    payment.period_start,
    payment.period_end,
    payment.amount_due,
    payment.minutes,
    payment.reservation_ids,
    actor_id
  ) RETURNING * INTO saved;

  UPDATE public.payments AS target
  SET invoice_id = saved.id,
      status = CASE WHEN target.status = 'paid' THEN target.status ELSE 'invoiced' END,
      "updated_at" = now()
  WHERE target.id = payment.id
  RETURNING target.* INTO payment;

  SELECT coalesce(jsonb_agg(public.admin_invoice_json(invoice) ORDER BY invoice."created_at" DESC), '[]'::jsonb)
  INTO invoices_json
  FROM public.invoices invoice
  WHERE invoice."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_payment_json(payment_record) ORDER BY payment_record."created_at" DESC), '[]'::jsonb)
  INTO payments_json
  FROM public.payments payment_record
  WHERE payment_record."Deleted" = 0;

  RETURN jsonb_build_object(
    'invoice', public.admin_invoice_json(saved),
    'payment', public.admin_payment_json(payment),
    'invoices', invoices_json,
    'payments', payments_json
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_bulk_operation(p_operation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  target public.admin_bulk_operations%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT * INTO target
  FROM public.admin_bulk_operations
  WHERE id = p_operation_id
    AND "Deleted" = 0
    AND status IN ('previewed', 'scheduled');

  IF target.id IS NULL THEN
    RAISE EXCEPTION 'Bulk draft not found' USING ERRCODE = '22023';
  END IF;

  UPDATE public.admin_bulk_operations
  SET "Deleted" = 1,
      "updated_at" = now()
  WHERE id = p_operation_id
  RETURNING * INTO target;

  RETURN public.admin_bulk_operation_json(target);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_client_type(p_client_type_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  client_type public.client_types%ROWTYPE;
  client_count integer;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT count(*) INTO client_count
  FROM public.subjects
  WHERE client_type_id = p_client_type_id
    AND "Deleted" = 0;

  IF client_count > 0 THEN
    RAISE EXCEPTION 'Client type is used by % active client(s). Move those clients before deleting it.', client_count USING ERRCODE = '23503';
  END IF;

  UPDATE public.client_types
  SET "Deleted" = 1,
      "updated_at" = now()
  WHERE id = p_client_type_id
    AND "Deleted" = 0
  RETURNING * INTO client_type;

  IF client_type.id IS NULL THEN
    RAISE EXCEPTION 'Client type not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('delete', 'client_type', client_type.id, client_type.name, to_jsonb(client_type), NULL);

  RETURN public.admin_client_type_json(client_type);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_closure(p_closure_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  closure public.closures%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  UPDATE public.closures
  SET "Deleted" = 1,
      "updated_at" = now()
  WHERE id = p_closure_id
    AND "Deleted" = 0
  RETURNING * INTO closure;

  IF closure.id IS NULL THEN
    RAISE EXCEPTION 'Closed day not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('delete', 'closure', closure.id, closure.reason, to_jsonb(closure), NULL);

  RETURN jsonb_build_object('id', closure.id, 'deleted', true);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_season(p_season_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  season public.seasons%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  IF EXISTS (
    SELECT 1
    FROM public.team_season_prices price
    WHERE price.season_id = p_season_id
      AND price."Deleted" = 0
  ) THEN
    RAISE EXCEPTION 'Season is used by team pricing' USING ERRCODE = '22023';
  END IF;

  UPDATE public.seasons
  SET "Deleted" = 1,
      "updated_at" = now()
  WHERE id = p_season_id
    AND "Deleted" = 0
  RETURNING * INTO season;

  IF season.id IS NULL THEN
    RAISE EXCEPTION 'Season not found' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_season_json(season);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_subject_team(p_team_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  team public.subject_teams%ROWTYPE;
  active_count integer;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT count(*) INTO active_count
  FROM public.reservations
  WHERE subject_team_id = p_team_id
    AND "Deleted" = 0
    AND status <> 'cancelled';

  IF active_count > 0 THEN
    RAISE EXCEPTION 'Team has % active reservation(s). Delete or cancel those reservations before deleting the team.', active_count USING ERRCODE = '23503';
  END IF;

  UPDATE public.subject_teams
  SET "Deleted" = 1,
      "updated_at" = now()
  WHERE id = p_team_id
    AND "Deleted" = 0
  RETURNING * INTO team;

  IF team.id IS NULL THEN
    RAISE EXCEPTION 'Team not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('delete', 'client_team', team.id, team.name, to_jsonb(team), NULL);

  RETURN public.admin_subject_team_json(team);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_delete_team_season_price(p_price_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  price public.team_season_prices%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  UPDATE public.team_season_prices
  SET "Deleted" = 1,
      "updated_at" = now()
  WHERE id = p_price_id
    AND "Deleted" = 0
  RETURNING * INTO price;

  IF price.id IS NULL THEN
    RAISE EXCEPTION 'Season price not found' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_team_season_price_json(price);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_disable_subject(p_subject_id uuid, p_reason text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.admin_subjects%ROWTYPE;
  future_dates text[];
BEGIN
  SELECT array_agg(to_char(reservation.start_at AT TIME ZONE 'America/New_York', 'YYYY-MM-DD HH24:MI') ORDER BY reservation.start_at)
  INTO future_dates
  FROM (
    SELECT reservation.start_at
    FROM public.reservations reservation
    WHERE reservation.subject_id = p_subject_id
      AND reservation."Deleted" = 0
      AND reservation.status <> 'cancelled'
      AND reservation.end_at >= now()
    ORDER BY reservation.start_at
    LIMIT 3
  ) reservation;

  IF coalesce(array_length(future_dates, 1), 0) > 0 THEN
    RAISE EXCEPTION 'Client has future reservations: %. Cancel or delete those reservations before disabling.', array_to_string(future_dates, ', ') USING ERRCODE = '23503';
  END IF;

  UPDATE public.subjects
  SET disabled_at = now(),
      disabled_by = actor_id,
      disabled_reason = nullif(p_reason, ''),
      "updated_at" = now()
  WHERE id = p_subject_id
    AND "Deleted" = 0
  RETURNING id, subject_type, display_name, contact_name, contact_email, contact_phone, notes, created_by, "Deleted", "created_at", "updated_at"
  INTO subject;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Client record not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('disable', 'client', subject.id, subject.display_name, NULL, public.admin_subject_json(subject));

  RETURN public.admin_subject_json(subject);
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
  settings_json jsonb;
  users_json jsonb;
  pending_json jsonb;
  bookings_json jsonb;
  subjects_json jsonb;
  client_types_json jsonb;
  subject_teams_json jsonb;
  subject_memberships_json jsonb;
  seasons_json jsonb;
  season_prices_json jsonb;
  operations_json jsonb;
  invoices_json jsonb;
  payments_json jsonb;
  menu_items_json jsonb;
BEGIN
  SELECT public.admin_facility_settings_json() INTO settings_json;

  SELECT coalesce(jsonb_agg(public.admin_profile_json(profile) ORDER BY profile.approval_status, profile."created_at"), '[]'::jsonb)
  INTO users_json
  FROM public.profiles profile
  WHERE profile."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_profile_json(profile) ORDER BY profile."created_at"), '[]'::jsonb)
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

  SELECT coalesce(jsonb_agg(public.admin_client_type_json(client_type) ORDER BY client_type.sort_order, client_type.name), '[]'::jsonb)
  INTO client_types_json
  FROM public.client_types client_type
  WHERE client_type."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_subject_team_json(team) ORDER BY team.name), '[]'::jsonb)
  INTO subject_teams_json
  FROM public.subject_teams team
  WHERE team."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_subject_membership_json(membership) ORDER BY membership."created_at"), '[]'::jsonb)
  INTO subject_memberships_json
  FROM public.subject_memberships membership
  WHERE membership."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_season_json(season) ORDER BY season.start_year DESC), '[]'::jsonb)
  INTO seasons_json
  FROM public.seasons season
  WHERE season."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_team_season_price_json(price) ORDER BY price.season_year DESC, price.season, price."created_at"), '[]'::jsonb)
  INTO season_prices_json
  FROM public.team_season_prices price
  WHERE price."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_bulk_operation_json(operation) ORDER BY operation."created_at"), '[]'::jsonb)
  INTO operations_json
  FROM public.admin_bulk_operations operation
  WHERE operation."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_invoice_json(invoice) ORDER BY invoice."created_at" DESC), '[]'::jsonb)
  INTO invoices_json
  FROM public.invoices invoice
  WHERE invoice."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_payment_json(payment) ORDER BY payment."created_at" DESC), '[]'::jsonb)
  INTO payments_json
  FROM public.payments payment
  WHERE payment."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_menu_item_json(menu_item) ORDER BY menu_item.page_order, menu_item.name), '[]'::jsonb)
  INTO menu_items_json
  FROM public.admin_menu_items menu_item
  WHERE menu_item.is_active = true
    AND menu_item."Deleted" = 0
    AND menu_item.required_role = 'admin';

  RETURN jsonb_build_object(
    'settings', settings_json,
    'users', users_json,
    'pendingUsers', pending_json,
    'bookings', bookings_json,
    'adminSubjects', subjects_json,
    'clientTypes', client_types_json,
    'subjectTeams', subject_teams_json,
    'subjectMemberships', subject_memberships_json,
    'seasons', seasons_json,
    'teamSeasonPrices', season_prices_json,
    'bulkOperations', operations_json,
    'invoices', invoices_json,
    'payments', payments_json,
    'adminMenuItems', menu_items_json,
    'actorId', actor_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_invoice_json(invoice public.invoices)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', invoice.id,
    'paymentId', invoice.payment_id,
    'paymentKey', invoice.payment_key,
    'invoiceNumber', invoice.invoice_number,
    'subjectId', invoice.subject_id,
    'subjectName', invoice.subject_name,
    'subjectType', invoice.subject_type,
    'contactEmail', coalesce(invoice.contact_email, ''),
    'billingRule', invoice.billing_rule,
    'periodStart', invoice.period_start,
    'periodEnd', invoice.period_end,
    'amount', invoice.amount_due,
    'minutes', invoice.minutes,
    'reservationIds', invoice.reservation_ids,
    'reservations', coalesce((
      SELECT jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at)
      FROM public.reservations reservation
      WHERE reservation.id = ANY(invoice.reservation_ids)
        AND reservation."Deleted" = 0
    ), '[]'::jsonb),
    'status', invoice.status,
    'createdAt', invoice."created_at",
    'sentToAdminAt', invoice.sent_to_admin_at,
    'sentToUserAt', invoice.sent_to_user_at
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_link_subject_profile(
  p_subject_id uuid,
  p_profile_id uuid,
  p_membership_role text DEFAULT 'owner'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  membership public.subject_memberships%ROWTYPE;
  profile public.profiles%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  IF p_membership_role NOT IN ('owner', 'scheduler', 'billing', 'viewer') THEN
    RAISE EXCEPTION 'Membership role is invalid' USING ERRCODE = '22023';
  END IF;

  SELECT *
  INTO profile
  FROM public.profiles
  WHERE id = p_profile_id
    AND "Deleted" = 0;

  IF profile.id IS NULL THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.subject_memberships (
    subject_id,
    profile_id,
    invited_email,
    membership_role,
    status
  ) VALUES (
    p_subject_id,
    p_profile_id,
    profile.email,
    p_membership_role,
    'active'
  )
  ON CONFLICT DO NOTHING;

  SELECT *
  INTO membership
  FROM public.subject_memberships
  WHERE subject_id = p_subject_id
    AND profile_id = p_profile_id
    AND "Deleted" = 0
  ORDER BY "created_at"
  LIMIT 1;

  IF membership.id IS NULL THEN
    RAISE EXCEPTION 'Subject membership could not be created' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_subject_membership_json(membership);
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
  v_payment_key text := coalesce(nullif(payload->>'paymentKey', ''), md5(coalesce(payload->>'subjectId', '') || coalesce(payload->>'billingRule', '') || coalesce(payload->>'periodStart', '') || coalesce(payload->>'periodEnd', '') || reservation_ids::text));
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
    v_payment_key,
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
    "updated_at" = now()
  RETURNING * INTO payment;

  UPDATE public.reservations
  SET payment_status = 'paid',
      updated_at = now()
  WHERE id = ANY(payment.reservation_ids)
    AND "Deleted" = 0;

  IF payment.invoice_id IS NOT NULL THEN
    UPDATE public.invoices
    SET status = 'paid',
        "updated_at" = now()
    WHERE id = payment.invoice_id;
  END IF;

  RETURN public.admin_payment_json(payment);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_payment_json(payment public.payments)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', payment.id,
    'paymentKey', payment.payment_key,
    'subjectId', payment.subject_id,
    'name', payment.subject_name,
    'subjectType', payment.subject_type,
    'contactEmail', coalesce(payment.contact_email, ''),
    'billingRule', payment.billing_rule,
    'periodStart', payment.period_start,
    'periodEnd', payment.period_end,
    'amount', payment.amount_due,
    'minutes', payment.minutes,
    'reservationIds', payment.reservation_ids,
    'reservations', coalesce((
      SELECT jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at)
      FROM public.reservations reservation
      WHERE reservation.id = ANY(payment.reservation_ids)
        AND reservation."Deleted" = 0
    ), '[]'::jsonb),
    'status', payment.status,
    'invoiceId', payment.invoice_id,
    'paidAt', payment.paid_at,
    'createdAt', payment."created_at"
  );
$$;

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
    'created_at', reservation_group."created_at",
    'updated_at', reservation_group."updated_at"
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
    'created_at', reservation."created_at",
    'updated_at', reservation."updated_at"
  )
  FROM public.reservations base
  LEFT JOIN public.subject_teams team ON team.id = reservation.subject_team_id
  WHERE base.id = reservation.id;
$$;

CREATE OR REPLACE FUNCTION public.admin_season_json(season public.seasons)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', season.id,
    'startYear', season.start_year,
    'displayName', season.display_name,
    'deleted', season."Deleted" = 1,
    'created_at', season."created_at",
    'updated_at', season."updated_at"
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_subject_json(subject public.admin_subjects)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', subject.id,
    'subjectType', coalesce(client_type.name, subject.subject_type),
    'clientTypeId', base.client_type_id,
    'clientTypeName', client_type.name,
    'clientTypeHaveTeams', coalesce(client_type.have_teams, false),
    'displayName', subject.display_name,
    'shortName', coalesce(base.short_name, subject.display_name),
    'contactName', coalesce(subject.contact_name, ''),
    'contactEmail', coalesce(subject.contact_email, ''),
    'contactPhone', coalesce(subject.contact_phone, ''),
    'notes', coalesce(subject.notes, ''),
    'disabled', base.disabled_at IS NOT NULL,
    'disabledAt', base.disabled_at,
    'disabledReason', coalesce(base.disabled_reason, ''),
    'teams', coalesce((
      SELECT jsonb_agg(public.admin_subject_team_json(team) ORDER BY team.name)
      FROM public.subject_teams team
      WHERE team.subject_id = subject.id
        AND team."Deleted" = 0
    ), '[]'::jsonb),
    'memberships', coalesce((
      SELECT jsonb_agg(public.admin_subject_membership_json(membership) ORDER BY membership."created_at")
      FROM public.subject_memberships membership
      WHERE membership.subject_id = subject.id
        AND membership."Deleted" = 0
    ), '[]'::jsonb),
    'deleted', subject."Deleted" = 1,
    'created_at', subject."created_at",
    'updated_at', subject."updated_at"
  )
  FROM public.subjects base
  LEFT JOIN public.client_types client_type ON client_type.id = base.client_type_id
  WHERE base.id = subject.id;
$$;

CREATE OR REPLACE FUNCTION public.admin_subject_membership_json(membership public.subject_memberships)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', membership.id,
    'subjectId', membership.subject_id,
    'profileId', membership.profile_id,
    'invitedEmail', coalesce(membership.invited_email, ''),
    'membershipRole', membership.membership_role,
    'status', membership.status,
    'canBook', membership.can_book,
    'canViewInvoices', membership.can_view_invoices,
    'profile', CASE
      WHEN profile.id IS NULL THEN NULL
      ELSE public.admin_profile_json(profile)
    END,
    'deleted', membership."Deleted" = 1,
    'created_at', membership."created_at",
    'updated_at', membership."updated_at"
  )
  FROM (SELECT membership.*) current_membership
  LEFT JOIN public.profiles profile ON profile.id = current_membership.profile_id;
$$;

CREATE OR REPLACE FUNCTION public.admin_subject_team_json(team public.subject_teams)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', team.id,
    'subjectId', team.subject_id,
    'name', team.name,
    'shortName', team.short_name,
    'coachName', coalesce(team.coach_name, ''),
    'coachEmail', coalesce(team.coach_email, ''),
    'coachPhone', coalesce(team.coach_phone, ''),
    'coachSafeSport', coalesce(team.coach_safe_sport, false),
    'coachBackgroundCheck', coalesce(team.coach_background_check, false),
    'coachConcussion', coalesce(team.coach_concussion, false),
    'clubInsuranceReceived', coalesce(team.club_insurance_received, false),
    'deleted', team."Deleted" = 1,
    'created_at', team."created_at",
    'updated_at', team."updated_at"
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_subjects_insert_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  inserted public.subjects%ROWTYPE;
BEGIN
  INSERT INTO public.subjects (
    id,
    subject_type,
    display_name,
    contact_name,
    contact_email,
    contact_phone,
    notes,
    created_by,
    "Deleted",
    "created_at",
    "updated_at"
  ) VALUES (
    coalesce(NEW.id, gen_random_uuid()),
    coalesce(NEW.subject_type, 'team'),
    NEW.display_name,
    NEW.contact_name,
    NEW.contact_email,
    NEW.contact_phone,
    NEW.notes,
    NEW.created_by,
    coalesce(NEW."Deleted", 0),
    coalesce(NEW."created_at", now()),
    coalesce(NEW."updated_at", now())
  )
  RETURNING * INTO inserted;

  NEW.id := inserted.id;
  NEW.subject_type := inserted.subject_type;
  NEW.display_name := inserted.display_name;
  NEW.contact_name := inserted.contact_name;
  NEW.contact_email := inserted.contact_email;
  NEW.contact_phone := inserted.contact_phone;
  NEW.notes := inserted.notes;
  NEW.created_by := inserted.created_by;
  NEW."Deleted" := inserted."Deleted";
  NEW."created_at" := inserted."created_at";
  NEW."updated_at" := inserted."updated_at";

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_subjects_update_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  updated public.subjects%ROWTYPE;
BEGIN
  UPDATE public.subjects
  SET subject_type = NEW.subject_type,
      display_name = NEW.display_name,
      contact_name = NEW.contact_name,
      contact_email = NEW.contact_email,
      contact_phone = NEW.contact_phone,
      notes = NEW.notes,
      created_by = NEW.created_by,
      "Deleted" = NEW."Deleted",
      "created_at" = NEW."created_at",
      "updated_at" = coalesce(NEW."updated_at", now())
  WHERE id = OLD.id
  RETURNING * INTO updated;

  IF updated.id IS NULL THEN
    RETURN NULL;
  END IF;

  NEW.id := updated.id;
  NEW.subject_type := updated.subject_type;
  NEW.display_name := updated.display_name;
  NEW.contact_name := updated.contact_name;
  NEW.contact_email := updated.contact_email;
  NEW.contact_phone := updated.contact_phone;
  NEW.notes := updated.notes;
  NEW.created_by := updated.created_by;
  NEW."Deleted" := updated."Deleted";
  NEW."created_at" := updated."created_at";
  NEW."updated_at" := updated."updated_at";

  RETURN NEW;
END;
$$;

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
    'seasonId', season.id,
    'season', coalesce(season.display_name, price.season),
    'seasonDisplayName', coalesce(season.display_name, price.season),
    'seasonYear', coalesce(season.start_year, price.season_year),
    'hourlyRate', price.hourly_rate,
    'documentsReceived', price.documents_received,
    'deposit', price.deposit,
    'deleted', price."Deleted" = 1,
    'created_at', price."created_at",
    'updated_at', price."updated_at"
  )
  FROM public.admin_subjects subject
  LEFT JOIN public.seasons season
    ON season.id = price.season_id
  WHERE subject.id = price.subject_id;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_client_type(p_client_type_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  before_row public.client_types%ROWTYPE;
  client_type public.client_types%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT * INTO before_row FROM public.client_types WHERE id = p_client_type_id AND "Deleted" = 0;

  UPDATE public.client_types
  SET name = coalesce(nullif(trim(payload->>'name'), ''), name),
      have_teams = coalesce((payload->>'haveTeams')::boolean, have_teams),
      sort_order = coalesce((payload->>'sortOrder')::integer, sort_order),
      "updated_at" = now()
  WHERE id = p_client_type_id
    AND "Deleted" = 0
  RETURNING * INTO client_type;

  IF client_type.id IS NULL THEN
    RAISE EXCEPTION 'Client type not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('update', 'client_type', client_type.id, client_type.name, to_jsonb(before_row), to_jsonb(client_type));

  RETURN public.admin_client_type_json(client_type);
END;
$$;

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
      updated_at = now(),
      "updated_at" = now()
  WHERE id = true;

  RETURN public.admin_get_dashboard();
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_season(p_season_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  season public.seasons%ROWTYPE;
  next_start_year integer;
  next_display_name text;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT *
  INTO season
  FROM public.seasons
  WHERE id = p_season_id
    AND "Deleted" = 0;

  IF season.id IS NULL THEN
    RAISE EXCEPTION 'Season not found' USING ERRCODE = '22023';
  END IF;

  next_start_year := coalesce(nullif(payload->>'startYear', '')::integer, season.start_year);
  next_display_name := coalesce(nullif(trim(payload->>'displayName'), ''), public.season_display_name(next_start_year));

  IF next_start_year NOT BETWEEN 2000 AND 2100 THEN
    RAISE EXCEPTION 'Season year must be between 2000 and 2100' USING ERRCODE = '22023';
  END IF;

  UPDATE public.seasons
  SET start_year = next_start_year,
      display_name = next_display_name,
      "updated_at" = now()
  WHERE id = p_season_id
    AND "Deleted" = 0
  RETURNING * INTO season;

  UPDATE public.team_season_prices
  SET season = season.display_name,
      season_year = season.start_year,
      "updated_at" = now()
  WHERE season_id = season.id
    AND "Deleted" = 0;

  RETURN public.admin_season_json(season);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_subject(p_subject_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  before_json jsonb;
  subject public.admin_subjects%ROWTYPE;
  client_type public.client_types%ROWTYPE;
  next_email text := nullif(trim(payload->>'contactEmail'), '');
BEGIN
  PERFORM public.admin_require_approved();

  SELECT public.admin_subject_json(existing)
  INTO before_json
  FROM public.admin_subjects existing
  WHERE existing.id = p_subject_id
    AND existing."Deleted" = 0;

  SELECT * INTO client_type
  FROM public.client_types
  WHERE id = nullif(payload->>'clientTypeId', '')::uuid
    AND "Deleted" = 0;

  IF client_type.id IS NULL THEN
    RAISE EXCEPTION 'Client type is required' USING ERRCODE = '22023';
  END IF;

  UPDATE public.admin_subjects
  SET subject_type = lower(client_type.name),
      display_name = coalesce(nullif(payload->>'displayName', ''), display_name),
      contact_name = nullif(payload->>'contactName', ''),
      contact_email = next_email,
      contact_phone = nullif(payload->>'contactPhone', ''),
      notes = coalesce(payload->>'notes', notes),
      "updated_at" = now()
  WHERE id = p_subject_id
    AND "Deleted" = 0
  RETURNING * INTO subject;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Client record not found' USING ERRCODE = '22023';
  END IF;

  UPDATE public.subjects
  SET short_name = coalesce(nullif(payload->>'shortName', ''), left(subject.display_name, 24)),
      client_type_id = client_type.id,
      "updated_at" = now()
  WHERE id = subject.id;

  SELECT * INTO subject FROM public.admin_subjects WHERE id = subject.id;

  IF next_email IS NOT NULL THEN
    INSERT INTO public.subject_memberships (subject_id, invited_email, membership_role, status)
    VALUES (subject.id, next_email, 'owner', 'invited')
    ON CONFLICT DO NOTHING;

    PERFORM public.link_profile_to_subjects_by_email(profile.id, profile.email)
    FROM public.profiles profile
    WHERE lower(profile.email) = lower(next_email)
      AND profile."Deleted" = 0;
  END IF;

  PERFORM public.audit_log('update', 'client', subject.id, subject.display_name, before_json, public.admin_subject_json(subject));

  RETURN public.admin_subject_json(subject);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_subject_team(p_team_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  before_row public.subject_teams%ROWTYPE;
  team public.subject_teams%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT * INTO before_row FROM public.subject_teams WHERE id = p_team_id AND "Deleted" = 0;

  UPDATE public.subject_teams
  SET name = coalesce(nullif(trim(payload->>'name'), ''), name),
      short_name = coalesce(nullif(trim(payload->>'shortName'), ''), short_name),
      coach_name = nullif(trim(payload->>'coachName'), ''),
      coach_email = nullif(trim(payload->>'coachEmail'), ''),
      coach_phone = nullif(trim(payload->>'coachPhone'), ''),
      coach_safe_sport = coalesce((payload->>'coachSafeSport')::boolean, coach_safe_sport),
      coach_background_check = coalesce((payload->>'coachBackgroundCheck')::boolean, coach_background_check),
      coach_concussion = coalesce((payload->>'coachConcussion')::boolean, coach_concussion),
      club_insurance_received = coalesce((payload->>'clubInsuranceReceived')::boolean, club_insurance_received),
      "updated_at" = now()
  WHERE id = p_team_id
    AND "Deleted" = 0
  RETURNING * INTO team;

  IF team.id IS NULL THEN
    RAISE EXCEPTION 'Team not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('update', 'client_team', team.id, team.name, to_jsonb(before_row), to_jsonb(team));

  RETURN public.admin_subject_team_json(team);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_team_season_price(p_price_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  subject public.admin_subjects%ROWTYPE;
  price public.team_season_prices%ROWTYPE;
  before_json jsonb;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT public.admin_team_season_price_json(existing)
  INTO before_json
  FROM public.team_season_prices existing
  WHERE existing.id = p_price_id
    AND existing."Deleted" = 0;

  SELECT *
  INTO subject
  FROM public.admin_subjects
  WHERE id = (payload->>'subjectId')::uuid
    AND "Deleted" = 0;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Client record not found' USING ERRCODE = '22023';
  END IF;

  UPDATE public.team_season_prices price
  SET subject_id = subject.id,
      season_id = season.id,
      season = season.display_name,
      season_year = season.start_year,
      hourly_rate = (payload->>'hourlyRate')::numeric,
      documents_received = coalesce((payload->>'documentsReceived')::boolean, documents_received),
      deposit = coalesce(nullif(payload->>'deposit', '')::numeric, deposit),
      "updated_at" = now()
  FROM public.seasons season
  WHERE price.id = p_price_id
    AND season.id = (payload->>'seasonId')::uuid
    AND price."Deleted" = 0
    AND season."Deleted" = 0
  RETURNING price.* INTO price;

  IF price.id IS NULL THEN
    RAISE EXCEPTION 'Club season not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('update', 'club_season', price.id, subject.display_name, before_json, public.admin_team_season_price_json(price));

  RETURN public.admin_team_season_price_json(price);
END;
$$;

CREATE OR REPLACE FUNCTION public.link_profile_to_subjects_by_email(p_profile_id uuid, p_email text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  normalized_email text := lower(nullif(trim(p_email), ''));
BEGIN
  IF p_profile_id IS NULL OR normalized_email IS NULL THEN
    RETURN;
  END IF;

  UPDATE public.subject_memberships
  SET profile_id = p_profile_id,
      status = 'active',
      "updated_at" = now()
  WHERE profile_id IS NULL
    AND lower(invited_email) = normalized_email
    AND "Deleted" = 0;

  INSERT INTO public.subject_memberships (
    subject_id,
    profile_id,
    invited_email,
    membership_role,
    status
  )
  SELECT
    subject.id,
    p_profile_id,
    subject.contact_email,
    'owner',
    'active'
  FROM public.subjects subject
  WHERE lower(subject.contact_email) = normalized_email
    AND subject."Deleted" = 0
    AND NOT EXISTS (
      SELECT 1
      FROM public.subject_memberships membership
      WHERE membership.subject_id = subject.id
        AND membership.profile_id = p_profile_id
        AND membership."Deleted" = 0
    )
    AND NOT EXISTS (
      SELECT 1
      FROM public.subject_memberships membership
      WHERE membership.subject_id = subject.id
        AND membership.profile_id IS NULL
        AND lower(membership.invited_email) = normalized_email
        AND membership."Deleted" = 0
    );
END;
$$;

CREATE TRIGGER admin_subjects_insert
  INSTEAD OF INSERT ON public.admin_subjects
  FOR EACH ROW EXECUTE FUNCTION public.admin_subjects_insert_trigger();

CREATE TRIGGER admin_subjects_update
  INSTEAD OF UPDATE ON public.admin_subjects
  FOR EACH ROW EXECUTE FUNCTION public.admin_subjects_update_trigger();

CREATE TRIGGER admin_subjects_delete
  INSTEAD OF DELETE ON public.admin_subjects
  FOR EACH ROW EXECUTE FUNCTION public.admin_subjects_delete_trigger();

GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_subjects TO authenticated;

DO $$
DECLARE
  audit_table text;
  audit_tables text[] := ARRAY[
    'admin_bulk_operation_items',
    'admin_bulk_operations',
    'admin_menu_items',
    'audit_events',
    'auth_provider_options',
    'client_types',
    'closures',
    'facility_config',
    'fixed_reservations',
    'invoices',
    'operating_hours',
    'payments',
    'profiles',
    'reservation_groups',
    'reservations',
    'resources',
    'seasons',
    'subject_memberships',
    'subject_teams',
    'subjects',
    'team_season_prices'
  ];
BEGIN
  FOREACH audit_table IN ARRAY audit_tables
  LOOP
    EXECUTE format('ALTER TABLE public.%I DROP COLUMN IF EXISTS "createdDT"', audit_table);
    EXECUTE format('ALTER TABLE public.%I DROP COLUMN IF EXISTS "updatedDT"', audit_table);
  END LOOP;
END $$;

REVOKE EXECUTE ON FUNCTION public.set_audit_fields() FROM PUBLIC;
