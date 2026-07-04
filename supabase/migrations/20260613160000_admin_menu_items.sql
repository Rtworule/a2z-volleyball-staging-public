CREATE TABLE IF NOT EXISTS public.admin_menu_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  menu_key text NOT NULL,
  name text NOT NULL,
  page_order integer NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  required_role text NOT NULL DEFAULT 'admin',
  required_permission text NOT NULL DEFAULT 'admin.full_access',
  description text,
  "Deleted" integer NOT NULL DEFAULT 0 CHECK ("Deleted" IN (0, 1)),
  "createdDT" timestamptz NOT NULL DEFAULT now(),
  "updatedDT" timestamptz NOT NULL DEFAULT now(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CHECK (menu_key ~ '^[a-z0-9-]+$'),
  CHECK (page_order > 0),
  UNIQUE (menu_key),
  UNIQUE (page_order)
);

CREATE INDEX IF NOT EXISTS admin_menu_items_active_order_idx
  ON public.admin_menu_items(page_order)
  WHERE is_active = true
    AND "Deleted" = 0;

DROP TRIGGER IF EXISTS admin_menu_items_set_updated_dt ON public.admin_menu_items;
CREATE TRIGGER admin_menu_items_set_updated_dt BEFORE UPDATE ON public.admin_menu_items
  FOR EACH ROW EXECUTE FUNCTION public.set_updated_dt();

ALTER TABLE public.admin_menu_items ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Admins read active menu items"
  ON public.admin_menu_items FOR SELECT
  USING (public.current_profile_is_admin() AND is_active = true AND "Deleted" = 0);

CREATE POLICY "Admins manage menu items"
  ON public.admin_menu_items FOR ALL
  USING (public.current_profile_is_admin())
  WITH CHECK (public.current_profile_is_admin());

INSERT INTO public.admin_menu_items (
  menu_key,
  name,
  page_order,
  required_role,
  required_permission,
  description
) VALUES
  ('payments', 'Payment Due', 10, 'admin', 'admin.payments.read', 'Review unpaid reservations and create invoices.'),
  ('invoices', 'Invoices', 20, 'admin', 'admin.invoices.read', 'Create, view, print, and email invoices.'),
  ('past-payments', 'Payments', 30, 'admin', 'admin.payments.read', 'Review paid payment records.'),
  ('users', 'Users/Clients', 40, 'admin', 'admin.users.read', 'Manage account approvals, users, clients, and client teams.'),
  ('bulk-reservations', 'Bulk Reserve', 50, 'admin', 'admin.reservations.bulk_create', 'Create recurring reservation groups.'),
  ('calendar', 'Calendar', 60, 'admin', 'admin.calendar.read', 'View and manage the operations calendar.'),
  ('reports', 'Reports', 70, 'admin', 'admin.reports.read', 'Create operational reports.'),
  ('club-seasons', 'Club Seasons', 80, 'admin', 'admin.club_seasons.read', 'Manage seasons and club season pricing.'),
  ('bulk-delete', 'Bulk Delete', 90, 'admin', 'admin.reservations.bulk_delete', 'Delete reservation sets and related reservation groups.'),
  ('settings', 'Settings', 100, 'admin', 'admin.settings.read', 'Manage facility settings, hours, closures, and email templates.')
ON CONFLICT (menu_key) DO UPDATE SET
  name = excluded.name,
  page_order = excluded.page_order,
  is_active = true,
  required_role = excluded.required_role,
  required_permission = excluded.required_permission,
  description = excluded.description,
  "Deleted" = 0,
  "updatedDT" = now(),
  updated_at = now();

CREATE OR REPLACE FUNCTION public.admin_menu_item_json(menu_item public.admin_menu_items)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', menu_item.id,
    'key', menu_item.menu_key,
    'name', menu_item.name,
    'pageOrder', menu_item.page_order,
    'isActive', menu_item.is_active,
    'requiredRole', menu_item.required_role,
    'requiredPermission', menu_item.required_permission,
    'description', menu_item.description
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

REVOKE EXECUTE ON FUNCTION public.admin_menu_item_json(public.admin_menu_items) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_menu_item_json(public.admin_menu_items) TO authenticated;
