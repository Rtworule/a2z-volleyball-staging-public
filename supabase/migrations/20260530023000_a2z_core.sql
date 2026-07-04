CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE public.profiles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  username text NOT NULL UNIQUE,
  email text NOT NULL UNIQUE,
  display_name text NOT NULL,
  team_name text,
  account_role text NOT NULL DEFAULT 'user' CHECK (account_role IN ('user', 'admin')),
  approval_status text NOT NULL DEFAULT 'pending' CHECK (approval_status IN ('pending', 'approved', 'rejected')),
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.auth_provider_options (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider text NOT NULL UNIQUE,
  enabled boolean NOT NULL DEFAULT false,
  display_name text NOT NULL,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.facility_config (
  id boolean PRIMARY KEY DEFAULT true CHECK (id),
  court_count integer NOT NULL DEFAULT 9 CHECK (court_count > 0),
  trainer_capacity integer NOT NULL DEFAULT 2 CHECK (trainer_capacity > 0),
  court_hourly_rate numeric(8, 2) NOT NULL DEFAULT 75 CHECK (court_hourly_rate >= 0),
  gym_hourly_rate numeric(8, 2) NOT NULL DEFAULT 110 CHECK (gym_hourly_rate >= 0),
  min_reservation_minutes integer NOT NULL DEFAULT 60 CHECK (min_reservation_minutes >= 60),
  reservation_step_minutes integer NOT NULL DEFAULT 30 CHECK (reservation_step_minutes = 30),
  timezone text NOT NULL DEFAULT 'America/New_York',
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.operating_hours (
  day_of_week integer PRIMARY KEY CHECK (day_of_week BETWEEN 0 AND 6),
  open_time time NOT NULL,
  close_time time NOT NULL,
  is_closed boolean NOT NULL DEFAULT false,
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  CHECK (is_closed OR open_time < close_time),
  CHECK (extract(minute from open_time)::int IN (0, 30)),
  CHECK (extract(minute from close_time)::int IN (0, 30))
);

CREATE TABLE public.resources (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_type text NOT NULL CHECK (resource_type IN ('court', 'trainer')),
  court_number integer,
  name text NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (resource_type = 'court' AND court_number IS NOT NULL)
    OR (resource_type = 'trainer' AND court_number IS NULL)
  ),
  UNIQUE (resource_type, court_number)
);

CREATE TABLE public.reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid REFERENCES public.profiles(id),
  team_name text,
  subject_id uuid,
  resource_type text NOT NULL CHECK (resource_type IN ('court', 'trainer')),
  court_number integer,
  start_at timestamptz NOT NULL,
  end_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'confirmed' CHECK (status IN ('pending', 'confirmed', 'cancelled')),
  payment_status text NOT NULL DEFAULT 'due' CHECK (payment_status IN ('due', 'paid', 'waived', 'refunded')),
  paid integer NOT NULL DEFAULT 0 CHECK (paid IN (0, 1)),
  created_by uuid REFERENCES public.profiles(id),
  bulk_operation_id uuid,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_at > start_at),
  CHECK (end_at - start_at >= interval '1 hour'),
  CHECK ((extract(epoch from (end_at - start_at))::integer / 60) % 30 = 0),
  CHECK (extract(minute from start_at)::int IN (0, 30)),
  CHECK (extract(minute from end_at)::int IN (0, 30)),
  CHECK (
    (resource_type = 'court' AND court_number BETWEEN 1 AND 9)
    OR (resource_type = 'trainer' AND court_number IS NULL)
  )
);

CREATE TABLE public.closures (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  resource_type text NOT NULL DEFAULT 'all' CHECK (resource_type IN ('all', 'court', 'trainer')),
  court_number integer,
  start_at timestamptz NOT NULL,
  end_at timestamptz NOT NULL,
  reason text NOT NULL DEFAULT 'Closed',
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (end_at > start_at),
  CHECK (court_number IS NULL OR court_number BETWEEN 1 AND 9)
);

CREATE TABLE public.fixed_reservations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL,
  resource_type text NOT NULL CHECK (resource_type IN ('court', 'trainer')),
  court_number integer,
  days_of_week integer[] NOT NULL,
  start_date date NOT NULL,
  end_date date NOT NULL,
  start_time time NOT NULL,
  end_time time NOT NULL,
  capacity integer NOT NULL DEFAULT 1 CHECK (capacity > 0),
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (start_date <= end_date),
  CHECK (start_time < end_time),
  CHECK (extract(minute from start_time)::int IN (0, 30)),
  CHECK (extract(minute from end_time)::int IN (0, 30)),
  CHECK (
    (resource_type = 'court' AND court_number BETWEEN 1 AND 9)
    OR (resource_type = 'trainer' AND court_number IS NULL)
  )
);

CREATE TABLE public.admin_subjects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_type text NOT NULL CHECK (subject_type IN ('team', 'coach')),
  display_name text NOT NULL,
  contact_name text,
  contact_email text,
  contact_phone text,
  notes text,
  created_by uuid REFERENCES public.profiles(id),
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.admin_bulk_operations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  operation_type text NOT NULL CHECK (operation_type IN ('reservation_create', 'reservation_delete', 'reservation_update')),
  label text NOT NULL,
  subject_id uuid REFERENCES public.admin_subjects(id),
  start_date date NOT NULL,
  end_date date NOT NULL,
  status text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'previewed', 'scheduled', 'applied', 'undone', 'cancelled')),
  apply_after timestamptz,
  paid integer NOT NULL DEFAULT 0 CHECK (paid IN (0, 1)),
  conflict_resolution text NOT NULL DEFAULT 'skip_conflicts' CHECK (conflict_resolution IN ('skip_conflicts', 'first_available_court', 'fail_all')),
  requested_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  preview_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by uuid REFERENCES public.profiles(id),
  applied_by uuid REFERENCES public.profiles(id),
  undone_by uuid REFERENCES public.profiles(id),
  "appliedDT" timestamptz,
  "undoneDT" timestamptz,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  CHECK (start_date <= end_date)
);

CREATE TABLE public.admin_bulk_operation_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bulk_operation_id uuid NOT NULL REFERENCES public.admin_bulk_operations(id) ON DELETE CASCADE,
  reservation_id uuid REFERENCES public.reservations(id),
  action text NOT NULL CHECK (action IN ('create', 'delete', 'update')),
  subject_id uuid REFERENCES public.admin_subjects(id),
  resource_type text NOT NULL CHECK (resource_type IN ('court', 'trainer')),
  court_number integer,
  start_at timestamptz NOT NULL,
  end_at timestamptz NOT NULL,
  paid integer NOT NULL DEFAULT 0 CHECK (paid IN (0, 1)),
  status text NOT NULL DEFAULT 'preview' CHECK (status IN ('preview', 'conflict', 'scheduled', 'applied', 'skipped', 'undone')),
  conflict_reason text,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  CHECK (end_at > start_at),
  CHECK ((resource_type = 'court' AND court_number BETWEEN 1 AND 9) OR (resource_type = 'trainer' AND court_number IS NULL))
);

CREATE INDEX reservations_user_id_idx ON public.reservations(user_id);
CREATE INDEX reservations_subject_id_idx ON public.reservations(subject_id) WHERE "Deleted" = 0;
CREATE INDEX reservations_window_idx ON public.reservations(start_at, end_at);
CREATE INDEX reservations_resource_idx ON public.reservations(resource_type, court_number);
CREATE UNIQUE INDEX resources_trainer_unique_idx ON public.resources(resource_type) WHERE resource_type = 'trainer';
CREATE INDEX admin_subjects_type_idx ON public.admin_subjects(subject_type) WHERE "Deleted" = 0;
CREATE INDEX admin_bulk_operations_status_idx ON public.admin_bulk_operations(status) WHERE "Deleted" = 0;
CREATE INDEX admin_bulk_operation_items_operation_idx ON public.admin_bulk_operation_items(bulk_operation_id) WHERE "Deleted" = 0;

ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_bulk_operation_id_fkey
  FOREIGN KEY (bulk_operation_id) REFERENCES public.admin_bulk_operations(id);

ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_subject_id_fkey
  FOREIGN KEY (subject_id) REFERENCES public.admin_subjects(id);

CREATE OR REPLACE FUNCTION public.set_updated_dt()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW."updatedDT" = now();
  RETURN NEW;
END;
$$;

CREATE TRIGGER profiles_set_updated_dt BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();
CREATE TRIGGER auth_provider_options_set_updated_dt BEFORE UPDATE ON public.auth_provider_options
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();
CREATE TRIGGER facility_config_set_updated_dt BEFORE UPDATE ON public.facility_config
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();
CREATE TRIGGER operating_hours_set_updated_dt BEFORE UPDATE ON public.operating_hours
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();
CREATE TRIGGER resources_set_updated_dt BEFORE UPDATE ON public.resources
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();
CREATE TRIGGER reservations_set_updated_dt BEFORE UPDATE ON public.reservations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();
CREATE TRIGGER closures_set_updated_dt BEFORE UPDATE ON public.closures
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();
CREATE TRIGGER fixed_reservations_set_updated_dt BEFORE UPDATE ON public.fixed_reservations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();
CREATE TRIGGER admin_subjects_set_updated_dt BEFORE UPDATE ON public.admin_subjects
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();
CREATE TRIGGER admin_bulk_operations_set_updated_dt BEFORE UPDATE ON public.admin_bulk_operations
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();
CREATE TRIGGER admin_bulk_operation_items_set_updated_dt BEFORE UPDATE ON public.admin_bulk_operation_items
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();

CREATE OR REPLACE FUNCTION public.current_profile_is_admin()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = auth.uid()
      AND account_role = 'admin'
      AND approval_status = 'approved'
      AND "Deleted" = 0
  );
$$;

CREATE OR REPLACE FUNCTION public.current_profile_is_approved_member()
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles
    WHERE id = auth.uid()
      AND account_role = 'user'
      AND approval_status = 'approved'
      AND "Deleted" = 0
  );
$$;

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.auth_provider_options ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.facility_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.operating_hours ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.resources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.closures ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.fixed_reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_subjects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_bulk_operations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_bulk_operation_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Public can read non-sensitive facility config"
  ON public.facility_config FOR SELECT
  USING (true);

CREATE POLICY "Public can read operating hours"
  ON public.operating_hours FOR SELECT
  USING (true);

CREATE POLICY "Public can read active resources"
  ON public.resources FOR SELECT
  USING (is_active AND "Deleted" = 0);

CREATE POLICY "Public can read enabled auth providers"
  ON public.auth_provider_options FOR SELECT
  USING (enabled AND "Deleted" = 0);

CREATE POLICY "Users can read own profile"
  ON public.profiles FOR SELECT
  USING (auth.uid() = id AND "Deleted" = 0);

CREATE POLICY "Users can read own reservations"
  ON public.reservations FOR SELECT
  USING (auth.uid() = user_id AND "Deleted" = 0);

CREATE POLICY "Approved users can create own reservations"
  ON public.reservations FOR INSERT
  WITH CHECK (
    auth.uid() = user_id
    AND "Deleted" = 0
    AND public.current_profile_is_approved_member()
  );

CREATE POLICY "Admins read active profiles"
  ON public.profiles FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert profiles"
  ON public.profiles FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update profiles"
  ON public.profiles FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins manage facility config"
  ON public.facility_config FOR ALL
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins manage operating hours"
  ON public.operating_hours FOR ALL
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins read active resources"
  ON public.resources FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert resources"
  ON public.resources FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update resources"
  ON public.resources FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins read active reservations"
  ON public.reservations FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert reservations"
  ON public.reservations FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update reservations"
  ON public.reservations FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins read active closures"
  ON public.closures FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert closures"
  ON public.closures FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update closures"
  ON public.closures FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins read active fixed reservations"
  ON public.fixed_reservations FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert fixed reservations"
  ON public.fixed_reservations FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update fixed reservations"
  ON public.fixed_reservations FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins read active auth provider options"
  ON public.auth_provider_options FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert auth provider options"
  ON public.auth_provider_options FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update auth provider options"
  ON public.auth_provider_options FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins read active temporary subjects"
  ON public.admin_subjects FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert temporary subjects"
  ON public.admin_subjects FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update temporary subjects"
  ON public.admin_subjects FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins read active bulk operations"
  ON public.admin_bulk_operations FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert bulk operations"
  ON public.admin_bulk_operations FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update bulk operations"
  ON public.admin_bulk_operations FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins read active bulk operation items"
  ON public.admin_bulk_operation_items FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert bulk operation items"
  ON public.admin_bulk_operation_items FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update bulk operation items"
  ON public.admin_bulk_operation_items FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE OR REPLACE FUNCTION public.admin_require_approved()
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := auth.uid();
BEGIN
  IF actor_id IS NULL OR NOT public.current_profile_is_admin() THEN
    RAISE EXCEPTION 'Admin access required' USING ERRCODE = '42501';
  END IF;

  RETURN actor_id;
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
    'paid', reservation.paid = 1,
    'deleted', reservation."Deleted" = 1,
    'bulkOperationId', reservation.bulk_operation_id,
    'createdDT', reservation."createdDT",
    'updatedDT', reservation."updatedDT"
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
    'subjectType', subject.subject_type,
    'displayName', subject.display_name,
    'contactName', coalesce(subject.contact_name, ''),
    'contactEmail', coalesce(subject.contact_email, ''),
    'contactPhone', coalesce(subject.contact_phone, ''),
    'notes', coalesce(subject.notes, ''),
    'deleted', subject."Deleted" = 1,
    'createdDT', subject."createdDT",
    'updatedDT', subject."updatedDT"
  );
$$;

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
    'createdDT', operation."createdDT",
    'updatedDT', operation."updatedDT"
  );
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
  pending_json jsonb;
  bookings_json jsonb;
  subjects_json jsonb;
  operations_json jsonb;
BEGIN
  SELECT *
  INTO config_row
  FROM public.facility_config
  WHERE id = true;

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
        jsonb_build_object(
          'open', to_char(hours.open_time, 'HH24:MI'),
          'close', to_char(hours.close_time, 'HH24:MI'),
          'closed', hours.is_closed
        )
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
  )
  INTO settings_json;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'id', profile.id,
    'username', profile.username,
    'email', profile.email,
    'name', profile.display_name,
    'team', profile.team_name,
    'role', profile.account_role,
    'approved', profile.approval_status = 'approved',
    'authenticated', true
  ) ORDER BY profile."createdDT"), '[]'::jsonb)
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

  SELECT coalesce(jsonb_agg(public.admin_bulk_operation_json(operation) ORDER BY operation."createdDT"), '[]'::jsonb)
  INTO operations_json
  FROM public.admin_bulk_operations operation
  WHERE operation."Deleted" = 0;

  RETURN jsonb_build_object(
    'settings', settings_json,
    'pendingUsers', pending_json,
    'bookings', bookings_json,
    'adminSubjects', subjects_json,
    'bulkOperations', operations_json,
    'actorId', actor_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_subject(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.admin_subjects%ROWTYPE;
BEGIN
  IF coalesce(payload->>'displayName', '') = '' THEN
    RAISE EXCEPTION 'Team or coach name is required' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.admin_subjects (
    subject_type,
    display_name,
    contact_name,
    contact_email,
    contact_phone,
    notes,
    created_by
  ) VALUES (
    coalesce(payload->>'subjectType', 'team'),
    payload->>'displayName',
    nullif(payload->>'contactName', ''),
    nullif(payload->>'contactEmail', ''),
    nullif(payload->>'contactPhone', ''),
    coalesce(nullif(payload->>'notes', ''), 'Temporary admin-created record'),
    actor_id
  )
  RETURNING * INTO subject;

  RETURN public.admin_subject_json(subject);
END;
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
  SET paid = CASE WHEN p_paid THEN 1 ELSE 0 END,
      payment_status = CASE WHEN p_paid THEN 'paid' ELSE 'due' END,
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

CREATE OR REPLACE FUNCTION public.admin_approve_profile(p_profile_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  profile public.profiles%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  UPDATE public.profiles
  SET approval_status = 'approved',
      updated_at = now()
  WHERE id = p_profile_id
    AND "Deleted" = 0
  RETURNING * INTO profile;

  IF profile.id IS NULL THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = '22023';
  END IF;

  RETURN jsonb_build_object(
    'id', profile.id,
    'username', profile.username,
    'email', profile.email,
    'name', profile.display_name,
    'team', profile.team_name,
    'role', profile.account_role,
    'approved', profile.approval_status = 'approved',
    'authenticated', true
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
      updated_at = now()
  WHERE id = true;

  RETURN public.admin_get_dashboard();
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_operating_hours(p_day_of_week integer, p_open_time time, p_close_time time, p_is_closed boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_require_approved();

  INSERT INTO public.operating_hours (day_of_week, open_time, close_time, is_closed)
  VALUES (p_day_of_week, p_open_time, p_close_time, coalesce(p_is_closed, false))
  ON CONFLICT (day_of_week) DO UPDATE SET
    open_time = excluded.open_time,
    close_time = excluded.close_time,
    is_closed = excluded.is_closed;

  RETURN public.admin_get_dashboard();
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
  config public.facility_config%ROWTYPE;
  local_date date := (payload->>'startDate')::date;
  end_date date := coalesce((payload->>'endDate')::date, (payload->>'startDate')::date);
  slot_start_time time := (payload->>'startTime')::time;
  duration_minutes integer := coalesce((payload->>'durationMinutes')::integer, 60);
  resource text := coalesce(payload->>'resourceType', 'court');
  requested_court integer := nullif(replace(coalesce(payload->>'courtId', ''), 'court-', ''), '')::integer;
  conflict_resolution text := coalesce(payload->>'conflictResolution', 'skip_conflicts');
  paid_flag boolean := coalesce((payload->>'paid')::boolean, false);
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

  SELECT *
  INTO subject
  FROM public.admin_subjects
  WHERE id = (payload->>'subjectId')::uuid
    AND "Deleted" = 0;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Team or coach record not found' USING ERRCODE = '22023';
  END IF;

  SELECT *
  INTO config
  FROM public.facility_config
  WHERE id = true;

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
        SELECT 1
        FROM public.closures closure
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
          SELECT court_number
          INTO resolved_court
          FROM generate_series(1, config.court_count) AS available_court(court_number)
          WHERE NOT EXISTS (
            SELECT 1
            FROM public.reservations reservation
            WHERE reservation."Deleted" = 0
              AND reservation.status <> 'cancelled'
              AND reservation.resource_type = 'court'
              AND reservation.court_number = court_number
              AND reservation.start_at < slot_end_at
              AND slot_start_at < reservation.end_at
          )
          AND NOT EXISTS (
            SELECT 1
            FROM public.fixed_reservations fixed
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
          SELECT 1
          FROM public.reservations reservation
          WHERE reservation."Deleted" = 0
            AND reservation.status <> 'cancelled'
            AND reservation.resource_type = 'court'
            AND reservation.court_number = resolved_court
            AND reservation.start_at < slot_end_at
            AND slot_start_at < reservation.end_at
        ) OR EXISTS (
          SELECT 1
          FROM public.fixed_reservations fixed
          WHERE fixed."Deleted" = 0
            AND fixed.resource_type = 'court'
            AND fixed.court_number = resolved_court
            AND extract(dow FROM local_date)::integer = ANY(fixed.days_of_week)
            AND local_date BETWEEN fixed.start_date AND fixed.end_date
            AND fixed.start_time < (slot_start_time + make_interval(mins => duration_minutes))::time
            AND slot_start_time < fixed.end_time
        ) THEN
          IF conflict_resolution = 'first_available_court' THEN
            SELECT court_number
            INTO resolved_court
          FROM generate_series(1, config.court_count) AS available_court(court_number)
            WHERE NOT EXISTS (
              SELECT 1
              FROM public.reservations reservation
              WHERE reservation."Deleted" = 0
                AND reservation.status <> 'cancelled'
                AND reservation.resource_type = 'court'
                AND reservation.court_number = court_number
                AND reservation.start_at < slot_end_at
                AND slot_start_at < reservation.end_at
            )
            AND NOT EXISTS (
              SELECT 1
              FROM public.fixed_reservations fixed
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
          ELSE
            item_status := 'conflict';
            conflict_reason := 'Court is already reserved';
          END IF;
        END IF;

        IF item_status = 'preview' AND (resolved_court IS NULL OR resolved_court NOT BETWEEN 1 AND config.court_count) THEN
          item_status := 'conflict';
          conflict_reason := 'No court is available';
        END IF;
      END IF;

      IF item_status = 'preview' AND resource = 'trainer' THEN
        SELECT
          (SELECT count(*)
           FROM public.reservations reservation
           WHERE reservation."Deleted" = 0
             AND reservation.status <> 'cancelled'
             AND reservation.resource_type = 'trainer'
             AND reservation.start_at < slot_end_at
             AND slot_start_at < reservation.end_at)
          + coalesce((
            SELECT sum(fixed.capacity)
            FROM public.fixed_reservations fixed
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
    'paid', coalesce((payload->>'paid')::boolean, false),
    'conflictResolution', coalesce(payload->>'conflictResolution', 'skip_conflicts'),
    'requestedPayload', payload,
    'items', items
  );
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
  item_reservation_id uuid;
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
    (payload->>'subjectId')::uuid,
    (payload->>'startDate')::date,
    coalesce((payload->>'endDate')::date, (payload->>'startDate')::date),
    CASE WHEN nullif(payload->>'applyAfter', '') IS NULL THEN 'previewed' ELSE 'scheduled' END,
    nullif(payload->>'applyAfter', '')::timestamptz,
    CASE WHEN coalesce((payload->>'paid')::boolean, false) THEN 1 ELSE 0 END,
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
      paid,
      status,
      conflict_reason
    ) VALUES (
      operation.id,
      'create',
      (item->>'subjectId')::uuid,
      item->>'resourceType',
      nullif(replace(coalesce(item->>'courtId', ''), 'court-', ''), '')::integer,
      (item->>'start')::timestamptz,
      (item->>'end')::timestamptz,
      CASE WHEN coalesce((item->>'paid')::boolean, false) THEN 1 ELSE 0 END,
      CASE WHEN item->>'status' = 'conflict' THEN 'conflict' ELSE 'preview' END,
      item->>'conflictReason'
    )
    RETURNING reservation_id INTO item_reservation_id;
  END LOOP;

  RETURN public.admin_bulk_operation_json(operation) || jsonb_build_object('items', preview->'items');
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
    operation_type,
    label,
    subject_id,
    start_date,
    end_date,
    status,
    paid,
    conflict_resolution,
    requested_payload,
    preview_payload,
    created_by,
    applied_by,
    "appliedDT"
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
  )
  RETURNING * INTO operation;

  FOR item IN SELECT value FROM jsonb_array_elements(preview->'items')
  LOOP
    IF item->>'status' = 'conflict' THEN
      INSERT INTO public.admin_bulk_operation_items (
        bulk_operation_id, action, subject_id, resource_type, court_number, start_at, end_at, paid, status, conflict_reason
      ) VALUES (
        operation.id,
        'create',
        (item->>'subjectId')::uuid,
        item->>'resourceType',
        nullif(replace(coalesce(item->>'courtId', ''), 'court-', ''), '')::integer,
        (item->>'start')::timestamptz,
        (item->>'end')::timestamptz,
        CASE WHEN coalesce((item->>'paid')::boolean, false) THEN 1 ELSE 0 END,
        'skipped',
        item->>'conflictReason'
      );
      CONTINUE;
    END IF;

    INSERT INTO public.reservations (
      user_id,
      team_name,
      subject_id,
      resource_type,
      court_number,
      start_at,
      end_at,
      status,
      payment_status,
      paid,
      created_by,
      bulk_operation_id
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
      actor_id,
      operation.id
    )
    RETURNING * INTO reservation;

    INSERT INTO public.admin_bulk_operation_items (
      bulk_operation_id, reservation_id, action, subject_id, resource_type, court_number, start_at, end_at, paid, status
    ) VALUES (
      operation.id,
      reservation.id,
      'create',
      reservation.subject_id,
      reservation.resource_type,
      reservation.court_number,
      reservation.start_at,
      reservation.end_at,
      reservation.paid,
      'applied'
    );

    created := created || jsonb_build_array(public.admin_reservation_json(reservation));
  END LOOP;

  RETURN jsonb_build_object(
    'operation', public.admin_bulk_operation_json(operation),
    'created', created,
    'items', preview->'items'
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_preview_delete_reservations(p_subject_id uuid, p_start_date date, p_end_date date)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_require_approved();

  RETURN coalesce((
    SELECT jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at)
    FROM public.reservations reservation
    WHERE reservation."Deleted" = 0
      AND reservation.status <> 'cancelled'
      AND (reservation.subject_id = p_subject_id OR reservation.user_id = p_subject_id)
      AND reservation.start_at < ((p_end_date + 1)::timestamp AT TIME ZONE (SELECT timezone FROM public.facility_config WHERE id = true))
      AND (p_start_date::timestamp AT TIME ZONE (SELECT timezone FROM public.facility_config WHERE id = true)) < reservation.end_at
  ), '[]'::jsonb);
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
  delete_start_at timestamptz := (p_start_date::timestamp AT TIME ZONE (SELECT timezone FROM public.facility_config WHERE id = true));
  delete_end_at timestamptz := ((p_end_date + 1)::timestamp AT TIME ZONE (SELECT timezone FROM public.facility_config WHERE id = true));
BEGIN
  SELECT *
  INTO subject
  FROM public.admin_subjects
  WHERE id = p_subject_id
    AND "Deleted" = 0;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Team or coach record not found' USING ERRCODE = '22023';
  END IF;

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
    'Delete reservations for ' || subject.display_name,
    subject.id,
    p_start_date,
    p_end_date,
    'applied',
    jsonb_build_object('subjectId', p_subject_id, 'startDate', p_start_date, 'endDate', p_end_date),
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
    'deleted', deleted
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_undo_bulk_operation(p_operation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  operation public.admin_bulk_operations%ROWTYPE;
  reservation_id uuid;
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
    UPDATE public.reservations
    SET "Deleted" = 1,
        updated_at = now()
    WHERE bulk_operation_id = operation.id;
  ELSIF operation.operation_type = 'reservation_delete' THEN
    UPDATE public.reservations
    SET "Deleted" = 0,
        updated_at = now()
    WHERE id IN (
      SELECT item.reservation_id
      FROM public.admin_bulk_operation_items item
      WHERE item.bulk_operation_id = operation.id
        AND item.reservation_id IS NOT NULL
    );
  END IF;

  UPDATE public.admin_bulk_operation_items
  SET status = 'undone'
  WHERE bulk_operation_id = operation.id;

  UPDATE public.admin_bulk_operations
  SET status = 'undone',
      undone_by = actor_id,
      "undoneDT" = now()
  WHERE id = operation.id
  RETURNING * INTO operation;

  RETURN public.admin_bulk_operation_json(operation);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_require_approved() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_get_dashboard() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_create_subject(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_mark_reservation_paid(uuid, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_approve_profile(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_update_facility_config(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_update_operating_hours(integer, time, time, boolean) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_preview_bulk_reservations(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_save_bulk_reservations(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_apply_bulk_reservations(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_preview_delete_reservations(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_apply_delete_reservations(uuid, date, date) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_undo_bulk_operation(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_get_dashboard() TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_subject(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_mark_reservation_paid(uuid, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_approve_profile(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_facility_config(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_operating_hours(integer, time, time, boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_preview_bulk_reservations(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_save_bulk_reservations(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_bulk_reservations(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_preview_delete_reservations(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_apply_delete_reservations(uuid, date, date) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_undo_bulk_operation(uuid) TO authenticated;
