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
