import assert from "node:assert/strict";
import test from "node:test";

import {
  AdminSettingsError,
  addClosure,
  addFixedReservation,
  createDefaultAdminSettings,
  removeClosure,
  summarizeAdminSettings,
  toSchedulerOptions,
  updateOperatingHours,
  updatePricing
} from "../src/admin-settings-state.js";

const admin = { id: "admin-1", role: "admin" };
const member = { id: "user-1", role: "user" };

test("admins can update weekly operating hours", () => {
  const settings = createDefaultAdminSettings();
  const updated = updateOperatingHours(settings, 1, {
    open: "09:30",
    close: "22:30"
  }, admin);

  assert.equal(updated.operatingHours[1].open, "09:30");
  assert.equal(updated.operatingHours[1].close, "22:30");
  assert.equal(settings.operatingHours[1].open, "10:00");
});

test("non-admins cannot change settings", () => {
  const settings = createDefaultAdminSettings();

  assert.throws(() => updatePricing(settings, {
    courtHourlyRate: 100
  }, member), AdminSettingsError);
});

test("validates hours, pricing, and reservation ranges", () => {
  const settings = createDefaultAdminSettings();

  assert.throws(() => updateOperatingHours(settings, 2, {
    open: "22:00",
    close: "10:00"
  }, admin), AdminSettingsError);

  assert.throws(() => updatePricing(settings, {
    courtHourlyRate: -1
  }, admin), AdminSettingsError);

  assert.throws(() => addFixedReservation(settings, {
    title: "Bad range",
    resourceType: "court",
    courtId: "court-2",
    daysOfWeek: [1],
    startDate: "2026-08-31",
    endDate: "2026-06-01",
    startTime: "18:00",
    endTime: "20:00"
  }, admin), AdminSettingsError);
});

test("admins can add and remove closures", () => {
  let settings = createDefaultAdminSettings();
  settings = addClosure(settings, {
    id: "holiday",
    resourceType: "all",
    start: "2026-07-04T00:00:00-04:00",
    end: "2026-07-05T00:00:00-04:00",
    reason: "Independence Day"
  }, admin);

  assert.equal(settings.closures.length, 1);
  assert.equal(settings.closures[0].reason, "Independence Day");

  settings = removeClosure(settings, "holiday", admin);
  assert.equal(settings.closures.length, 0);
});

test("fixed reservations normalize days and expose scheduler-compatible settings", () => {
  const settings = addFixedReservation(createDefaultAdminSettings(), {
    id: "team-season",
    title: "Team season",
    resourceType: "court",
    courtId: "court-5",
    daysOfWeek: [4, 2, 2],
    startDate: "2026-06-01",
    endDate: "2026-08-31",
    startTime: "18:00",
    endTime: "20:00"
  }, admin);

  assert.deepEqual(settings.fixedReservations[0].daysOfWeek, [2, 4]);

  const schedulerOptions = toSchedulerOptions(settings);
  assert.equal(schedulerOptions.fixedReservations[0].courtId, "court-5");
  assert.equal(schedulerOptions.operatingHours[1].open, "10:00");
});

test("summarizes settings for the dashboard", () => {
  const settings = addClosure(createDefaultAdminSettings(), {
    id: "court-maintenance",
    resourceType: "court",
    courtId: "court-3",
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T14:00:00-04:00",
    reason: "Maintenance"
  }, admin);

  const summary = summarizeAdminSettings(settings);
  assert.equal(summary.openDays, 7);
  assert.equal(summary.closureCount, 1);
  assert.equal(summary.courtHourlyRate, 75);
});
