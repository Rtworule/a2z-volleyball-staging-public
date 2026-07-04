import assert from "node:assert/strict";
import { readdirSync, readFileSync } from "node:fs";
import test from "node:test";

const migrationDir = new URL("../supabase/migrations/", import.meta.url);
const migration = readdirSync(migrationDir)
  .filter((file) => file.endsWith(".sql"))
  .sort()
  .map((file) => readFileSync(new URL(file, migrationDir), "utf8"))
  .join("\n");
const clientEnableMigration = readFileSync(new URL("../supabase/migrations/20260613194000_enable_clients_and_fix_subject_type.sql", import.meta.url), "utf8");
const appSource = readFileSync(new URL("../src/app.js", import.meta.url), "utf8");

const requiredRpcFunctions = [
  "admin_get_dashboard",
  "admin_facility_settings_json",
  "admin_create_subject",
  "admin_update_subject",
  "admin_enable_subject",
  "admin_link_subject_profile",
  "admin_create_season",
  "admin_update_season",
  "admin_delete_season",
  "admin_create_team_season_price",
  "admin_update_team_season_price",
  "admin_delete_team_season_price",
  "admin_create_invoice",
  "admin_delete_bulk_operation",
  "system_monthly_payment_due_job",
  "system_reservation_reminder_job",
  "admin_mark_reservation_paid",
  "admin_approve_profile",
  "admin_reject_profile",
  "admin_update_profile",
  "admin_set_profile_menu_rights",
  "admin_update_facility_config",
  "admin_update_operating_hours",
  "admin_create_closure",
  "admin_delete_closure",
  "admin_create_single_reservation",
  "admin_preview_bulk_reservations",
  "admin_save_bulk_reservations",
  "admin_apply_bulk_reservations",
  "admin_preview_delete_reservations",
  "admin_apply_delete_reservations",
  "admin_calculate_monthly_payment_due",
  "admin_undo_bulk_operation",
  "admin_mark_payment_paid",
  "admin_delete_reservation"
];

test("admin production mutations are exposed through checked RPC functions", () => {
  for (const functionName of requiredRpcFunctions) {
    assert.match(migration, new RegExp(`CREATE OR REPLACE FUNCTION public\\.${functionName}\\b`));
  }

  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.admin_require_approved\(\)/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.admin_facility_settings_json\(\)/);
  assert.match(migration, /SELECT public\.admin_facility_settings_json\(\)/);
  assert.match(migration, /SECURITY DEFINER/g);
  assert.match(migration, /REVOKE EXECUTE ON FUNCTION public\.admin_apply_bulk_reservations\(jsonb\) FROM PUBLIC;/);
  assert.match(migration, /GRANT EXECUTE ON FUNCTION public\.admin_apply_bulk_reservations\(jsonb\) TO authenticated;/);
});

test("admin RPCs enforce soft-delete and paid-state persistence in SQL", () => {
  assert.match(migration, /WHERE reservation\."Deleted" = 0/);
  assert.match(migration, /SET "Deleted" = 1/);
  assert.match(migration, /SET "Deleted" = 0/);
  assert.match(migration, /target\.payment_status <> 'paid'/);
  assert.match(migration, /'skippedPaid'/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS public\.team_season_prices/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS public\.seasons/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS season_id uuid/);
  assert.match(migration, /'seasons', seasons_json/);
  assert.match(migration, /'seasonDisplayName'/);
  assert.match(migration, /UPDATE public\.team_season_prices/);
  assert.match(migration, /SET "Deleted" = 1,\s+updated_at = now\(\)/);
  assert.match(migration, /hourly_rate = next_hourly_rate/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS season_price_id uuid/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS amount numeric/);
  assert.match(migration, /'teamSeasonPrices'/);
  assert.match(migration, /reservation\.amount/);
  assert.match(migration, /DROP COLUMN IF EXISTS paid/);
  assert.match(migration, /payment_status = CASE WHEN p_paid THEN 'paid' ELSE 'due' END/);
  assert.match(migration, /courtCountNeeded/);
  assert.match(migration, /courtIds/);
  assert.match(migration, /jsonb_array_elements_text\(court_ids\)/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS public\.reservation_groups/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS reservation_group_id uuid/);
  assert.match(migration, /FOREIGN KEY \(reservation_group_id\) REFERENCES public\.reservation_groups\(id\) ON DELETE SET NULL/);
  assert.match(migration, /'reservationGroupId', reservation\.reservation_group_id/);
  assert.match(migration, /INSERT INTO public\.reservation_groups/);
  assert.match(migration, /reservation_group\.id/);
  assert.match(migration, /deletedReservationGroups/);
  assert.match(migration, /NOT EXISTS \(\s+SELECT 1\s+FROM public\.reservations reservation\s+WHERE reservation\.reservation_group_id = reservation_group\.id[\s\S]+reservation\."Deleted" = 0/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.admin_undo_bulk_operation\(p_operation_id uuid\)[\s\S]+reservation\.payment_status = 'paid'/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.admin_undo_bulk_operation\(p_operation_id uuid\)[\s\S]+reservation\.payment_status <> 'paid'/);
  assert.match(migration, /active_children_count = 0/);
  assert.match(migration, /subject_teams_unique_active_name_idx[\s\S]+ON public\.subject_teams\(subject_id, lower\(name\)\)/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS public\.invoices/);
  assert.match(migration, /CREATE TABLE public\.subject_memberships/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS public\.admin_menu_items/);
  assert.match(migration, /menu_key text NOT NULL/);
  assert.match(migration, /required_permission text NOT NULL DEFAULT 'admin\.full_access'/);
  assert.match(migration, /\('clients', 'Clients', 40/);
  assert.match(migration, /\('users', 'Users', 95/);
  assert.match(migration, /CREATE TABLE IF NOT EXISTS public\.admin_user_menu_items/);
  assert.match(migration, /profile_id uuid NOT NULL REFERENCES public\.profiles\(id\) ON DELETE CASCADE/);
  assert.match(migration, /menu_item_id uuid NOT NULL REFERENCES public\.admin_menu_items\(id\) ON DELETE CASCADE/);
  assert.match(migration, /has_access boolean NOT NULL DEFAULT true/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.admin_set_profile_menu_rights\(p_profile_id uuid, p_menu_keys text\[\]\)/);
  assert.match(migration, /'adminAllMenuItems', all_menu_items_json/);
  assert.match(migration, /'adminMenuRights', menu_rights_json/);
  assert.match(migration, /right_row\.profile_id = actor_id[\s\S]+right_row\.has_access = true/);
  assert.match(migration, /'adminMenuItems', menu_items_json/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.admin_menu_item_json\(menu_item public\.admin_menu_items\)/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.set_audit_fields\(\)/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS created_by uuid REFERENCES public\.profiles\(id\) ON DELETE SET NULL/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS updated_by uuid REFERENCES public\.profiles\(id\) ON DELETE SET NULL/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS created_at timestamptz/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS updated_at timestamptz/);
  assert.match(migration, /DROP COLUMN IF EXISTS "createdDT"/);
  assert.match(migration, /DROP COLUMN IF EXISTS "updatedDT"/);
  assert.match(migration, /'created_by', actor_id/);
  assert.match(migration, /'updated_by', actor_id/);
  assert.match(migration, /BEFORE INSERT OR UPDATE[\s\S]+EXECUTE FUNCTION public\.set_audit_fields\(\)/);
  assert.match(migration, /ALTER TABLE public\.admin_subjects RENAME TO subjects/);
  assert.match(migration, /CREATE OR REPLACE VIEW public\.admin_subjects/);
  assert.match(migration, /'subjectMemberships', subject_memberships_json/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS admin_email text/);
  assert.match(migration, /ADD COLUMN IF NOT EXISTS email_templates jsonb/);
  assert.match(migration, /'invoices', invoices_json/);
  assert.match(migration, /status IN \('previewed', 'scheduled'\)/);
});

test("admin UI and database access require approved admin profiles", () => {
  assert.match(appSource, /function isAdminSession\(\) \{\s+return Boolean\(state\.user\?\.authenticated && state\.user\.approved && state\.user\.role === "admin"\);\s+\}/);
  assert.match(appSource, /if \(isAdminSession\(\)\) \{\s+await loadAdminDashboard\(\);\s+\}/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.current_profile_is_admin\(\)[\s\S]+account_role = 'admin'[\s\S]+approval_status = 'approved'/);
  assert.match(migration, /CREATE OR REPLACE FUNCTION public\.admin_require_approved\(\)[\s\S]+approval_status = 'approved'/);
});

test("live admin UI does not send demo ids to Supabase RPCs", () => {
  assert.match(appSource, /const liveUsers = data\.users \?\? data\.allUsers \?\? \[\];/);
  assert.match(appSource, /function clearLiveAdminData\(\)/);
  assert.match(appSource, /if \(shouldUseLiveAuth\(\)\) \{\s+clearLiveAdminData\(\);\s+await restoreSupabaseSession\(\);/);
  assert.match(appSource, /const source = shouldUseLiveAuth\(\) \? state\.allUsers : state\.allUsers\.length \? state\.allUsers : demoUsers;/);
  assert.match(appSource, /function isUuid\(value\)/);
  assert.match(appSource, /function resolveClientTypeId\(clientTypeId\)/);
  assert.match(appSource, /\{ key: "clients", name: "Clients", pageOrder: 40, isActive: true \}/);
  assert.match(appSource, /\{ key: "users", name: "Users", pageOrder: 95, isActive: true \}/);
  assert.match(appSource, /activeTab === "clients" \? renderAdminClientsTab\(\) : ""/);
  assert.match(appSource, /activeTab === "users" \? renderAdminUsersTab\(\) : ""/);
  assert.match(appSource, /data-action="enable-subject"/);
  assert.match(appSource, /function enableSubject\(subjectId\)/);
  assert.match(appSource, /function isCurrentAdminUser\(userId\)/);
  assert.match(appSource, /status === "approved" && !isCurrentUser/);
  assert.match(appSource, /status === "rejected" \? "Enable" : "Approve"/);
  assert.match(appSource, /data-action="edit-admin-rights"/);
  assert.match(appSource, /function renderAdminRightsPanel\(user\)/);
  assert.match(appSource, /data-admin-right/);
  assert.match(appSource, /data-admin-rights-all/);
  assert.match(appSource, /function updateAdminRightsAllControl\(control\)/);
  assert.match(appSource, /admin_set_profile_menu_rights/);
  assert.match(appSource, /function activeAdminMenuItems\(\)/);
  assert.match(appSource, /data\.adminMenuItems/);
  assert.match(appSource, /const clientTypeId = resolveClientTypeId\(state\.adminSubjectForm\.clientTypeId\);/);
  assert.match(appSource, /Client types are not loaded from Supabase yet/);
  assert.match(appSource, /This account is not loaded from Supabase yet/);
  assert.match(appSource, /This client is not loaded from Supabase yet/);
  assert.match(appSource, /This payment includes reservations that are not loaded from Supabase yet/);
});

test("bulk reservation UI removes drafts and hides stale deleted children", () => {
  assert.doesNotMatch(appSource, /Save Draft/);
  assert.doesNotMatch(appSource, /data-action="bulk-save"/);
  assert.doesNotMatch(appSource, /bulk-draft-/);
  assert.match(appSource, /function subjectTeamOptions\(subjectId, selectedId\)[\s\S]+escapeHtml\(team\.shortName \?\? team\.name\)/);
  const bulkDeleteRowSource = appSource.match(/function renderBulkDeletePreviewRow\(booking\)[\s\S]+?function renderAdminSettings/)?.[0] ?? "";
  assert.match(bulkDeleteRowSource, /bookingDisplayName\(booking\)/);
  assert.doesNotMatch(bulkDeleteRowSource, /isBookingPaid\(booking\) \? "paid" : "due"/);
  assert.match(appSource, /function activeBulkReservationOperations\(\)[\s\S]+operation\.status === "applied"[\s\S]+activeBulkOperationBookings\(operation\)\.length > 0/);
  assert.match(appSource, /const items = activeBulkOperationBookings\(operation\)\.map\(bulkCalendarItemFromBooking\)/);
});

test("client management supports enabling clients and compatible subject types", () => {
  assert.match(clientEnableMigration, /CREATE OR REPLACE FUNCTION public\.admin_enable_subject\(p_subject_id uuid\)/);
  assert.match(clientEnableMigration, /disabled_at = NULL/);
  assert.match(clientEnableMigration, /disabled_reason = NULL/);
  assert.match(clientEnableMigration, /subject_type = CASE WHEN coalesce\(client_type\.have_teams, false\) THEN ''team'' ELSE ''coach'' END/);
  assert.match(clientEnableMigration, /CASE WHEN coalesce\(client_type\.have_teams, false\) THEN ''team'' ELSE ''coach'' END,/);
  assert.match(appSource, /state\.editingSubjectId \? "" : renderDisabledClientsSection\(\)/);
  assert.match(appSource, /data-action="enable-subject"/);
  assert.match(appSource, /function mergeSubjectTeams\(subjects, teams\)/);
  assert.match(appSource, /data\.subjectTeams \?\? data\.adminSubjectTeams/);
  assert.match(appSource, /data-form="create-subject-team"/);
  assert.match(appSource, /function currentTeamFormFromForm\(form\)/);
  assert.match(appSource, /data-action="create-subject-team"/);
  assert.match(appSource, /createSubjectTeam\(target\.closest\('\[data-form="create-subject-team"\]'\)\)/);
  assert.match(appSource, /teamCreateInFlight/);
  assert.match(appSource, /state\.teamForm = defaultTeamForm\(\)/);
  assert.match(appSource, /String\(form\.coachName \?\? ""\)\.trim\(\)/);
  assert.doesNotMatch(appSource, /status-pill is-busy">disabled/);
  assert.doesNotMatch(appSource, /data-subject-team="coach/);
  assert.doesNotMatch(appSource, /data-edit-subject-team="coach/);
});
