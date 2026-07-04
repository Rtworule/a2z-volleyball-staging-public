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

  UPDATE public.payments AS target
  SET invoice_id = saved.id,
      status = CASE WHEN target.status = 'paid' THEN target.status ELSE 'invoiced' END,
      "updatedDT" = now()
  WHERE target.id = payment.id
  RETURNING target.* INTO payment;

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
