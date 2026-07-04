CREATE TABLE IF NOT EXISTS public.client_types (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  have_teams boolean NOT NULL DEFAULT false,
  sort_order integer NOT NULL DEFAULT 100,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS client_types_unique_active_name_idx
  ON public.client_types(lower(name))
  WHERE "Deleted" = 0;

CREATE TRIGGER client_types_set_updated_dt BEFORE UPDATE ON public.client_types
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();

ALTER TABLE public.client_types ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read active client types"
  ON public.client_types FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert client types"
  ON public.client_types FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update client types"
  ON public.client_types FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

INSERT INTO public.client_types (name, have_teams, sort_order)
VALUES
  ('Club', true, 10),
  ('Academy', true, 20),
  ('Coach', false, 30),
  ('Pickleball', false, 40)
ON CONFLICT DO NOTHING;

ALTER TABLE public.subjects
  ADD COLUMN IF NOT EXISTS short_name text,
  ADD COLUMN IF NOT EXISTS client_type_id uuid REFERENCES public.client_types(id),
  ADD COLUMN IF NOT EXISTS disabled_at timestamptz,
  ADD COLUMN IF NOT EXISTS disabled_by uuid REFERENCES public.profiles(id),
  ADD COLUMN IF NOT EXISTS disabled_reason text;

UPDATE public.subjects subject
SET short_name = coalesce(nullif(subject.short_name, ''), left(regexp_replace(subject.display_name, '\s+', ' ', 'g'), 24)),
    client_type_id = coalesce(
      subject.client_type_id,
      CASE
        WHEN subject.subject_type = 'coach' THEN (SELECT id FROM public.client_types WHERE lower(name) = 'coach' AND "Deleted" = 0 LIMIT 1)
        ELSE (SELECT id FROM public.client_types WHERE lower(name) = 'club' AND "Deleted" = 0 LIMIT 1)
      END
    )
WHERE subject."Deleted" = 0;

ALTER TABLE public.subjects
  ALTER COLUMN short_name SET DEFAULT '',
  ALTER COLUMN subject_type SET DEFAULT 'club';

CREATE INDEX IF NOT EXISTS subjects_client_type_idx
  ON public.subjects(client_type_id)
  WHERE "Deleted" = 0;

CREATE TABLE IF NOT EXISTS public.subject_teams (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL REFERENCES public.subjects(id) ON DELETE RESTRICT,
  name text NOT NULL,
  short_name text NOT NULL,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX IF NOT EXISTS subject_teams_unique_active_name_idx
  ON public.subject_teams(subject_id, lower(name))
  WHERE "Deleted" = 0;

CREATE INDEX IF NOT EXISTS subject_teams_subject_idx
  ON public.subject_teams(subject_id)
  WHERE "Deleted" = 0;

CREATE TRIGGER subject_teams_set_updated_dt BEFORE UPDATE ON public.subject_teams
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();

ALTER TABLE public.subject_teams ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read active subject teams"
  ON public.subject_teams FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert subject teams"
  ON public.subject_teams FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update subject teams"
  ON public.subject_teams FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS subject_team_id uuid REFERENCES public.subject_teams(id) ON DELETE RESTRICT,
  ADD COLUMN IF NOT EXISTS reservation_source text NOT NULL DEFAULT 'bulk' CHECK (reservation_source IN ('bulk', 'calendar', 'booking'));

ALTER TABLE public.admin_bulk_operation_items
  ADD COLUMN IF NOT EXISTS subject_team_id uuid REFERENCES public.subject_teams(id) ON DELETE RESTRICT;

ALTER TABLE public.team_season_prices
  ADD COLUMN IF NOT EXISTS documents_received boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS deposit numeric(10, 2) NOT NULL DEFAULT 0 CHECK (deposit >= 0);

CREATE TABLE IF NOT EXISTS public.audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id uuid REFERENCES public.profiles(id),
  actor_username text,
  action text NOT NULL,
  object_type text NOT NULL,
  object_id uuid,
  object_label text,
  before_data jsonb,
  after_data jsonb,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  "createdDT" timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS audit_events_actor_idx ON public.audit_events(actor_id, "createdDT" DESC);
CREATE INDEX IF NOT EXISTS audit_events_object_idx ON public.audit_events(object_type, object_id, "createdDT" DESC);

ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read audit events"
  ON public.audit_events FOR SELECT
  USING (public.current_profile_is_admin());

CREATE OR REPLACE FUNCTION public.audit_log(
  p_action text,
  p_object_type text,
  p_object_id uuid DEFAULT NULL,
  p_object_label text DEFAULT NULL,
  p_before_data jsonb DEFAULT NULL,
  p_after_data jsonb DEFAULT NULL,
  p_metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor public.profiles%ROWTYPE;
BEGIN
  SELECT *
  INTO actor
  FROM public.profiles
  WHERE id = auth.uid();

  INSERT INTO public.audit_events (
    actor_id,
    actor_username,
    action,
    object_type,
    object_id,
    object_label,
    before_data,
    after_data,
    metadata
  ) VALUES (
    actor.id,
    coalesce(actor.username, actor.email, actor.display_name),
    p_action,
    p_object_type,
    p_object_id,
    p_object_label,
    p_before_data,
    p_after_data,
    coalesce(p_metadata, '{}'::jsonb)
  );
END;
$$;

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
  "createdDT",
  "updatedDT"
FROM public.subjects;

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
    'createdDT', client_type."createdDT",
    'updatedDT', client_type."updatedDT"
  );
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
    'deleted', team."Deleted" = 1,
    'createdDT', team."createdDT",
    'updatedDT', team."updatedDT"
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
      SELECT jsonb_agg(public.admin_subject_membership_json(membership) ORDER BY membership."createdDT")
      FROM public.subject_memberships membership
      WHERE membership.subject_id = subject.id
        AND membership."Deleted" = 0
    ), '[]'::jsonb),
    'deleted', subject."Deleted" = 1,
    'createdDT', subject."createdDT",
    'updatedDT', subject."updatedDT"
  )
  FROM public.subjects base
  LEFT JOIN public.client_types client_type ON client_type.id = base.client_type_id
  WHERE base.id = subject.id;
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
    'createdDT', reservation."createdDT",
    'updatedDT', reservation."updatedDT"
  )
  FROM public.reservations base
  LEFT JOIN public.subject_teams team ON team.id = reservation.subject_team_id
  WHERE base.id = reservation.id;
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
    'createdDT', price."createdDT",
    'updatedDT', price."updatedDT"
  )
  FROM public.admin_subjects subject
  LEFT JOIN public.seasons season
    ON season.id = price.season_id
  WHERE subject.id = price.subject_id;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_client_type(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  client_type public.client_types%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  INSERT INTO public.client_types (name, have_teams, sort_order)
  VALUES (
    trim(payload->>'name'),
    coalesce((payload->>'haveTeams')::boolean, false),
    coalesce((payload->>'sortOrder')::integer, 100)
  )
  RETURNING * INTO client_type;

  PERFORM public.audit_log('create', 'client_type', client_type.id, client_type.name, NULL, to_jsonb(client_type));

  RETURN public.admin_client_type_json(client_type);
END;
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
      "updatedDT" = now()
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
      "updatedDT" = now()
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

CREATE OR REPLACE FUNCTION public.admin_create_subject(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.admin_subjects%ROWTYPE;
  client_type public.client_types%ROWTYPE;
  next_email text := nullif(trim(payload->>'contactEmail'), '');
BEGIN
  IF coalesce(payload->>'displayName', '') = '' THEN
    RAISE EXCEPTION 'Client name is required' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO client_type
  FROM public.client_types
  WHERE id = nullif(payload->>'clientTypeId', '')::uuid
    AND "Deleted" = 0;

  IF client_type.id IS NULL THEN
    SELECT * INTO client_type
    FROM public.client_types
    WHERE lower(name) = lower(coalesce(nullif(payload->>'subjectType', ''), 'Club'))
      AND "Deleted" = 0
    LIMIT 1;
  END IF;

  IF client_type.id IS NULL THEN
    RAISE EXCEPTION 'Client type is required' USING ERRCODE = '22023';
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
    lower(client_type.name),
    payload->>'displayName',
    nullif(payload->>'contactName', ''),
    next_email,
    nullif(payload->>'contactPhone', ''),
    coalesce(nullif(payload->>'notes', ''), 'Admin-created client record'),
    actor_id
  )
  RETURNING * INTO subject;

  UPDATE public.subjects
  SET short_name = coalesce(nullif(payload->>'shortName', ''), left(subject.display_name, 24)),
      client_type_id = client_type.id
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

  PERFORM public.audit_log('create', 'client', subject.id, subject.display_name, NULL, public.admin_subject_json(subject));

  RETURN public.admin_subject_json(subject);
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
      "updatedDT" = now()
  WHERE id = p_subject_id
    AND "Deleted" = 0
  RETURNING * INTO subject;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Client record not found' USING ERRCODE = '22023';
  END IF;

  UPDATE public.subjects
  SET short_name = coalesce(nullif(payload->>'shortName', ''), left(subject.display_name, 24)),
      client_type_id = client_type.id,
      "updatedDT" = now()
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
      "updatedDT" = now()
  WHERE id = p_subject_id
    AND "Deleted" = 0
  RETURNING id, subject_type, display_name, contact_name, contact_email, contact_phone, notes, created_by, "Deleted", "createdDT", "updatedDT"
  INTO subject;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Client record not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('disable', 'client', subject.id, subject.display_name, NULL, public.admin_subject_json(subject));

  RETURN public.admin_subject_json(subject);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_subject_team(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  team public.subject_teams%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  INSERT INTO public.subject_teams (subject_id, name, short_name)
  VALUES (
    nullif(payload->>'subjectId', '')::uuid,
    trim(payload->>'name'),
    coalesce(nullif(trim(payload->>'shortName'), ''), left(trim(payload->>'name'), 24))
  )
  RETURNING * INTO team;

  PERFORM public.audit_log('create', 'client_team', team.id, team.name, NULL, to_jsonb(team));

  RETURN public.admin_subject_team_json(team);
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
      "updatedDT" = now()
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
      "updatedDT" = now()
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

CREATE OR REPLACE FUNCTION public.admin_bulk_preview_items(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.admin_subjects%ROWTYPE;
  subject_base public.subjects%ROWTYPE;
  client_type public.client_types%ROWTYPE;
  subject_team public.subject_teams%ROWTYPE;
  season_price public.team_season_prices%ROWTYPE;
  config public.facility_config%ROWTYPE;
  local_date date := (payload->>'startDate')::date;
  end_date date := coalesce((payload->>'endDate')::date, (payload->>'startDate')::date);
  slot_start_time time := (payload->>'startTime')::time;
  duration_minutes integer := coalesce((payload->>'durationMinutes')::integer, 60);
  resource text := coalesce(payload->>'resourceType', 'court');
  requested_court integer := nullif(replace(coalesce(payload->>'courtId', ''), 'court-', ''), '')::integer;
  avoid_court_one boolean := coalesce(payload->>'courtId', '') = 'auto_except_1';
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
    RAISE EXCEPTION 'Select a client before previewing reservations' USING ERRCODE = '22023';
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

  SELECT * INTO subject_base FROM public.subjects WHERE id = subject.id;
  SELECT * INTO client_type FROM public.client_types WHERE id = subject_base.client_type_id;

  IF subject.id IS NULL OR subject_base.disabled_at IS NOT NULL THEN
    RAISE EXCEPTION 'Active client record not found' USING ERRCODE = '22023';
  END IF;

  IF coalesce(client_type.have_teams, false) THEN
    SELECT * INTO subject_team
    FROM public.subject_teams
    WHERE id = nullif(payload->>'subjectTeamId', '')::uuid
      AND subject_id = subject.id
      AND "Deleted" = 0;

    IF subject_team.id IS NULL THEN
      RAISE EXCEPTION 'Select a team for this client before creating reservations' USING ERRCODE = '22023';
    END IF;
  END IF;

  SELECT * INTO config FROM public.facility_config WHERE id = true;

  IF nullif(payload->>'seasonPriceId', '') IS NOT NULL THEN
    SELECT * INTO season_price
    FROM public.team_season_prices
    WHERE id = nullif(payload->>'seasonPriceId', '')::uuid
      AND subject_id = subject.id
      AND "Deleted" = 0;

    IF season_price.id IS NULL THEN
      RAISE EXCEPTION 'Season price not found for selected client' USING ERRCODE = '22023';
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
              AND (NOT avoid_court_one OR available_court.court_number <> 1)
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
        'subjectShortName', subject_base.short_name,
        'subjectTeamId', subject_team.id,
        'teamName', subject_team.name,
        'teamShortName', subject_team.short_name,
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
        user_id, team_name, subject_id, subject_team_id, resource_type, court_number, start_at, end_at, status, payment_status, season_price_id, season_label, hourly_rate, amount, created_by, bulk_operation_id, reservation_source
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
        coalesce(nullif(payload->>'source', ''), 'bulk')
      ) RETURNING * INTO reservation;

      INSERT INTO public.admin_bulk_operation_items (
        bulk_operation_id, reservation_id, action, subject_id, subject_team_id, resource_type, court_number, start_at, end_at, season_price_id, season_label, hourly_rate, amount_due, paid, status
      ) VALUES (
        operation.id, reservation.id, 'create', reservation.subject_id, reservation.subject_team_id, reservation.resource_type, reservation.court_number, reservation.start_at, reservation.end_at,
        reservation.season_price_id, reservation.season_label, reservation.hourly_rate, reservation.amount, CASE WHEN reservation.payment_status = 'paid' THEN 1 ELSE 0 END, 'applied'
      );

      PERFORM public.audit_log('create', 'reservation', reservation.id, reservation.team_name, NULL, public.admin_reservation_json(reservation), jsonb_build_object('source', coalesce(nullif(payload->>'source', ''), 'bulk'), 'bulkOperationId', operation.id));

      created := created || jsonb_build_array(public.admin_reservation_json(reservation));
    END LOOP;
  END LOOP;

  PERFORM public.audit_log('create', 'bulk_reservation', operation.id, operation.label, NULL, public.admin_bulk_operation_json(operation));

  RETURN jsonb_build_object('operation', public.admin_bulk_operation_json(operation), 'created', created, 'items', preview->'items');
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_create_team_season_price(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.admin_subjects%ROWTYPE;
  price public.team_season_prices%ROWTYPE;
BEGIN
  SELECT *
  INTO subject
  FROM public.admin_subjects
  WHERE id = (payload->>'subjectId')::uuid
    AND "Deleted" = 0;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Client record not found' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.team_season_prices (
    subject_id, season_id, season, season_year, hourly_rate, documents_received, deposit, created_by
  )
  SELECT
    subject.id,
    season.id,
    season.display_name,
    season.start_year,
    (payload->>'hourlyRate')::numeric,
    coalesce((payload->>'documentsReceived')::boolean, false),
    coalesce(nullif(payload->>'deposit', '')::numeric, 0),
    actor_id
  FROM public.seasons season
  WHERE season.id = (payload->>'seasonId')::uuid
    AND season."Deleted" = 0
  RETURNING * INTO price;

  IF price.id IS NULL THEN
    RAISE EXCEPTION 'Season record not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log('create', 'club_season', price.id, subject.display_name, NULL, public.admin_team_season_price_json(price));

  RETURN public.admin_team_season_price_json(price);
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
      "updatedDT" = now()
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
BEGIN
  SELECT public.admin_facility_settings_json() INTO settings_json;

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

  SELECT coalesce(jsonb_agg(public.admin_client_type_json(client_type) ORDER BY client_type.sort_order, client_type.name), '[]'::jsonb)
  INTO client_types_json
  FROM public.client_types client_type
  WHERE client_type."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_subject_team_json(team) ORDER BY team.name), '[]'::jsonb)
  INTO subject_teams_json
  FROM public.subject_teams team
  WHERE team."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_subject_membership_json(membership) ORDER BY membership."createdDT"), '[]'::jsonb)
  INTO subject_memberships_json
  FROM public.subject_memberships membership
  WHERE membership."Deleted" = 0;

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
    'clientTypes', client_types_json,
    'subjectTeams', subject_teams_json,
    'subjectMemberships', subject_memberships_json,
    'seasons', seasons_json,
    'teamSeasonPrices', season_prices_json,
    'bulkOperations', operations_json,
    'invoices', invoices_json,
    'payments', payments_json,
    'actorId', actor_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.audit_log(text, text, uuid, text, jsonb, jsonb, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_client_type_json(public.client_types) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_subject_team_json(public.subject_teams) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_create_client_type(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_update_client_type(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_client_type(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_disable_subject(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_create_subject_team(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_update_subject_team(uuid, jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_delete_subject_team(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_create_client_type(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_client_type(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_client_type(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_disable_subject(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_subject_team(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_subject_team(uuid, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_delete_subject_team(uuid) TO authenticated;
