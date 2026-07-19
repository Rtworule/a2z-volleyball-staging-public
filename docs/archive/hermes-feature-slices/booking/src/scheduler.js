const DEFAULT_COURTS = Array.from({ length: 9 }, (_, index) => `court-${index + 1}`);
const DEFAULT_TRAINER_CAPACITY = 2;
const DEFAULT_TIMEZONE = "America/New_York";
const DEFAULT_HOURS = {
  0: { open: "08:00", close: "21:00" },
  1: { open: "10:00", close: "23:00" },
  2: { open: "10:00", close: "23:00" },
  3: { open: "10:00", close: "23:00" },
  4: { open: "10:00", close: "23:00" },
  5: { open: "10:00", close: "23:00" },
  6: { open: "08:00", close: "21:00" }
};

export class BookingValidationError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = "BookingValidationError";
    this.details = details;
  }
}

export class BookingConflictError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = "BookingConflictError";
    this.details = details;
  }
}

export class AuthorizationError extends Error {
  constructor(message) {
    super(message);
    this.name = "AuthorizationError";
  }
}

export class SchedulingService {
  constructor(options = {}) {
    this.timezone = options.timezone ?? DEFAULT_TIMEZONE;
    this.courts = options.courts ?? DEFAULT_COURTS;
    this.trainerCapacity = options.trainerCapacity ?? DEFAULT_TRAINER_CAPACITY;
    this.operatingHours = { ...DEFAULT_HOURS, ...(options.operatingHours ?? {}) };
    this.closures = options.closures ?? [];
    this.fixedReservations = options.fixedReservations ?? [];
    this.bookings = options.bookings ? options.bookings.map(normalizeStoredBooking) : [];
    this.nextId = options.nextId ?? 1;
  }

  createBooking(request, actor) {
    assertCanBook(actor);

    const start = parseDate(request.start, "start");
    const end = parseDate(request.end, "end");
    validateDuration(start, end);

    const resourceType = request.resourceType;
    if (resourceType !== "court" && resourceType !== "trainer") {
      throw new BookingValidationError("resourceType must be court or trainer");
    }

    this.assertWithinOperatingHours(start, end);

    if (resourceType === "court") {
      return this.createCourtBooking(request, actor, start, end);
    }

    return this.createTrainerBooking(request, actor, start, end);
  }

  createCourtBooking(request, actor, start, end) {
    const userId = resolveBookingUserId(request, actor);
    const requestedCourtId = request.courtId;
    const courtId = requestedCourtId
      ? this.normalizeCourtId(requestedCourtId)
      : this.courts.find((candidate) => this.isCourtAvailable(candidate, start, end));

    if (!courtId) {
      throw new BookingConflictError("No court is available for the requested time", {
        resourceType: "court",
        start,
        end
      });
    }

    if (!this.isCourtAvailable(courtId, start, end)) {
      throw new BookingConflictError(`${courtId} is not available for the requested time`, {
        resourceType: "court",
        courtId,
        start,
        end
      });
    }

    return this.persistBooking({
      userId,
      teamId: request.teamId ?? null,
      resourceType: "court",
      courtId,
      start,
      end,
      status: normalizeBookingStatus(request.status),
      paymentStatus: request.paymentStatus ?? "due",
      createdBy: actor.id
    });
  }

  createTrainerBooking(request, actor, start, end) {
    const userId = resolveBookingUserId(request, actor);

    if (!this.isTrainerAvailable(start, end)) {
      throw new BookingConflictError("No trainer slot is available for the requested time", {
        resourceType: "trainer",
        start,
        end
      });
    }

    return this.persistBooking({
      userId,
      teamId: request.teamId ?? null,
      resourceType: "trainer",
      courtId: null,
      start,
      end,
      status: normalizeBookingStatus(request.status),
      paymentStatus: request.paymentStatus ?? "due",
      createdBy: actor.id
    });
  }

  getAvailability({ start, end, viewer }) {
    const windowStart = parseDate(start, "start");
    const windowEnd = parseDate(end, "end");
    validateDuration(windowStart, windowEnd);

    if (!this.isWithinOperatingHours(windowStart, windowEnd)) {
      return {
        courts: this.courts.map((courtId) => ({ courtId, available: false })),
        trainer: isAdmin(viewer)
          ? { available: false, availableSlots: 0, capacity: this.trainerCapacity, inUse: this.trainerCapacity }
          : { available: false, availableSlots: 0 }
      };
    }

    const courts = this.courts.map((courtId) => {
      const available = this.isCourtAvailable(courtId, windowStart, windowEnd);
      const result = { courtId, available };

      if (isAdmin(viewer) && !available) {
        result.blockers = this.findCourtBlockers(courtId, windowStart, windowEnd);
      }

      return result;
    });

    const trainerInUse = this.maxTrainerUsage(windowStart, windowEnd);
    const trainerAvailableSlots = Math.max(0, this.trainerCapacity - trainerInUse);
    const trainer = isAdmin(viewer)
      ? { available: trainerAvailableSlots > 0, availableSlots: trainerAvailableSlots, capacity: this.trainerCapacity, inUse: trainerInUse }
      : { available: trainerAvailableSlots > 0, availableSlots: trainerAvailableSlots };

    return { courts, trainer };
  }

  listUserBookings(userId, viewer) {
    if (!viewer?.id || !viewer.authenticated) {
      throw new AuthorizationError("Viewer must be authenticated");
    }

    if (viewer.id !== userId && !isAdmin(viewer)) {
      throw new AuthorizationError("Users can only view their own bookings");
    }

    return this.bookings
      .filter((booking) => booking.userId === userId && booking.status !== "cancelled")
      .sort((left, right) => left.start.getTime() - right.start.getTime())
      .map(sanitizeBooking);
  }

  setPaymentStatus(bookingId, paymentStatus, actor) {
    if (!isAdmin(actor)) {
      throw new AuthorizationError("Only admins can update payment status");
    }

    if (!["due", "paid", "waived", "refunded"].includes(paymentStatus)) {
      throw new BookingValidationError("Unsupported payment status");
    }

    const booking = this.bookings.find((candidate) => candidate.id === bookingId);
    if (!booking) {
      throw new BookingValidationError("Booking not found", { bookingId });
    }

    booking.paymentStatus = paymentStatus;
    booking.updatedBy = actor.id;
    booking.updatedAt = new Date();
    return sanitizeBooking(booking);
  }

  isCourtAvailable(courtId, start, end) {
    this.normalizeCourtId(courtId);
    return this.findCourtBlockers(courtId, start, end).length === 0;
  }

  isTrainerAvailable(start, end) {
    return this.maxTrainerUsage(start, end) < this.trainerCapacity;
  }

  assertWithinOperatingHours(start, end) {
    const result = this.checkOperatingHours(start, end);
    if (!result.ok) {
      throw result.error;
    }
  }

  isWithinOperatingHours(start, end) {
    return this.checkOperatingHours(start, end).ok;
  }

  checkOperatingHours(start, end) {
    const startParts = zonedParts(start, this.timezone);
    const endParts = zonedParts(end, this.timezone);

    if (startParts.dateKey !== endParts.dateKey) {
      return {
        ok: false,
        error: new BookingValidationError("Bookings must start and end on the same local day")
      };
    }

    const hours = this.operatingHours[startParts.dayOfWeek];
    if (!hours || hours.closed) {
      return {
        ok: false,
        error: new BookingConflictError("The center is closed on the requested day")
      };
    }

    const openMinutes = timeToMinutes(hours.open);
    const closeMinutes = timeToMinutes(hours.close);
    const startMinutes = startParts.hour * 60 + startParts.minute;
    const endMinutes = endParts.hour * 60 + endParts.minute;

    if (startMinutes < openMinutes || endMinutes > closeMinutes) {
      return {
        ok: false,
        error: new BookingConflictError("Requested time is outside operating hours", {
          open: hours.open,
          close: hours.close
        })
      };
    }

    return { ok: true };
  }

  findCourtBlockers(courtId, start, end) {
    return [
      ...this.findClosureBlockers("court", courtId, start, end),
      ...this.findFixedReservationBlockers("court", courtId, start, end),
      ...this.bookings
        .filter((booking) => booking.status !== "cancelled")
        .filter((booking) => booking.resourceType === "court")
        .filter((booking) => booking.courtId === courtId)
        .filter((booking) => overlaps(booking.start, booking.end, start, end))
        .map((booking) => ({ type: "booking", id: booking.id }))
    ];
  }

  findClosureBlockers(resourceType, courtId, start, end) {
    return this.closures
      .filter((closure) => !closure.resourceType || closure.resourceType === "all" || closure.resourceType === resourceType)
      .filter((closure) => !closure.courtId || closure.courtId === courtId)
      .filter((closure) => overlaps(parseDate(closure.start, "closure.start"), parseDate(closure.end, "closure.end"), start, end))
      .map((closure) => ({ type: "closure", id: closure.id, reason: closure.reason ?? null }));
  }

  findFixedReservationBlockers(resourceType, courtId, start, end) {
    return this.fixedReservations
      .filter((reservation) => reservation.resourceType === resourceType)
      .filter((reservation) => !reservation.courtId || reservation.courtId === courtId)
      .filter((reservation) => fixedReservationOverlaps(reservation, start, end, this.timezone))
      .map((reservation) => ({ type: "fixed-reservation", id: reservation.id }));
  }

  maxTrainerUsage(start, end) {
    const usageIntervals = [
      ...this.findClosureBlockers("trainer", null, start, end).map(() => ({
        start,
        end,
        capacity: this.trainerCapacity
      })),
      ...this.fixedReservations
        .filter((reservation) => reservation.resourceType === "trainer")
        .filter((reservation) => fixedReservationOverlaps(reservation, start, end, this.timezone))
        .map((reservation) => ({
          start: maxDate(start, dateAtLocalTime(start, reservation.startTime, this.timezone)),
          end: minDate(end, dateAtLocalTime(start, reservation.endTime, this.timezone)),
          capacity: reservation.capacity ?? 1
        })),
      ...this.bookings
        .filter((booking) => booking.status !== "cancelled")
        .filter((booking) => booking.resourceType === "trainer")
        .filter((booking) => overlaps(booking.start, booking.end, start, end))
        .map((booking) => ({ start: booking.start, end: booking.end, capacity: 1 }))
    ];

    return maxConcurrentUsage(usageIntervals, start, end);
  }

  normalizeCourtId(courtId) {
    if (!this.courts.includes(courtId)) {
      throw new BookingValidationError("Unknown court", { courtId });
    }
    return courtId;
  }

  persistBooking(booking) {
    const saved = {
      ...booking,
      id: `booking-${this.nextId++}`,
      createdAt: new Date()
    };
    this.bookings.push(saved);
    return sanitizeBooking(saved);
  }
}

function assertCanBook(actor) {
  if (!actor?.id || !actor.authenticated) {
    throw new AuthorizationError("User must be logged in before booking");
  }

  if (!actor.approved && !isAdmin(actor)) {
    throw new AuthorizationError("User registration must be approved by an admin before booking");
  }
}

function resolveBookingUserId(request, actor) {
  const userId = request.userId ?? actor.id;
  if (userId !== actor.id && !isAdmin(actor)) {
    throw new AuthorizationError("Users can only create bookings for themselves");
  }
  return userId;
}

function isAdmin(user) {
  return user?.authenticated === true && user.role === "admin";
}

function parseDate(value, fieldName) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new BookingValidationError(`Invalid ${fieldName} date`);
  }
  return date;
}

function validateDuration(start, end) {
  const minutes = (end.getTime() - start.getTime()) / 60000;
  if (minutes < 60 || minutes > 240) {
    throw new BookingValidationError("Bookings must be between 1 and 4 hours");
  }
}

function normalizeBookingStatus(status) {
  const normalizedStatus = status ?? "confirmed";
  if (!["pending", "confirmed", "cancelled"].includes(normalizedStatus)) {
    throw new BookingValidationError("Unsupported booking status");
  }
  return normalizedStatus;
}

function overlaps(leftStart, leftEnd, rightStart, rightEnd) {
  return leftStart < rightEnd && rightStart < leftEnd;
}

function timeToMinutes(time) {
  const match = /^(\d{2}):(\d{2})$/.exec(time);
  if (!match) {
    throw new BookingValidationError("Time must use HH:mm format", { time });
  }
  return Number(match[1]) * 60 + Number(match[2]);
}

function zonedParts(date, timezone) {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: timezone,
    weekday: "short",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23"
  });
  const parts = Object.fromEntries(formatter.formatToParts(date).map((part) => [part.type, part.value]));
  const dayMap = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

  return {
    dateKey: `${parts.year}-${parts.month}-${parts.day}`,
    dayOfWeek: dayMap[parts.weekday],
    hour: Number(parts.hour),
    minute: Number(parts.minute)
  };
}

function fixedReservationOverlaps(reservation, start, end, timezone) {
  const startParts = zonedParts(start, timezone);
  const dayOfWeek = startParts.dayOfWeek;
  if (!reservation.daysOfWeek.includes(dayOfWeek)) {
    return false;
  }

  const localDate = startParts.dateKey;
  if (reservation.startDate && localDate < reservation.startDate) {
    return false;
  }
  if (reservation.endDate && localDate > reservation.endDate) {
    return false;
  }

  const reservationStart = dateAtLocalTime(start, reservation.startTime, timezone);
  const reservationEnd = dateAtLocalTime(start, reservation.endTime, timezone);
  return overlaps(reservationStart, reservationEnd, start, end);
}

function dateAtLocalTime(anchorDate, time, timezone) {
  const parts = zonedParts(anchorDate, timezone);
  const [hour, minute] = time.split(":").map(Number);
  const desiredUtc = Date.UTC(
    Number(parts.dateKey.slice(0, 4)),
    Number(parts.dateKey.slice(5, 7)) - 1,
    Number(parts.dateKey.slice(8, 10)),
    hour,
    minute
  );
  const utcGuess = new Date(desiredUtc);
  const guessParts = zonedParts(utcGuess, timezone);
  const zonedAsUtc = Date.UTC(
    Number(guessParts.dateKey.slice(0, 4)),
    Number(guessParts.dateKey.slice(5, 7)) - 1,
    Number(guessParts.dateKey.slice(8, 10)),
    guessParts.hour,
    guessParts.minute
  );

  return new Date(utcGuess.getTime() - (zonedAsUtc - desiredUtc));
}

function maxConcurrentUsage(intervals, start, end) {
  const events = [];

  for (const interval of intervals) {
    const clippedStart = maxDate(parseDate(interval.start, "interval.start"), start);
    const clippedEnd = minDate(parseDate(interval.end, "interval.end"), end);
    if (clippedStart < clippedEnd) {
      events.push({ at: clippedStart.getTime(), delta: interval.capacity });
      events.push({ at: clippedEnd.getTime(), delta: -interval.capacity });
    }
  }

  events.sort((left, right) => left.at - right.at || left.delta - right.delta);

  let current = 0;
  let max = 0;
  for (const event of events) {
    current += event.delta;
    max = Math.max(max, current);
  }
  return max;
}

function maxDate(left, right) {
  return left > right ? left : right;
}

function minDate(left, right) {
  return left < right ? left : right;
}

function sanitizeBooking(booking) {
  return {
    id: booking.id,
    userId: booking.userId,
    teamId: booking.teamId,
    resourceType: booking.resourceType,
    courtId: booking.courtId,
    start: booking.start.toISOString(),
    end: booking.end.toISOString(),
    status: booking.status,
    paymentStatus: booking.paymentStatus
  };
}

function normalizeStoredBooking(booking) {
  return {
    ...booking,
    start: parseDate(booking.start, "booking.start"),
    end: parseDate(booking.end, "booking.end")
  };
}
