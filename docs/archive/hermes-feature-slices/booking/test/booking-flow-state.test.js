import assert from "node:assert/strict";
import test from "node:test";

import { SchedulingService } from "../src/scheduler.js";
import {
  approvedMember,
  buildHourlySlots,
  accountStatusLabel,
  canViewerReserve,
  getSlotAvailability,
  guestUser,
  pendingMember,
  submitReservation
} from "../src/booking-flow-state.js";

test("builds selectable one to four hour slots inside operating hours", () => {
  assert.equal(buildHourlySlots("2026-06-01", 1).length, 13);
  assert.equal(buildHourlySlots("2026-06-01", 4).length, 10);
  assert.throws(() => buildHourlySlots("2026-06-01", 5), /1 to 4 hours/);
});

test("uses weekend and weekday operating hours from the selected date", () => {
  assert.equal(buildHourlySlots("2026-05-31", 1)[0].startTime, "08:00");
  assert.equal(buildHourlySlots("2026-06-01", 1)[0].startTime, "10:00");
});

test("builds slots in New York local time across standard and daylight offsets", () => {
  assert.equal(buildHourlySlots("2026-06-01", 1)[0].start, "2026-06-01T14:00:00.000Z");
  assert.equal(buildHourlySlots("2026-12-01", 1)[0].start, "2026-12-01T15:00:00.000Z");
});

test("blocks unauthenticated reservation requests", () => {
  const scheduler = new SchedulingService();
  const [slot] = buildHourlySlots("2026-06-01", 1);

  const result = submitReservation(scheduler, slot, {
    viewer: guestUser,
    durationHours: 1,
    resourceType: "court",
    courtId: ""
  });

  assert.equal(result.ok, false);
  assert.match(result.message, /Sign in/);
});

test("blocks missing viewer reservation requests", () => {
  const scheduler = new SchedulingService();
  const [slot] = buildHourlySlots("2026-06-01", 1);

  const result = submitReservation(scheduler, slot, {
    viewer: null,
    durationHours: 1,
    resourceType: "court",
    courtId: ""
  });

  assert.equal(result.ok, false);
  assert.match(result.message, /Sign in/);
});

test("blocks authenticated users that are not approved", () => {
  const scheduler = new SchedulingService();
  const [slot] = buildHourlySlots("2026-06-01", 1);

  const result = submitReservation(scheduler, slot, {
    viewer: pendingMember,
    durationHours: 1,
    resourceType: "court",
    courtId: ""
  });

  assert.equal(result.ok, false);
  assert.match(result.message, /Sign in/);
});

test("labels account approval states used by the booking flow", () => {
  assert.equal(canViewerReserve(approvedMember), true);
  assert.equal(canViewerReserve(pendingMember), false);
  assert.equal(canViewerReserve(guestUser), false);
  assert.equal(accountStatusLabel(approvedMember), "Approved member");
  assert.equal(accountStatusLabel(pendingMember), "Pending approval");
  assert.equal(accountStatusLabel(guestUser), "Guest");
});

test("creates reservation status for an approved member", () => {
  const scheduler = new SchedulingService();
  const [slot] = buildHourlySlots("2026-06-01", 2);

  const result = submitReservation(scheduler, slot, {
    viewer: approvedMember,
    durationHours: 2,
    resourceType: "court",
    courtId: ""
  });

  assert.equal(result.ok, true);
  assert.equal(result.booking.userId, "member-1");
  assert.equal(result.booking.status, "confirmed");
  assert.equal(result.booking.paymentStatus, "due");
  assert.match(result.message, /reserved/);
});

test("preserves requested booking status and payment status fields", () => {
  const scheduler = new SchedulingService();
  const [slot] = buildHourlySlots("2026-06-01", 1);

  const booking = scheduler.createBooking({
    userId: approvedMember.id,
    resourceType: "trainer",
    start: slot.start,
    end: slot.end,
    status: "pending",
    paymentStatus: "paid"
  }, approvedMember);

  assert.equal(booking.status, "pending");
  assert.equal(booking.paymentStatus, "paid");
});

test("blocks approved members from creating reservations for another user", () => {
  const scheduler = new SchedulingService();
  const [slot] = buildHourlySlots("2026-06-01", 1);

  assert.throws(() => scheduler.createBooking({
    userId: "other-member",
    resourceType: "court",
    start: slot.start,
    end: slot.end
  }, approvedMember), /themselves/);
});

test("allows admins to create reservations for another user", () => {
  const scheduler = new SchedulingService();
  const [slot] = buildHourlySlots("2026-06-01", 1);
  const admin = {
    id: "admin-1",
    authenticated: true,
    approved: true,
    role: "admin",
    name: "Admin"
  };

  const booking = scheduler.createBooking({
    userId: "member-2",
    resourceType: "court",
    start: slot.start,
    end: slot.end
  }, admin);

  assert.equal(booking.userId, "member-2");
  assert.equal(booking.resourceType, "court");
});

test("requires authenticated admins for privileged booking operations", () => {
  const scheduler = new SchedulingService();
  const [slot] = buildHourlySlots("2026-06-01", 1);
  const unauthenticatedAdmin = {
    id: "admin-guest",
    authenticated: false,
    approved: true,
    role: "admin",
    name: "Admin Guest"
  };

  assert.throws(() => scheduler.createBooking({
    userId: "member-2",
    resourceType: "court",
    start: slot.start,
    end: slot.end
  }, unauthenticatedAdmin), /logged in/);
});

test("reports unavailable selected court and allows auto-assigned alternatives", () => {
  const scheduler = new SchedulingService({
    bookings: [{
      id: "existing",
      userId: "other-user",
      teamId: null,
      resourceType: "court",
      courtId: "court-1",
      start: new Date("2026-06-01T10:00:00-04:00"),
      end: new Date("2026-06-01T12:00:00-04:00"),
      status: "confirmed",
      paymentStatus: "paid"
    }]
  });
  const [slot] = buildHourlySlots("2026-06-01", 2);

  const selectedCourt = getSlotAvailability(scheduler, slot, {
    viewer: approvedMember,
    resourceType: "court",
    courtId: "court-1"
  });
  const autoAssigned = getSlotAvailability(scheduler, slot, {
    viewer: approvedMember,
    resourceType: "court",
    courtId: ""
  });

  assert.equal(selectedCourt.available, false);
  assert.equal(autoAssigned.available, true);
  assert.equal(autoAssigned.courtId, "court-2");
});

test("hydrates persisted booking date strings for availability checks", () => {
  const scheduler = new SchedulingService({
    bookings: [{
      id: "existing-string-booking",
      userId: "other-user",
      teamId: null,
      resourceType: "court",
      courtId: "court-1",
      start: "2026-06-01T10:00:00-04:00",
      end: "2026-06-01T12:00:00-04:00",
      status: "confirmed",
      paymentStatus: "paid"
    }]
  });
  const [slot] = buildHourlySlots("2026-06-01", 2);

  const availability = getSlotAvailability(scheduler, slot, {
    viewer: approvedMember,
    resourceType: "court",
    courtId: "court-1"
  });

  assert.equal(availability.available, false);
});

test("resolves fixed reservations near local midnight", () => {
  const scheduler = new SchedulingService({
    operatingHours: {
      1: { open: "00:00", close: "04:00" }
    },
    fixedReservations: [{
      id: "overnight-training",
      resourceType: "trainer",
      daysOfWeek: [1],
      startDate: "2026-06-01",
      endDate: "2026-06-01",
      startTime: "00:30",
      endTime: "01:30",
      capacity: 2
    }]
  });
  const slot = {
    start: "2026-06-01T04:30:00.000Z",
    end: "2026-06-01T05:30:00.000Z"
  };

  const availability = getSlotAvailability(scheduler, slot, {
    viewer: approvedMember,
    resourceType: "trainer",
    courtId: ""
  });

  assert.equal(availability.available, false);
  assert.equal(availability.label, "Trainer full");
});

test("reports all resources unavailable outside operating hours", () => {
  const scheduler = new SchedulingService();

  const availability = scheduler.getAvailability({
    start: "2026-06-01T12:00:00.000Z",
    end: "2026-06-01T13:00:00.000Z",
    viewer: approvedMember
  });

  assert.equal(availability.courts.every((court) => court.available === false), true);
  assert.equal(availability.trainer.available, false);
  assert.equal(availability.trainer.availableSlots, 0);
});

test("reports closed days as unavailable in availability checks", () => {
  const scheduler = new SchedulingService({
    operatingHours: {
      1: { closed: true }
    }
  });

  const availability = scheduler.getAvailability({
    start: "2026-06-01T14:00:00.000Z",
    end: "2026-06-01T15:00:00.000Z",
    viewer: approvedMember
  });

  assert.equal(availability.courts.every((court) => court.available === false), true);
  assert.equal(availability.trainer.available, false);
  assert.throws(() => scheduler.createBooking({
    userId: approvedMember.id,
    resourceType: "trainer",
    start: "2026-06-01T14:00:00.000Z",
    end: "2026-06-01T15:00:00.000Z"
  }, approvedMember), /closed/);
});

test("reports trainer pooled capacity and blocks full trainer slots", () => {
  const scheduler = new SchedulingService({
    trainerCapacity: 2,
    bookings: [
      trainerBooking("trainer-a", "2026-06-01T10:00:00-04:00", "2026-06-01T11:00:00-04:00"),
      trainerBooking("trainer-b", "2026-06-01T10:00:00-04:00", "2026-06-01T11:00:00-04:00")
    ]
  });
  const [slot] = buildHourlySlots("2026-06-01", 1);

  const availability = getSlotAvailability(scheduler, slot, {
    viewer: approvedMember,
    resourceType: "trainer",
    courtId: ""
  });
  const result = submitReservation(scheduler, slot, {
    viewer: approvedMember,
    durationHours: 1,
    resourceType: "trainer",
    courtId: ""
  });

  assert.equal(availability.available, false);
  assert.equal(availability.label, "Trainer full");
  assert.equal(result.ok, false);
  assert.match(result.message, /No trainer slot/);
});

test("lists the signed-in user's confirmed bookings after a reservation", () => {
  const scheduler = new SchedulingService();
  const [slot] = buildHourlySlots("2026-06-01", 1);

  const result = submitReservation(scheduler, slot, {
    viewer: approvedMember,
    durationHours: 1,
    resourceType: "trainer",
    courtId: ""
  });
  const bookings = scheduler.listUserBookings(approvedMember.id, approvedMember);

  assert.equal(result.ok, true);
  assert.equal(bookings.length, 1);
  assert.equal(bookings[0].resourceType, "trainer");
  assert.equal(bookings[0].userId, approvedMember.id);
  assert.equal(bookings[0].paymentStatus, "due");
});

test("blocks unauthenticated users from listing bookings", () => {
  const scheduler = new SchedulingService();

  assert.throws(() => scheduler.listUserBookings(guestUser.id, guestUser), /authenticated/);
});

test("blocks unauthenticated admin-shaped users from updating payment status", () => {
  const scheduler = new SchedulingService();
  const [slot] = buildHourlySlots("2026-06-01", 1);
  const result = submitReservation(scheduler, slot, {
    viewer: approvedMember,
    durationHours: 1,
    resourceType: "trainer",
    courtId: ""
  });

  assert.equal(result.ok, true);
  assert.throws(() => scheduler.setPaymentStatus(result.booking.id, "paid", {
    id: "admin-guest",
    authenticated: false,
    role: "admin"
  }), /Only admins/);
});

function trainerBooking(id, start, end) {
  return {
    id,
    userId: "trainer-user",
    teamId: null,
    resourceType: "trainer",
    courtId: null,
    start: new Date(start),
    end: new Date(end),
    status: "confirmed",
    paymentStatus: "paid"
  };
}
