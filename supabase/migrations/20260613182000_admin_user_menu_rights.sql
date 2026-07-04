CREATE TABLE IF NOT EXISTS public.admin_user_menu_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  profile_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  menu_item_id uuid NOT NULL REFERENCES public.admin_menu_items(id) ON DELETE CASCADE,
  has_access boolean NOT NULL DEFAULT true,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL,
  UNIQUE (profile_id, menu_item_id)
);

CREATE INDEX IF NOT EXISTS admin_user_menu_items_profile_idx
  ON public.admin_user_menu_items(profile_id)
  WHERE "Deleted" = 0;

CREATE INDEX IF NOT EXISTS admin_user_menu_items_menu_item_idx
  ON public.admin_user_menu_items(menu_item_id)
  WHERE "Deleted" = 0;

DROP TRIGGER IF EXISTS admin_user_menu_items_set_audit_fields ON public.admin_user_menu_items;
CREATE TRIGGER admin_user_menu_items_set_audit_fields
  BEFORE INSERT OR UPDATE ON public.admin_user_menu_items
  FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields();

ALTER TABLE public.admin_user_menu_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read admin menu rights"
  ON public.admin_user_menu_items FOR SELECT
  USING (public.current_profile_is_admin() AND "Deleted" = 0);

CREATE POLICY "Admins manage admin menu rights"
  ON public.admin_user_menu_items FOR ALL
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

INSERT INTO public.admin_user_menu_items (
  profile_id,
  menu_item_id,
  has_access
)
SELECT
  profile.id,
  menu_item.id,
  true
FROM public.profiles profile
CROSS JOIN public.admin_menu_items menu_item
WHERE profile.account_role = 'admin'
  AND profile.approval_status = 'approved'
  AND profile."Deleted" = 0
  AND menu_item.is_active = true
  AND menu_item."Deleted" = 0
ON CONFLICT (profile_id, menu_item_id) DO UPDATE SET
  has_access = true,
  "Deleted" = 0,
  updated_at = now();

CREATE OR REPLACE FUNCTION public.admin_menu_right_json(right_row public.admin_user_menu_items, menu_item public.admin_menu_items)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'profileId', right_row.profile_id,
    'menuItemId', right_row.menu_item_id,
    'menuKey', menu_item.menu_key,
    'hasAccess', right_row.has_access
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_profile_json(profile public.profiles)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', profile.id,
    'username', profile.username,
    'email', profile.email,
    'name', profile.display_name,
    'role', profile.account_role,
    'approvalStatus', profile.approval_status,
    'approved', profile.approval_status = 'approved',
    'authenticated', true
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_update_profile(p_profile_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  profile public.profiles%ROWTYPE;
  next_role text := coalesce(nullif(payload->>'accountRole', ''), 'user');
BEGIN
  IF next_role NOT IN ('user', 'admin') THEN
    RAISE EXCEPTION 'Account role must be user or admin' USING ERRCODE = '22023';
  END IF;

  UPDATE public.profiles
  SET display_name = coalesce(nullif(payload->>'displayName', ''), display_name),
      account_role = next_role,
      updated_by = actor_id,
      updated_at = now()
  WHERE id = p_profile_id
    AND "Deleted" = 0
  RETURNING * INTO profile;

  IF profile.id IS NULL THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = '22023';
  END IF;

  IF next_role = 'admin' THEN
    INSERT INTO public.admin_user_menu_items (
      profile_id,
      menu_item_id,
      has_access,
      created_by,
      updated_by
    )
    SELECT
      p_profile_id,
      menu_item.id,
      true,
      actor_id,
      actor_id
    FROM public.admin_menu_items menu_item
    WHERE menu_item.is_active = true
      AND menu_item."Deleted" = 0
    ON CONFLICT (profile_id, menu_item_id) DO NOTHING;
  END IF;

  RETURN public.admin_profile_json(profile);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_profile_menu_rights(p_profile_id uuid, p_menu_keys text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  profile public.profiles%ROWTYPE;
  rights_json jsonb;
BEGIN
  SELECT *
  INTO profile
  FROM public.profiles
  WHERE id = p_profile_id
    AND "Deleted" = 0;

  IF profile.id IS NULL THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = '22023';
  END IF;

  IF profile.account_role <> 'admin' THEN
    RAISE EXCEPTION 'Admin rights can only be assigned to admin users' USING ERRCODE = '22023';
  END IF;

  WITH active_menu AS (
    SELECT id, menu_key
    FROM public.admin_menu_items
    WHERE is_active = true
      AND "Deleted" = 0
  )
  INSERT INTO public.admin_user_menu_items (
    profile_id,
    menu_item_id,
    has_access,
    created_by,
    updated_by
  )
  SELECT
    p_profile_id,
    active_menu.id,
    active_menu.menu_key = ANY(coalesce(p_menu_keys, ARRAY[]::text[])),
    actor_id,
    actor_id
  FROM active_menu
  ON CONFLICT (profile_id, menu_item_id) DO UPDATE SET
    has_access = excluded.has_access,
    "Deleted" = 0,
    updated_by = actor_id,
    updated_at = now();

  SELECT coalesce(jsonb_agg(public.admin_menu_right_json(right_row, menu_item) ORDER BY menu_item.page_order, menu_item.name), '[]'::jsonb)
  INTO rights_json
  FROM public.admin_user_menu_items right_row
  JOIN public.admin_menu_items menu_item
    ON menu_item.id = right_row.menu_item_id
  WHERE right_row.profile_id = p_profile_id
    AND right_row."Deleted" = 0
    AND menu_item.is_active = true
    AND menu_item."Deleted" = 0;

  RETURN rights_json;
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
  all_menu_items_json jsonb;
  menu_items_json jsonb;
  menu_rights_json jsonb;
BEGIN
  SELECT public.admin_facility_settings_json() INTO settings_json;

  SELECT coalesce(jsonb_agg(public.admin_profile_json(profile) ORDER BY profile.approval_status, profile.created_at), '[]'::jsonb)
  INTO users_json
  FROM public.profiles profile
  WHERE profile."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_profile_json(profile) ORDER BY profile.created_at), '[]'::jsonb)
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

  SELECT coalesce(jsonb_agg(public.admin_subject_membership_json(membership) ORDER BY membership.created_at), '[]'::jsonb)
  INTO subject_memberships_json
  FROM public.subject_memberships membership
  WHERE membership."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_season_json(season) ORDER BY season.start_year DESC), '[]'::jsonb)
  INTO seasons_json
  FROM public.seasons season
  WHERE season."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_team_season_price_json(price) ORDER BY price.season_year DESC, price.season, price.created_at), '[]'::jsonb)
  INTO season_prices_json
  FROM public.team_season_prices price
  WHERE price."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_bulk_operation_json(operation) ORDER BY operation.created_at), '[]'::jsonb)
  INTO operations_json
  FROM public.admin_bulk_operations operation
  WHERE operation."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_invoice_json(invoice) ORDER BY invoice.created_at DESC), '[]'::jsonb)
  INTO invoices_json
  FROM public.invoices invoice
  WHERE invoice."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_payment_json(payment) ORDER BY payment.created_at DESC), '[]'::jsonb)
  INTO payments_json
  FROM public.payments payment
  WHERE payment."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_menu_item_json(menu_item) ORDER BY menu_item.page_order, menu_item.name), '[]'::jsonb)
  INTO all_menu_items_json
  FROM public.admin_menu_items menu_item
  WHERE menu_item.is_active = true
    AND menu_item."Deleted" = 0
    AND menu_item.required_role = 'admin';

  SELECT coalesce(jsonb_agg(public.admin_menu_item_json(menu_item) ORDER BY menu_item.page_order, menu_item.name), '[]'::jsonb)
  INTO menu_items_json
  FROM public.admin_menu_items menu_item
  WHERE menu_item.is_active = true
    AND menu_item."Deleted" = 0
    AND menu_item.required_role = 'admin'
    AND (
      NOT EXISTS (
        SELECT 1
        FROM public.admin_user_menu_items right_row
        WHERE right_row.profile_id = actor_id
          AND right_row."Deleted" = 0
      )
      OR EXISTS (
        SELECT 1
        FROM public.admin_user_menu_items right_row
        WHERE right_row.profile_id = actor_id
          AND right_row.menu_item_id = menu_item.id
          AND right_row.has_access = true
          AND right_row."Deleted" = 0
      )
    );

  SELECT coalesce(jsonb_agg(public.admin_menu_right_json(right_row, menu_item) ORDER BY profile.display_name, menu_item.page_order, menu_item.name), '[]'::jsonb)
  INTO menu_rights_json
  FROM public.admin_user_menu_items right_row
  JOIN public.admin_menu_items menu_item
    ON menu_item.id = right_row.menu_item_id
  JOIN public.profiles profile
    ON profile.id = right_row.profile_id
  WHERE right_row."Deleted" = 0
    AND profile."Deleted" = 0
    AND menu_item.is_active = true
    AND menu_item."Deleted" = 0;

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
    'adminAllMenuItems', all_menu_items_json,
    'adminMenuItems', menu_items_json,
    'adminMenuRights', menu_rights_json,
    'actorId', actor_id
  );
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_menu_right_json(public.admin_user_menu_items, public.admin_menu_items) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_profile_menu_rights(uuid, text[]) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_menu_right_json(public.admin_user_menu_items, public.admin_menu_items) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_profile_menu_rights(uuid, text[]) TO authenticated;
