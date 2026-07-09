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

test("social login uses Supabase OAuth with a site redirect", () => {
  assert.match(appSource, /supabase\.auth\.signInWithOAuth\(\{\s*provider,\s*options: \{ redirectTo: window\.location\.origin \}/);
  assert.match(appSource, /signInWithProvider\(target\.dataset\.socialProvider\.toLowerCase\(\)\)/);
  assert.doesNotMatch(appSource, /Social login is disabled/);
  assert.doesNotMatch(appSource, /data-action="social-login"/);
});

test("site imagery is local volleyball artwork", () => {
  assert.match(appSource, /const HERO_IMAGE = "\/hero-court\.svg"/);
  assert.match(appSource, /const BALL_IMAGE = "\/ball-court\.svg"/);
  assert.match(appSource, /const TRAINING_IMAGE = "\/window-panels\.svg"/);
  assert.doesNotMatch(appSource, /pexels\.com/);
});

test("private lessons are editable through member_update_reservation with a 36h window", () => {
  assert.match(appSource, /supabase\.rpc\("member_update_reservation"/);
  assert.match(appSource, /36 \* 60 \* 60 \* 1000/);
  assert.match(appSource, /data-action="edit-reservation"/);
});

test("combined Sideline x Summer League design is applied", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const html = await readFile(new URL("../index.html", import.meta.url), "utf8");
  assert.match(css, /--coral: #de1f26/);
  assert.match(css, /--azure: #2aa9e0/);
  assert.match(css, /--gold: #f5c400/);
  assert.match(css, /marquee-roll/);
  assert.match(html, /Bricolage\+Grotesque/);
  assert.match(html, /phosphor-icons/);
  assert.match(appSource, /class="marquee"/);
  assert.match(appSource, /Chantilly, VA 20152/);
});

test("brand graphics from the logo package are wired in", () => {
  assert.match(appSource, /const TRAINING_IMAGE = "\/window-panels\.svg"/);
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
  assert.match(css, /\.map-net \{ stroke: #ffffff/);
  const migration = await readFile(new URL("../supabase/migrations/20260711100000_weight_room_instructor_rental.sql", import.meta.url), "utf8");
  assert.match(migration, /instructors only/);
});

test("crest hero uses ink text on the light background (no invisible white text)", async () => {
  const css = await readFile(new URL("../src/styles.css", import.meta.url), "utf8");
  const heroWhite = css.indexOf("color: white");
  const crestInk = css.lastIndexOf(".hero.crest-hero .hero-text { color: var(--muted); }");
  assert.ok(heroWhite >= 0 && crestInk > heroWhite, "crest hero overrides must come after the photo-hero whites");
  assert.match(css, /\.hero\.crest-hero \{[^}]*color: var\(--ink\)/s);
});
