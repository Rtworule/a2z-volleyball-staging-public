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
  assert.match(appSource, /\["1-2", "3", "4", "5\+"\]/);
});

test("facility map places court 1 left and courts 2-9 clockwise from bottom-left", () => {
  assert.match(appSource, /const topRow = \[3, 4, 5, 6\];/);
  assert.match(appSource, /const bottomRow = \[2, 9, 8, 7\];/);
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
  assert.match(appSource, /const TRAINING_IMAGE = "\/training\.svg"/);
  assert.doesNotMatch(appSource, /pexels\.com/);
});

test("private lessons are editable through member_update_reservation with a 36h window", () => {
  assert.match(appSource, /supabase\.rpc\("member_update_reservation"/);
  assert.match(appSource, /36 \* 60 \* 60 \* 1000/);
  assert.match(appSource, /data-action="edit-reservation"/);
});
