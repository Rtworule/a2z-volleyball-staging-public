CREATE TABLE IF NOT EXISTS public.payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_key text NOT NULL UNIQUE,
  subject_id uuid REFERENCES public.admin_subjects(id),
  subject_name text NOT NULL,
  subject_type text NOT NULL CHECK (subject_type IN ('team', 'coach', 'user')),
  contact_email text,
  billing_rule text NOT NULL,
  period_start date,
  period_end date,
  amount_due numeric(10, 2) NOT NULL DEFAULT 0,
  minutes integer NOT NULL DEFAULT 0,
  reservation_ids uuid[] NOT NULL DEFAULT ARRAY[]::uuid[],
  status text NOT NULL DEFAULT 'due' CHECK (status IN ('due', 'invoiced', 'paid', 'void')),
  invoice_id uuid REFERENCES public.invoices(id),
  paid_at timestamptz,
  created_by uuid REFERENCES public.profiles(id),
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS payments_subject_idx ON public.payments(subject_id, period_start, period_end) WHERE "Deleted" = 0;
CREATE INDEX IF NOT EXISTS payments_status_idx ON public.payments(status) WHERE "Deleted" = 0;

ALTER TABLE public.invoices
  ADD COLUMN IF NOT EXISTS payment_id uuid REFERENCES public.payments(id),
  ADD COLUMN IF NOT EXISTS payment_key text;

DROP TRIGGER IF EXISTS payments_set_updated_dt ON public.payments;
CREATE TRIGGER payments_set_updated_dt BEFORE UPDATE ON public.payments
FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read active payments" ON public.payments;
DROP POLICY IF EXISTS "Admins insert payments" ON public.payments;
DROP POLICY IF EXISTS "Admins update payments" ON public.payments;

CREATE POLICY "Admins read active payments"
  ON public.payments FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert payments"
  ON public.payments FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update payments"
  ON public.payments FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

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
    'createdAt', payment."createdDT"
  );
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
    'createdAt', invoice."createdDT",
    'sentToAdminAt', invoice.sent_to_admin_at,
    'sentToUserAt', invoice.sent_to_user_at
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
    'invoiced',
    actor_id
  )
  ON CONFLICT (payment_key) DO UPDATE SET
    amount_due = excluded.amount_due,
    minutes = excluded.minutes,
    reservation_ids = excluded.reservation_ids,
    status = CASE WHEN public.payments.status = 'paid' THEN public.payments.status ELSE 'invoiced' END,
    "updatedDT" = now()
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

  UPDATE public.payments
  SET invoice_id = saved.id,
      status = CASE WHEN status = 'paid' THEN status ELSE 'invoiced' END,
      "updatedDT" = now()
  WHERE id = payment.id
  RETURNING * INTO payment;

  SELECT coalesce(jsonb_agg(public.admin_invoice_json(invoice) ORDER BY invoice."createdDT" DESC), '[]'::jsonb)
  INTO invoices_json
  FROM public.invoices invoice
  WHERE invoice."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_payment_json(payment_record) ORDER BY payment_record."createdDT" DESC), '[]'::jsonb)
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
  SET paid = 1,
      payment_status = 'paid',
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
      "updatedDT" = now()
  WHERE id = p_operation_id
  RETURNING * INTO target;

  RETURN public.admin_bulk_operation_json(target);
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
    AND paid = 0
    AND start_at >= now()
  RETURNING * INTO reservation;

  IF reservation.id IS NULL THEN
    RAISE EXCEPTION 'Future unpaid reservation not found' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_reservation_json(reservation);
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
  seasons_json jsonb;
  season_prices_json jsonb;
  operations_json jsonb;
  invoices_json jsonb;
  payments_json jsonb;
BEGIN
  SELECT public.admin_facility_settings_json()
  INTO settings_json;

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

  SELECT coalesce(jsonb_agg(public.admin_season_json(season) ORDER BY season.start_year DESC), '[]'::jsonb)
  INTO seasons_json
  FROM public.seasons season
  WHERE season."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_team_season_price_json(price) ORDER BY price.season_year DESC, price.season, price."createdDT"), '[]'::jsonb)
  INTO season_prices_json
  FROM public.team_season_prices price
  WHERE price."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_bulk_operation_json(operation) ORDER BY operation."createdDT"), '[]'::jsonb)
  INTO operations_json
  FROM public.admin_bulk_operations operation
  WHERE operation."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_invoice_json(invoice) ORDER BY invoice."createdDT" DESC), '[]'::jsonb)
  INTO invoices_json
  FROM public.invoices invoice
  WHERE invoice."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_payment_json(payment) ORDER BY payment."createdDT" DESC), '[]'::jsonb)
  INTO payments_json
  FROM public.payments payment
  WHERE payment."Deleted" = 0;

  RETURN jsonb_build_object(
    'settings', settings_json,
    'users', users_json,
    'pendingUsers', pending_json,
    'bookings', bookings_json,
    'adminSubjects', subjects_json,
    'seasons', seasons_json,
    'teamSeasonPrices', season_prices_json,
    'bulkOperations', operations_json,
    'invoices', invoices_json,
    'payments', payments_json,
    'actorId', actor_id
  );
END;
$$;

COMMENT ON FUNCTION public.system_monthly_payment_due_job(date) IS 'Schedule at 00:05 America/New_York on the first day of each month. Supabase cron should use the America/New_York timezone.';
COMMENT ON FUNCTION public.system_reservation_reminder_job(date) IS 'Schedule at 20:00 America/New_York daily. Supabase cron should use the America/New_York timezone.';

REVOKE EXECUTE ON FUNCTION public.admin_payment_json(public.payments) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_mark_payment_paid(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_reservation(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_payment_json(public.payments) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mark_payment_paid(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_reservation(uuid) TO authenticated;
