import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

const appSource = await readFile(new URL("../src/app.js", import.meta.url), "utf8");

test("live member booking goes through member_create_reservation RPC", () => {
  assert.match(appSource, /supabase\.rpc\("member_create_reservation", \{ payload \}\)/);
  assert.match(appSource, /shouldUseLiveAuth\(\) && isApprovedMember\(\)/);
});

test("member portal loads availability through member_get_portal RPC", () => {
  assert.match(appSource, /supabase\.rpc\("member_get_portal"/);
});

test("member cancellations go through member_cancel_reservation RPC", () => {
  assert.match(appSource, /supabase\.rpc\("member_cancel_reservation", \{ p_reservation_id: reservationId \}\)/);
});

test("private lesson bracket options match the database check constraint", () => {
  for (const value of ["1-2", "3", "4", "5+", "camps"]) {
    assert.ok(appSource.includes(`value: "${value}"`), `missing bracket ${value}`);
  }
});

test("facility map matches Exhibit C: two columns of four beside vertical court 1", () => {
  assert.match(appSource, /const leftColumn = \[2, 3, 4, 5\];/);
  assert.match(appSource, /const rightColumn = \[6, 7, 8, 9\];/);
});

test("public login screen uses a neutral email placeholder", () => {
  assert.match(appSource, /shouldUseLiveAuth\(\) \? "you@example\.com" : "member or member@a2z\.local"/);
});

test("forgot-password flow uses Supabase Auth recovery", () => {
  assert.match(appSource, /supabase\.auth\.resetPasswordForEmail/);
  assert.match(appSource, /PASSWORD_RECOVERY/);
  assert.match(appSource, /supabase\.auth\.updateUser\(\{ password \}\)/);
});

test("schedule view renders a half-hour day grid for members", () => {
  assert.match(appSource, /renderDayGrid/);
  assert.match(appSource, /data-grid-time/);
});

test("private lesson estimates use bracket prices from the portal", () => {
  assert.match(appSource, /state\.bracketPrices\.find\(\(price\) => price\.bracket === state\.lessonBracket\)/);
});

test("public home data comes from the column-safe facility info RPC", () => {
  assert.match(appSource, /supabase\.rpc\("public_get_facility_info"\)/);
  assert.doesNotMatch(appSource, /from\("facility_config"\)/);
});

test("signup has no parent mentions and redirects email confirmation to the site", () => {
  assert.doesNotMatch(appSource, /parent or coach/i);
  assert.match(appSource, /placeholder="coach-name or club-name"/);
  assert.match(appSource, /emailRedirectTo: window\.location\.origin/);
});

test("Google login uses Supabase OAuth with a site redirect", () => {
  assert.match(appSource, /supabase\.auth\.signInWithOAuth\(\{\s*provider,\s*options: \{ redirectTo: window\.location\.origin \}/);
  assert.match(appSource, /signInWithProvider\(target\.dataset\.socialProvider\.toLowerCase\(\)\)/);
  assert.match(appSource, /provider !== "google"/);
  assert.match(appSource, /Google account creation option/);
  assert.doesNotMatch(appSource, /socialButton\("Facebook"\)/);
  assert.doesNotMatch(appSource, /socialButton\("Apple"\)/);
  assert.doesNotMatch(appSource, /Social login is disabled/);
  assert.doesNotMatch(appSource, /data-action="social-login"/);
});

test("program CTAs distinguish signed-out, pending, and approved members", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(appSource, /const label = isApprovedMember\(\) \? action : pendingApproval \? "Waiting for approval" : "Log in"/);
  assert.match(appSource, /disabled aria-disabled="true"/);
  assert.match(appSource, /function isPendingMember\(\)/);
  assert.match(css, /\.program-card button:disabled/);
});

test("site imagery is local volleyball artwork", () => {
  assert.match(appSource, /const HERO_IMAGE = "\/volleyball-hero-junior-girls-v5\.jpg"/);
  assert.match(appSource, /const TRAINING_IMAGE = "\/volleyball-hero-v2\.jpg"/);
  assert.doesNotMatch(appSource, /pexels\.com/);
});

test("private lessons are editable through member_update_reservation with a 36h window", () => {
  assert.match(appSource, /supabase\.rpc\("member_update_reservation"/);
  assert.match(appSource, /36 \* 60 \* 60 \* 1000/);
  assert.match(appSource, /data-action="edit-reservation"/);
});

test("Hypothesis 4 homepage is applied with the reference headline font", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  assert.match(css, /Hypothesis 4: Lift the Scrim/);
  assert.match(css, /\.hypothesis-four-hero/);
  assert.match(css, /\.fact-band/);
  assert.match(css, /\.booking-path/);
  assert.match(html, /Bricolage\+Grotesque/);
  assert.match(html, /phosphor-icons/);
  assert.match(appSource, /class="hero public-hero hypothesis-four-hero"/);
  assert.match(appSource, /<h1>A to Z Volleyball Center<\/h1>/);
  assert.doesNotMatch(css, /Design 8/);
  assert.doesNotMatch(appSource, /class="finder"/);
});

test("card-on-file and cancellation tiers are wired in the UI", () => {
  assert.match(appSource, /privateBookingBlocked/);
  assert.match(appSource, /credit card on file is required for private lessons/i);
  assert.match(appSource, /cancellationFeePercentFor/);
  assert.match(appSource, /50% between 36 and 24 hours/);
});

test("Camps & Clinics is a bookable players-attending option with its own rate", async () => {
  assert.match(appSource, /Camps & Clinics/);
  assert.match(appSource, /value: "camps"/);
  const migration = await readFile(new URL("../supabase/migrations/20260710100000_camps_clinics_bracket.sql", import.meta.url), "utf8");
  assert.match(migration, /'camps'/);
});

test("weight room is instructor space & equipment rental with white court lines", async () => {
  assert.match(appSource, /space & equipment rental/i);
  assert.match(appSource, /type === "private" \? `<option value="trainer"/);
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  assert.match(css, /\.map-net \{\s*stroke: #ffffff/);
  const migration = await readFile(new URL("../supabase/migrations/20260711100000_weight_room_instructor_rental.sql", import.meta.url), "utf8");
  assert.match(migration, /instructors only/);
});

test("staging hosts render the application while production stays coming soon", async () => {
  const mainSource = await readFile(new URL("../src/main.js", import.meta.url), "utf8");
  assert.match(mainSource, /PRODUCTION_HOSTS\.has\(currentHost\)/);
  assert.doesNotMatch(mainSource, /!isLocalHost\s*\|\|/);
});

test("Cloudflare staging branch builds with staging environment variables", async () => {
  const packageSource = JSON.parse(await readFile(new URL("../package.json", import.meta.url), "utf8"));
  const buildSource = await readFile(new URL("../scripts/build-cloudflare.mjs", import.meta.url), "utf8");

  assert.equal(packageSource.scripts.build, "node scripts/build-cloudflare.mjs");
  assert.match(buildSource, /branch === "staging" \? "staging" : "production"/);
  assert.match(buildSource, /await build\(\{ mode \}\)/);
});

test("personal court rentals: sport choice, 4h cap, privacy copy, personal RPC", () => {
  assert.match(appSource, /member_create_personal_reservation/);
  assert.match(appSource, /data-control="rentalSport"/);
  assert.match(appSource, /marked "You"/);
  assert.doesNotMatch(appSource, /not linked to a club or coach profile yet/);
});

test("weight room has its own page linked from Reserve", () => {
  assert.match(appSource, /renderWeightRoomView/);
  assert.match(appSource, /data-view="weight-room"/);
  assert.match(appSource, /of \$\{capacity\} open/);
});

test("my bookings filters courts vs weight room", () => {
  assert.match(appSource, /data-action="bookings-filter"/);
  assert.match(appSource, /\["trainer", "Weight room"\]/);
});

test("schedule menu is merged into Reserve", () => {
  assert.doesNotMatch(appSource, /navButton\("schedule", "Schedule"\)/);
});

test("facility map wraps long room labels", () => {
  assert.match(appSource, /wrapLabel/);
  assert.match(appSource, /tspan/);
});

test("onboarding sections hidden for approved members", () => {
  assert.match(appSource, /isApprovedMember\(\) \? "" : `<section class="home-section booking-path">/);
  assert.match(appSource, /isApprovedMember\(\) \? "" : `<section class="home-section facility-home-section">/);
});

test("admin manages club coaches and pickleball rate; tabs refresh data", () => {
  assert.match(appSource, /admin_add_club_coach/);
  assert.match(appSource, /admin_remove_club_coach/);
  assert.match(appSource, /admin_search_profiles/);
  assert.match(appSource, /data-config="pickleballHourlyRate"/);
  assert.match(appSource, /loadAdminDashboard\(\)\.then\(\(\) => render\(\)\)/);
});
