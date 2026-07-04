import assert from "node:assert/strict";
import test from "node:test";

import {
  AuthorizationError,
  BookingConflictError,
  BookingValidationError,
  SchedulingService
} from "../src/scheduler.js";

const approvedUser = { id: "user-1", authenticated: true, approved: true, role: "user" };
const secondUser = { id: "user-2", authenticated: true, approved: true, role: "user" };
const thirdUser = { id: "user-3", authenticated: true, approved: true, role: "user" };
const admin = { id: "admin-1", authenticated: true, approved: true, role: "admin" };

test("auto-assigns an empty court and prevents overlapping court bookings", () => {
  const scheduler = new SchedulingService();

  const first = scheduler.createBooking({
    resourceType: "court",
    start: "2026-06-01T14:00:00-04:00",
    end: "2026-06-01T16:00:00-04:00"
  }, approvedUser);

  assert.equal(first.courtId, "court-1");

  assert.throws(() => scheduler.createBooking({
    resourceType: "court",
    courtId: "court-1",
    start: "2026-06-01T15:00:00-04:00",
    end: "2026-06-01T16:00:00-04:00"
  }, secondUser), BookingConflictError);

  const second = scheduler.createBooking({
    resourceType: "court",
    start: "2026-06-01T15:00:00-04:00",
    end: "2026-06-01T16:00:00-04:00"
  }, secondUser);

  assert.equal(second.courtId, "court-2");
});

test("allows only two simultaneous trainer bookings", () => {
  const scheduler = new SchedulingService();

  scheduler.createBooking({
    resourceType: "trainer",
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T13:00:00-04:00"
  }, approvedUser);

  scheduler.createBooking({
    resourceType: "trainer",
    start: "2026-06-01T12:30:00-04:00",
    end: "2026-06-01T13:30:00-04:00"
  }, secondUser);

  assert.throws(() => scheduler.createBooking({
    resourceType: "trainer",
    start: "2026-06-01T12:30:00-04:00",
    end: "2026-06-01T13:30:00-04:00"
  }, thirdUser), BookingConflictError);

  const later = scheduler.createBooking({
    resourceType: "trainer",
    start: "2026-06-01T13:30:00-04:00",
    end: "2026-06-01T14:30:00-04:00"
  }, thirdUser);

  assert.equal(later.resourceType, "trainer");
});

test("enforces login and admin approval before booking", () => {
  const scheduler = new SchedulingService();

  assert.throws(() => scheduler.createBooking({
    resourceType: "court",
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T13:00:00-04:00"
  }, { id: "guest", authenticated: false, approved: false }), AuthorizationError);

  assert.throws(() => scheduler.createBooking({
    resourceType: "court",
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T13:00:00-04:00"
  }, { id: "pending", authenticated: true, approved: false }), AuthorizationError);
});

test("enforces booking duration, slot boundaries, and operating hours", () => {
  const scheduler = new SchedulingService();

  assert.throws(() => scheduler.createBooking({
    resourceType: "court",
    start: "2026-06-01T09:00:00-04:00",
    end: "2026-06-01T10:00:00-04:00"
  }, approvedUser), BookingConflictError);

  assert.throws(() => scheduler.createBooking({
    resourceType: "court",
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T12:30:00-04:00"
  }, approvedUser), BookingValidationError);

  assert.throws(() => scheduler.createBooking({
    resourceType: "court",
    start: "2026-06-01T12:15:00-04:00",
    end: "2026-06-01T13:15:00-04:00"
  }, approvedUser), BookingValidationError);

  const longBooking = scheduler.createBooking({
    resourceType: "court",
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T16:30:00-04:00"
  }, approvedUser);

  assert.equal(longBooking.courtId, "court-1");
});

test("closures block all affected resources", () => {
  const scheduler = new SchedulingService({
    closures: [{
      id: "holiday",
      resourceType: "all",
      start: "2026-07-04T00:00:00-04:00",
      end: "2026-07-05T00:00:00-04:00",
      reason: "Independence Day"
    }]
  });

  assert.throws(() => scheduler.createBooking({
    resourceType: "court",
    courtId: "court-3",
    start: "2026-07-04T10:00:00-04:00",
    end: "2026-07-04T11:00:00-04:00"
  }, approvedUser), BookingConflictError);

  const availability = scheduler.getAvailability({
    start: "2026-07-04T10:00:00-04:00",
    end: "2026-07-04T11:00:00-04:00",
    viewer: admin
  });

  assert.equal(availability.courts.every((court) => !court.available), true);
  assert.equal(availability.trainer.available, false);
});

test("fixed seasonal reservations block matching court days", () => {
  const scheduler = new SchedulingService({
    fixedReservations: [{
      id: "team-a-season",
      resourceType: "court",
      courtId: "court-4",
      daysOfWeek: [2, 4],
      startDate: "2026-06-01",
      endDate: "2026-08-31",
      startTime: "18:00",
      endTime: "20:00"
    }]
  });

  assert.throws(() => scheduler.createBooking({
    resourceType: "court",
    courtId: "court-4",
    start: "2026-06-02T18:30:00-04:00",
    end: "2026-06-02T19:30:00-04:00"
  }, approvedUser), BookingConflictError);

  const booking = scheduler.createBooking({
    resourceType: "court",
    courtId: "court-4",
    start: "2026-06-03T18:30:00-04:00",
    end: "2026-06-03T19:30:00-04:00"
  }, approvedUser);

  assert.equal(booking.courtId, "court-4");
});

test("regular availability hides blocker details while admin availability includes them", () => {
  const scheduler = new SchedulingService();
  scheduler.createBooking({
    resourceType: "court",
    courtId: "court-1",
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T13:00:00-04:00"
  }, approvedUser);

  const userAvailability = scheduler.getAvailability({
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T13:00:00-04:00",
    viewer: secondUser
  });
  assert.deepEqual(userAvailability.courts[0], { courtId: "court-1", available: false });

  const adminAvailability = scheduler.getAvailability({
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T13:00:00-04:00",
    viewer: admin
  });
  assert.equal(adminAvailability.courts[0].blockers[0].type, "booking");
});

test("users can list their own bookings and admins can update payment status", () => {
  const scheduler = new SchedulingService();
  const booking = scheduler.createBooking({
    resourceType: "court",
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T13:00:00-04:00"
  }, approvedUser);

  assert.equal(scheduler.listUserBookings("user-1", approvedUser).length, 1);
  assert.throws(() => scheduler.listUserBookings("user-1", secondUser), AuthorizationError);

  const paid = scheduler.setPaymentStatus(booking.id, "paid", admin);
  assert.equal(paid.paymentStatus, "paid");
  assert.throws(() => scheduler.setPaymentStatus(booking.id, "due", approvedUser), AuthorizationError);
});

test("soft-deleted bookings are hidden from availability and user lists", () => {
  const scheduler = new SchedulingService({
    bookings: [{
      id: "booking-deleted",
      userId: "user-1",
      teamId: "Riverside 16U",
      resourceType: "court",
      courtId: "court-1",
      start: "2026-06-01T12:00:00-04:00",
      end: "2026-06-01T13:00:00-04:00",
      status: "confirmed",
      paymentStatus: "due",
      Deleted: 1
    }]
  });

  const availability = scheduler.getAvailability({
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T13:00:00-04:00",
    viewer: admin
  });

  assert.equal(availability.courts[0].available, true);
  assert.equal(scheduler.listUserBookings("user-1", approvedUser).length, 0);
});

test("admins can preview soft delete bookings for a team and undo the transaction", () => {
  const scheduler = new SchedulingService({
    bookings: [
      {
        id: "booking-team",
        userId: "subject-team-storm",
        subjectId: "subject-team-storm",
        teamId: "Storm Elite",
        resourceType: "court",
        courtId: "court-5",
        start: "2026-06-01T18:00:00-04:00",
        end: "2026-06-01T20:00:00-04:00",
        status: "confirmed",
        paymentStatus: "due"
      },
      {
        id: "booking-team-paid",
        userId: "subject-team-storm",
        subjectId: "subject-team-storm",
        teamId: "Storm Elite",
        resourceType: "court",
        courtId: "court-6",
        start: "2026-06-02T18:00:00-04:00",
        end: "2026-06-02T20:00:00-04:00",
        status: "confirmed",
        paymentStatus: "paid"
      }
    ]
  });

  const preview = scheduler.previewDeleteBookingsForSubject({
    subjectId: "subject-team-storm",
    subjectName: "Storm Elite",
    start: "2026-06-01T00:00:00-04:00",
    end: "2026-06-30T23:30:00-04:00"
  }, admin);
  assert.equal(preview.length, 1);
  assert.equal(preview[0].id, "booking-team");

  const skippedPaid = scheduler.previewPaidDeleteBookingsForSubject({
    subjectId: "subject-team-storm",
    subjectName: "Storm Elite",
    start: "2026-06-01T00:00:00-04:00",
    end: "2026-06-30T23:30:00-04:00"
  }, admin);
  assert.equal(skippedPaid.length, 1);
  assert.equal(skippedPaid[0].id, "booking-team-paid");

  const deleted = scheduler.deleteBookingsForSubject({
    subjectId: "subject-team-storm",
    subjectName: "Storm Elite",
    start: "2026-06-01T00:00:00-04:00",
    end: "2026-06-30T23:30:00-04:00"
  }, admin);
  assert.equal(deleted.deleted.length, 1);
  assert.equal(scheduler.bookings[0].deleted, true);
  assert.equal(scheduler.bookings[1].deleted, false);
  assert.equal(deleted.skippedPaid.length, 1);

  scheduler.undoBulkOperation(deleted.operation.id, admin);
  assert.equal(scheduler.bookings[0].deleted, false);
});

test("admin bulk reservations apply payment status to every created reservation", () => {
  const scheduler = new SchedulingService();
  const result = scheduler.applyBulkReservationOperation({
    subjectId: "subject-coach-a2z",
    subjectName: "Coach rental",
    userId: "subject-coach-a2z",
    resourceType: "trainer",
    startDate: "2026-06-01",
    endDate: "2026-06-02",
    startTime: "14:00",
    durationMinutes: 60,
    daysOfWeek: [1, 2],
    paymentStatus: "paid",
    conflictResolution: "skip_conflicts"
  }, admin);

  assert.equal(result.created.length, 2);
  assert.equal(result.created.every((booking) => booking.paymentStatus === "paid"), true);
  assert.equal(result.created.every((booking) => booking.bulkOperationId === result.operation.id), true);
  assert.equal(result.created.every((booking) => booking.reservationGroupId === result.reservationGroup.id), true);
  assert.equal(result.reservationGroup.bulkOperationId, result.operation.id);
});

test("bulk delete deletes an RG only after all active child reservations are deleted", () => {
  const scheduler = new SchedulingService();
  const result = scheduler.applyBulkReservationOperation({
    subjectId: "subject-coach-a2z",
    subjectName: "Coach rental",
    userId: "subject-coach-a2z",
    resourceType: "trainer",
    startDate: "2026-06-01",
    endDate: "2026-06-02",
    startTime: "14:00",
    durationMinutes: 60,
    daysOfWeek: [1, 2],
    paymentStatus: "due",
    conflictResolution: "skip_conflicts"
  }, admin);

  const partialDelete = scheduler.deleteBookingsForSubject({
    subjectId: "subject-coach-a2z",
    start: "2026-06-01T00:00:00-04:00",
    end: "2026-06-01T23:30:00-04:00"
  }, admin);

  assert.equal(partialDelete.deleted.length, 1);
  assert.equal(partialDelete.deletedReservationGroups.length, 0);
  assert.equal(scheduler.reservationGroups.find((group) => group.id === result.reservationGroup.id).deleted, undefined);

  const finalDelete = scheduler.deleteBookingsForSubject({
    subjectId: "subject-coach-a2z",
    start: "2026-06-02T00:00:00-04:00",
    end: "2026-06-02T23:30:00-04:00"
  }, admin);

  assert.equal(finalDelete.deleted.length, 1);
  assert.equal(finalDelete.deletedReservationGroups.length, 1);
  assert.equal(finalDelete.deletedReservationGroups[0].id, result.reservationGroup.id);
  assert.equal(scheduler.reservationGroups.find((group) => group.id === result.reservationGroup.id).status, "deleted");
});

test("bulk operation delete skips paid reservations and keeps the RG active until all children are deleted", () => {
  const scheduler = new SchedulingService();
  const result = scheduler.applyBulkReservationOperation({
    subjectId: "subject-coach-a2z",
    subjectName: "Coach rental",
    userId: "subject-coach-a2z",
    resourceType: "trainer",
    startDate: "2026-06-01",
    endDate: "2026-06-02",
    startTime: "14:00",
    durationMinutes: 60,
    daysOfWeek: [1, 2],
    paymentStatus: "due",
    conflictResolution: "skip_conflicts"
  }, admin);

  scheduler.setPaymentStatus(result.created[1].id, "paid", admin);

  const partialDelete = scheduler.undoBulkOperation(result.operation.id, admin);
  assert.equal(partialDelete.deleted.length, 1);
  assert.equal(partialDelete.skippedPaid.length, 1);
  assert.equal(partialDelete.operation.status, "applied");
  assert.equal(scheduler.bookings.find((booking) => booking.id === result.created[0].id).deleted, true);
  assert.equal(scheduler.bookings.find((booking) => booking.id === result.created[1].id).deleted, false);
  assert.equal(scheduler.reservationGroups.find((group) => group.id === result.reservationGroup.id).deleted, undefined);

  scheduler.setPaymentStatus(result.created[1].id, "due", admin);
  const finalDelete = scheduler.undoBulkOperation(result.operation.id, admin);
  assert.equal(finalDelete.deleted.length, 1);
  assert.equal(finalDelete.skippedPaid.length, 0);
  assert.equal(finalDelete.operation.status, "undone");
  assert.equal(finalDelete.deletedReservationGroups[0].id, result.reservationGroup.id);
});

test("team season pricing is stored on admin-created reservations", () => {
  const scheduler = new SchedulingService();
  const single = scheduler.createBooking({
    userId: "subject-team-storm",
    subjectId: "subject-team-storm",
    teamId: "Storm Elite",
    resourceType: "court",
    courtId: "court-3",
    start: "2026-06-01T18:00:00-04:00",
    end: "2026-06-01T20:00:00-04:00",
    seasonPriceId: "price-storm-2026",
    seasonLabel: "2026 Summer",
    hourlyRate: 80,
    amount: 160
  }, admin);

  assert.equal(single.subjectId, "subject-team-storm");
  assert.equal(single.reservationGroupId, null);
  assert.equal(single.seasonPriceId, "price-storm-2026");
  assert.equal(single.hourlyRate, 80);
  assert.equal(single.amount, 160);

  const result = scheduler.applyBulkReservationOperation({
    subjectId: "subject-team-storm",
    subjectName: "Storm Elite",
    userId: "subject-team-storm",
    resourceType: "court",
    courtId: "court-4",
    startDate: "2026-06-02",
    endDate: "2026-06-02",
    startTime: "18:00",
    durationMinutes: 120,
    daysOfWeek: [2],
    seasonPriceId: "price-storm-2026",
    seasonLabel: "2026 Summer",
    hourlyRate: 80,
    conflictResolution: "skip_conflicts"
  }, admin);

  assert.equal(result.created.length, 1);
  assert.equal(result.created[0].seasonPriceId, "price-storm-2026");
  assert.equal(result.created[0].seasonLabel, "2026 Summer");
  assert.equal(result.created[0].hourlyRate, 80);
  assert.equal(result.created[0].amount, 160);
});

test("bulk reservations create one booking per needed court", () => {
  const scheduler = new SchedulingService({ courts: ["court-1", "court-2", "court-3"] });
  const result = scheduler.applyBulkReservationOperation({
    subjectId: "subject-team-storm",
    subjectName: "Storm Elite",
    userId: "subject-team-storm",
    resourceType: "court",
    courtCountNeeded: 2,
    startDate: "2026-06-03",
    endDate: "2026-06-03",
    startTime: "18:00",
    durationMinutes: 120,
    daysOfWeek: [3],
    hourlyRate: 75,
    conflictResolution: "skip_conflicts"
  }, admin);

  assert.equal(result.created.length, 2);
  assert.deepEqual(result.created.map((booking) => booking.courtId), ["court-1", "court-2"]);
  assert.equal(result.created.every((booking) => booking.amount === 150), true);
});
