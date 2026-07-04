import assert from "node:assert/strict";
import test from "node:test";

import { SchedulingService } from "../src/scheduler.js";

const viewer = { id: "viewer", authenticated: true, approved: true, role: "user" };

test("availability exposes all 9 courts and pooled trainer capacity", () => {
  const scheduler = new SchedulingService({
    bookings: [
      {
        id: "court-booking",
        userId: "user-1",
        teamId: null,
        resourceType: "court",
        courtId: "court-1",
        start: new Date("2026-06-01T12:00:00-04:00"),
        end: new Date("2026-06-01T13:00:00-04:00"),
        status: "confirmed",
        paymentStatus: "paid"
      },
      {
        id: "trainer-booking-a",
        userId: "user-1",
        teamId: null,
        resourceType: "trainer",
        courtId: null,
        start: new Date("2026-06-01T12:00:00-04:00"),
        end: new Date("2026-06-01T13:00:00-04:00"),
        status: "confirmed",
        paymentStatus: "paid"
      }
    ]
  });

  const availability = scheduler.getAvailability({
    start: "2026-06-01T12:00:00-04:00",
    end: "2026-06-01T13:00:00-04:00",
    viewer
  });

  assert.equal(availability.courts.length, 9);
  assert.equal(availability.courts[0].available, false);
  assert.equal(availability.courts.filter((court) => court.available).length, 8);
  assert.deepEqual(availability.trainer, { available: true, availableSlots: 1 });
});
