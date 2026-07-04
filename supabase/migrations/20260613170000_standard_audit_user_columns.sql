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
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL', audit_table);
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS "createdDT" timestamptz NOT NULL DEFAULT now()', audit_table);
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES public.profiles(id) ON DELETE SET NULL', audit_table);
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS "updatedDT" timestamptz NOT NULL DEFAULT now()', audit_table);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION public.set_audit_fields()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  actor_id uuid := auth.uid();
  audit_patch jsonb := jsonb_build_object(
    'updatedDT', now(),
    'updated_at', now()
  );
BEGIN
  IF actor_id IS NOT NULL THEN
    audit_patch := audit_patch || jsonb_build_object('updated_by', actor_id);
  END IF;

  IF TG_OP = 'INSERT' THEN
    audit_patch := audit_patch || jsonb_build_object(
      'createdDT', now(),
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
    EXECUTE format('DROP TRIGGER IF EXISTS %I ON public.%I', audit_table || '_set_audit_fields', audit_table);
    EXECUTE format(
      'CREATE TRIGGER %I BEFORE INSERT OR UPDATE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.set_audit_fields()',
      audit_table || '_set_audit_fields',
      audit_table
    );
  END LOOP;
END $$;

CREATE INDEX IF NOT EXISTS admin_bulk_operation_items_created_by_idx ON public.admin_bulk_operation_items(created_by);
CREATE INDEX IF NOT EXISTS admin_bulk_operation_items_updated_by_idx ON public.admin_bulk_operation_items(updated_by);
CREATE INDEX IF NOT EXISTS admin_bulk_operations_updated_by_idx ON public.admin_bulk_operations(updated_by);
CREATE INDEX IF NOT EXISTS admin_menu_items_created_by_idx ON public.admin_menu_items(created_by);
CREATE INDEX IF NOT EXISTS admin_menu_items_updated_by_idx ON public.admin_menu_items(updated_by);
CREATE INDEX IF NOT EXISTS audit_events_created_by_idx ON public.audit_events(created_by);
CREATE INDEX IF NOT EXISTS audit_events_updated_by_idx ON public.audit_events(updated_by);
CREATE INDEX IF NOT EXISTS auth_provider_options_created_by_idx ON public.auth_provider_options(created_by);
CREATE INDEX IF NOT EXISTS auth_provider_options_updated_by_idx ON public.auth_provider_options(updated_by);
CREATE INDEX IF NOT EXISTS client_types_created_by_idx ON public.client_types(created_by);
CREATE INDEX IF NOT EXISTS client_types_updated_by_idx ON public.client_types(updated_by);
CREATE INDEX IF NOT EXISTS closures_created_by_idx ON public.closures(created_by);
CREATE INDEX IF NOT EXISTS closures_updated_by_idx ON public.closures(updated_by);
CREATE INDEX IF NOT EXISTS facility_config_created_by_idx ON public.facility_config(created_by);
CREATE INDEX IF NOT EXISTS facility_config_updated_by_idx ON public.facility_config(updated_by);
CREATE INDEX IF NOT EXISTS fixed_reservations_created_by_idx ON public.fixed_reservations(created_by);
CREATE INDEX IF NOT EXISTS fixed_reservations_updated_by_idx ON public.fixed_reservations(updated_by);
CREATE INDEX IF NOT EXISTS invoices_updated_by_idx ON public.invoices(updated_by);
CREATE INDEX IF NOT EXISTS operating_hours_created_by_idx ON public.operating_hours(created_by);
CREATE INDEX IF NOT EXISTS operating_hours_updated_by_idx ON public.operating_hours(updated_by);
CREATE INDEX IF NOT EXISTS payments_updated_by_idx ON public.payments(updated_by);
CREATE INDEX IF NOT EXISTS profiles_created_by_idx ON public.profiles(created_by);
CREATE INDEX IF NOT EXISTS profiles_updated_by_idx ON public.profiles(updated_by);
CREATE INDEX IF NOT EXISTS reservation_groups_updated_by_idx ON public.reservation_groups(updated_by);
CREATE INDEX IF NOT EXISTS reservations_updated_by_idx ON public.reservations(updated_by);
CREATE INDEX IF NOT EXISTS resources_created_by_idx ON public.resources(created_by);
CREATE INDEX IF NOT EXISTS resources_updated_by_idx ON public.resources(updated_by);
CREATE INDEX IF NOT EXISTS seasons_created_by_idx ON public.seasons(created_by);
CREATE INDEX IF NOT EXISTS seasons_updated_by_idx ON public.seasons(updated_by);
CREATE INDEX IF NOT EXISTS subject_memberships_created_by_idx ON public.subject_memberships(created_by);
CREATE INDEX IF NOT EXISTS subject_memberships_updated_by_idx ON public.subject_memberships(updated_by);
CREATE INDEX IF NOT EXISTS subject_teams_created_by_idx ON public.subject_teams(created_by);
CREATE INDEX IF NOT EXISTS subject_teams_updated_by_idx ON public.subject_teams(updated_by);
CREATE INDEX IF NOT EXISTS subjects_updated_by_idx ON public.subjects(updated_by);
CREATE INDEX IF NOT EXISTS team_season_prices_updated_by_idx ON public.team_season_prices(updated_by);

REVOKE EXECUTE ON FUNCTION public.set_audit_fields() FROM PUBLIC;
