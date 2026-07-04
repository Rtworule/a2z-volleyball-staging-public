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
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS "createdDT" timestamptz NOT NULL DEFAULT now()', audit_table);
    EXECUTE format('ALTER TABLE public.%I ADD COLUMN IF NOT EXISTS "updatedDT" timestamptz NOT NULL DEFAULT now()', audit_table);
  END LOOP;
END $$;
