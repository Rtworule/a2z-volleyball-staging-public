ALTER TABLE public.admin_subjects RENAME TO subjects;

COMMENT ON TABLE public.subjects IS 'Billable/reservable business entities such as teams and private coaches. Kept compatible with the former admin_subjects API through a view.';

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
    "createdDT",
    "updatedDT"
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
    coalesce(NEW."createdDT", now()),
    coalesce(NEW."updatedDT", now())
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
  NEW."createdDT" := inserted."createdDT";
  NEW."updatedDT" := inserted."updatedDT";

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
      "createdDT" = NEW."createdDT",
      "updatedDT" = coalesce(NEW."updatedDT", now())
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
  NEW."createdDT" := updated."createdDT";
  NEW."updatedDT" := updated."updatedDT";

  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_subjects_delete_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  DELETE FROM public.subjects
  WHERE id = OLD.id;

  RETURN OLD;
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

CREATE TABLE public.subject_memberships (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  subject_id uuid NOT NULL REFERENCES public.subjects(id) ON DELETE CASCADE,
  profile_id uuid REFERENCES public.profiles(id) ON DELETE CASCADE,
  invited_email text,
  membership_role text NOT NULL DEFAULT 'owner' CHECK (membership_role IN ('owner', 'scheduler', 'billing', 'viewer')),
  status text NOT NULL DEFAULT 'invited' CHECK (status IN ('invited', 'active', 'disabled')),
  can_book boolean NOT NULL DEFAULT true,
  can_view_invoices boolean NOT NULL DEFAULT true,
  "Deleted" integer NOT NULL DEFAULT 0,
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT subject_memberships_profile_or_email_check CHECK (profile_id IS NOT NULL OR nullif(invited_email, '') IS NOT NULL)
);

CREATE INDEX subject_memberships_subject_idx
  ON public.subject_memberships(subject_id)
  WHERE "Deleted" = 0;

CREATE INDEX subject_memberships_profile_idx
  ON public.subject_memberships(profile_id)
  WHERE profile_id IS NOT NULL AND "Deleted" = 0;

CREATE UNIQUE INDEX subject_memberships_subject_profile_unique
  ON public.subject_memberships(subject_id, profile_id)
  WHERE profile_id IS NOT NULL AND "Deleted" = 0;

CREATE UNIQUE INDEX subject_memberships_subject_email_unique
  ON public.subject_memberships(subject_id, lower(invited_email))
  WHERE invited_email IS NOT NULL AND "Deleted" = 0;

CREATE TRIGGER subject_memberships_set_updated_dt BEFORE UPDATE ON public.subject_memberships
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();

ALTER TABLE public.subject_memberships ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read active subject memberships"
  ON public.subject_memberships FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins insert subject memberships"
  ON public.subject_memberships FOR INSERT
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Admins update subject memberships"
  ON public.subject_memberships FOR UPDATE
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

CREATE POLICY "Members read own subject memberships"
  ON public.subject_memberships FOR SELECT
  USING (profile_id = auth.uid() AND "Deleted" = 0);

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
    'createdDT', membership."createdDT",
    'updatedDT', membership."updatedDT"
  )
  FROM (SELECT membership.*) current_membership
  LEFT JOIN public.profiles profile ON profile.id = current_membership.profile_id;
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
    'memberships', coalesce((
      SELECT jsonb_agg(public.admin_subject_membership_json(membership) ORDER BY membership."createdDT")
      FROM public.subject_memberships membership
      WHERE membership.subject_id = subject.id
        AND membership."Deleted" = 0
    ), '[]'::jsonb),
    'deleted', subject."Deleted" = 1,
    'createdDT', subject."createdDT",
    'updatedDT', subject."updatedDT"
  );
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
      "updatedDT" = now()
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

INSERT INTO public.subject_memberships (
  subject_id,
  invited_email,
  membership_role,
  status
)
SELECT
  subject.id,
  subject.contact_email,
  'owner',
  'invited'
FROM public.subjects subject
WHERE nullif(subject.contact_email, '') IS NOT NULL
  AND subject."Deleted" = 0
  AND NOT EXISTS (
    SELECT 1
    FROM public.subject_memberships membership
    WHERE membership.subject_id = subject.id
      AND lower(membership.invited_email) = lower(subject.contact_email)
      AND membership."Deleted" = 0
  );

UPDATE public.subject_memberships membership
SET profile_id = profile.id,
    status = 'active',
    "updatedDT" = now()
FROM public.profiles profile
WHERE membership.profile_id IS NULL
  AND lower(membership.invited_email) = lower(profile.email)
  AND profile."Deleted" = 0
  AND membership."Deleted" = 0;

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  requested_username text := nullif(trim(new.raw_user_meta_data->>'username'), '');
  requested_display_name text := nullif(trim(new.raw_user_meta_data->>'display_name'), '');
  requested_team_name text := nullif(trim(new.raw_user_meta_data->>'team_name'), '');
BEGIN
  INSERT INTO public.profiles (
    id,
    username,
    email,
    display_name,
    team_name,
    account_role,
    approval_status
  ) VALUES (
    new.id,
    coalesce(requested_username, split_part(new.email, '@', 1)),
    new.email,
    coalesce(requested_display_name, split_part(new.email, '@', 1)),
    requested_team_name,
    'user',
    'pending'
  )
  ON CONFLICT (id) DO NOTHING;

  PERFORM public.link_profile_to_subjects_by_email(new.id, new.email);

  RETURN new;
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
  next_type text := coalesce(nullif(payload->>'subjectType', ''), 'team');
  next_email text := nullif(trim(payload->>'contactEmail'), '');
BEGIN
  IF next_type NOT IN ('team', 'coach') THEN
    RAISE EXCEPTION 'Type must be team or coach' USING ERRCODE = '22023';
  END IF;

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
    next_type,
    payload->>'displayName',
    nullif(payload->>'contactName', ''),
    next_email,
    nullif(payload->>'contactPhone', ''),
    coalesce(nullif(payload->>'notes', ''), 'Admin-created team/coach record'),
    actor_id
  )
  RETURNING * INTO subject;

  IF next_email IS NOT NULL THEN
    INSERT INTO public.subject_memberships (
      subject_id,
      invited_email,
      membership_role,
      status
    ) VALUES (
      subject.id,
      next_email,
      'owner',
      'invited'
    )
    ON CONFLICT DO NOTHING;

    PERFORM public.link_profile_to_subjects_by_email(profile.id, profile.email)
    FROM public.profiles profile
    WHERE lower(profile.email) = lower(next_email)
      AND profile."Deleted" = 0;
  END IF;

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
  subject public.admin_subjects%ROWTYPE;
  next_type text := coalesce(nullif(payload->>'subjectType', ''), 'team');
  next_email text := nullif(trim(payload->>'contactEmail'), '');
BEGIN
  PERFORM public.admin_require_approved();

  IF next_type NOT IN ('team', 'coach') THEN
    RAISE EXCEPTION 'Type must be team or coach' USING ERRCODE = '22023';
  END IF;

  UPDATE public.admin_subjects
  SET subject_type = next_type,
      display_name = coalesce(nullif(payload->>'displayName', ''), display_name),
      contact_name = nullif(payload->>'contactName', ''),
      contact_email = next_email,
      contact_phone = nullif(payload->>'contactPhone', ''),
      notes = coalesce(nullif(payload->>'notes', ''), notes),
      "updatedDT" = now()
  WHERE id = p_subject_id
    AND "Deleted" = 0
  RETURNING * INTO subject;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Team or coach record not found' USING ERRCODE = '22023';
  END IF;

  IF next_email IS NOT NULL THEN
    INSERT INTO public.subject_memberships (
      subject_id,
      invited_email,
      membership_role,
      status
    ) VALUES (
      subject.id,
      next_email,
      'owner',
      'invited'
    )
    ON CONFLICT DO NOTHING;

    PERFORM public.link_profile_to_subjects_by_email(profile.id, profile.email)
    FROM public.profiles profile
    WHERE lower(profile.email) = lower(next_email)
      AND profile."Deleted" = 0;
  END IF;

  RETURN public.admin_subject_json(subject);
END;
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
  ORDER BY "createdDT"
  LIMIT 1;

  IF membership.id IS NULL THEN
    RAISE EXCEPTION 'Subject membership could not be created' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_subject_membership_json(membership);
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
  subject_memberships_json jsonb;
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

REVOKE EXECUTE ON FUNCTION public.admin_subjects_insert_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_subjects_update_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_subjects_delete_trigger() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_subject_membership_json(public.subject_memberships) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.link_profile_to_subjects_by_email(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_link_subject_profile(uuid, uuid, text) FROM PUBLIC;

GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_subjects TO authenticated;
GRANT SELECT ON public.subjects TO authenticated;
GRANT SELECT, INSERT, UPDATE ON public.subject_memberships TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_subject_membership_json(public.subject_memberships) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_link_subject_profile(uuid, uuid, text) TO authenticated;
