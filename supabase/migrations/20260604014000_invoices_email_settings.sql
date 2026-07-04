ALTER TABLE public.facility_config
  ADD COLUMN IF NOT EXISTS admin_email text,
  ADD COLUMN IF NOT EXISTS email_templates jsonb NOT NULL DEFAULT jsonb_build_object(
    'reservationReminder', jsonb_build_object(
      'subject', 'Reservation reminder for <teamname>',
      'body', 'Hi <teamname>,' || chr(10) || chr(10) || 'This is a reminder for your reservation on <reservationdate> from <starttime> to <endtime> on <courts>.'
    ),
    'invoice', jsonb_build_object(
      'subject', 'Invoice <invoicenumber> for <teamname>',
      'body', 'Hi <teamname>,' || chr(10) || chr(10) || 'Your invoice <invoicenumber> for <amountdue> is ready.'
    )
  );

CREATE TABLE IF NOT EXISTS public.invoices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_number text NOT NULL UNIQUE,
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
  status text NOT NULL DEFAULT 'created' CHECK (status IN ('created', 'sent', 'paid', 'void')),
  created_by uuid REFERENCES public.profiles(id),
  sent_to_admin_at timestamptz,
  sent_to_user_at timestamptz,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS invoices_subject_idx ON public.invoices(subject_id, "createdDT") WHERE "Deleted" = 0;
CREATE INDEX IF NOT EXISTS invoices_status_idx ON public.invoices(status) WHERE "Deleted" = 0;

DROP TRIGGER IF EXISTS invoices_set_updated_dt ON public.invoices;
CREATE TRIGGER invoices_set_updated_dt BEFORE UPDATE ON public.invoices
FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();

ALTER TABLE public.invoices ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Admins read active invoices" ON public.invoices;
DROP POLICY IF EXISTS "Admins insert invoices" ON public.invoices;
DROP POLICY IF EXISTS "Admins update invoices" ON public.invoices;

CREATE POLICY "Admins read active invoices"
  ON public.invoices FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert invoices"
  ON public.invoices FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update invoices"
  ON public.invoices FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE OR REPLACE FUNCTION public.admin_invoice_json(invoice public.invoices)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', invoice.id,
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
  invoices_json jsonb;
BEGIN
  INSERT INTO public.invoices (
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
    coalesce(nullif(payload->>'invoiceNumber', ''), 'A2Z-' || to_char(now(), 'YYYYMMDDHH24MISS')),
    nullif(payload->>'subjectId', '')::uuid,
    payload->>'subjectName',
    coalesce(payload->>'subjectType', 'user'),
    nullif(payload->>'contactEmail', ''),
    coalesce(payload->>'billingRule', 'manual'),
    nullif(payload->>'periodStart', '')::date,
    nullif(payload->>'periodEnd', '')::date,
    coalesce((payload->>'amount')::numeric, 0),
    coalesce((payload->>'minutes')::integer, 0),
    coalesce(ARRAY(SELECT value::uuid FROM jsonb_array_elements_text(coalesce(payload->'reservationIds', '[]'::jsonb)) AS value), ARRAY[]::uuid[]),
    actor_id
  ) RETURNING * INTO saved;

  SELECT coalesce(jsonb_agg(public.admin_invoice_json(invoice) ORDER BY invoice."createdDT" DESC), '[]'::jsonb)
  INTO invoices_json
  FROM public.invoices invoice
  WHERE invoice."Deleted" = 0;

  RETURN jsonb_build_object('invoice', public.admin_invoice_json(saved), 'invoices', invoices_json);
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
      status = 'deleted',
      "updatedDT" = now()
  WHERE id = p_operation_id
  RETURNING * INTO target;

  RETURN public.admin_bulk_operation_json(target);
END;
$$;

CREATE OR REPLACE FUNCTION public.system_monthly_payment_due_job(p_run_date date DEFAULT current_date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.admin_calculate_monthly_payment_due(p_run_date);
END;
$$;

CREATE OR REPLACE FUNCTION public.system_reservation_reminder_job(p_run_date date DEFAULT current_date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN jsonb_build_object(
    'runDate', p_run_date,
    'reminderDate', p_run_date + 1,
    'reservations', coalesce((
      SELECT jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at)
      FROM public.reservations reservation
      WHERE reservation."Deleted" = 0
        AND reservation.status <> 'cancelled'
        AND reservation.start_at >= ((p_run_date + 1)::text || ' 00:00')::timestamp
        AND reservation.start_at < ((p_run_date + 2)::text || ' 00:00')::timestamp
    ), '[]'::jsonb)
  );
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
      admin_email = coalesce(nullif(payload->>'adminEmail', ''), admin_email),
      email_templates = coalesce(payload->'emailTemplates', email_templates),
      updated_at = now()
  WHERE id = true;

  RETURN public.admin_get_dashboard();
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
  seasons_json jsonb;
  season_prices_json jsonb;
  operations_json jsonb;
  invoices_json jsonb;
BEGIN
  SELECT * INTO config_row FROM public.facility_config WHERE id = true;

  SELECT jsonb_build_object(
    'courtCount', config_row.court_count,
    'trainerCapacity', config_row.trainer_capacity,
    'slotIntervalMinutes', config_row.reservation_step_minutes,
    'minBookingMinutes', config_row.min_reservation_minutes,
    'adminEmail', coalesce(config_row.admin_email, ''),
    'emailTemplates', config_row.email_templates,
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
    'actorId', actor_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_invoice_json(public.invoices) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_create_invoice(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_bulk_operation(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.system_monthly_payment_due_job(date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.system_reservation_reminder_job(date) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_invoice_json(public.invoices) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_invoice(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_bulk_operation(uuid) TO authenticated;
