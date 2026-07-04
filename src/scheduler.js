const DEFAULT_COURTS = Array.from({ length: 9 }, (_, index) => `court-${index + 1}`);
const DEFAULT_TRAINER_CAPACITY = 2;
const DEFAULT_TIMEZONE = "America/New_York";
const DEFAULT_SLOT_INTERVAL_MINUTES = 30;
const DEFAULT_MIN_BOOKING_MINUTES = 60;
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
    this.slotIntervalMinutes = options.slotIntervalMinutes ?? DEFAULT_SLOT_INTERVAL_MINUTES;
    this.minBookingMinutes = options.minBookingMinutes ?? DEFAULT_MIN_BOOKING_MINUTES;
    this.operatingHours = { ...DEFAULT_HOURS, ...(options.operatingHours ?? {}) };
    this.closures = options.closures ?? [];
    this.fixedReservations = options.fixedReservations ?? [];
    this.bookings = options.bookings ? options.bookings.map(normalizeStoredBooking) : [];
    this.bulkOperations = options.bulkOperations ? options.bulkOperations.map(normalizeStoredBulkOperation) : [];
    this.reservationGroups = options.reservationGroups ?? [];
    this.nextId = options.nextId ?? 1;
    this.nextBulkOperationId = options.nextBulkOperationId ?? 1;
    this.nextReservationGroupId = options.nextReservationGroupId ?? 1;
  }

  createBooking(request, actor) {
    assertCanBook(actor);

    const start = parseDate(request.start, "start");
    const end = parseDate(request.end, "end");
    this.validateBookingWindow(start, end);

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
      subjectId: request.subjectId ?? null,
      resourceType: "court",
      courtId,
      start,
      end,
      status: normalizeBookingStatus(request.status),
      paymentStatus: normalizePaymentStatus(request.paymentStatus ?? (request.paid ? "paid" : "due")),
      seasonPriceId: request.seasonPriceId ?? null,
      seasonLabel: request.seasonLabel ?? null,
      hourlyRate: request.hourlyRate ?? null,
      amount: request.amount ?? request.amountDue ?? null,
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
      subjectId: request.subjectId ?? null,
      resourceType: "trainer",
      courtId: null,
      start,
      end,
      status: normalizeBookingStatus(request.status),
      paymentStatus: normalizePaymentStatus(request.paymentStatus ?? (request.paid ? "paid" : "due")),
      seasonPriceId: request.seasonPriceId ?? null,
      seasonLabel: request.seasonLabel ?? null,
      hourlyRate: request.hourlyRate ?? null,
      amount: request.amount ?? request.amountDue ?? null,
      createdBy: actor.id
    });
  }

  getAvailability({ start, end, viewer }) {
    const windowStart = parseDate(start, "start");
    const windowEnd = parseDate(end, "end");
    this.validateBookingWindow(windowStart, windowEnd);

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
      .filter(isVisibleBooking)
      .filter((booking) => booking.userId === userId)
      .sort((left, right) => left.start.getTime() - right.start.getTime())
      .map(sanitizeBooking);
  }

  setPaymentStatus(bookingId, paymentStatus, actor) {
    if (!isAdmin(actor)) {
      throw new AuthorizationError("Only admins can update payment status");
    }

    const booking = this.bookings.find((candidate) => candidate.id === bookingId && !isDeleted(candidate));
    if (!booking) {
      throw new BookingValidationError("Booking not found", { bookingId });
    }

    booking.paymentStatus = normalizePaymentStatus(paymentStatus);
    booking.updatedBy = actor.id;
    booking.updatedAt = new Date();
    booking.updatedDT = booking.updatedAt.toISOString();
    return sanitizeBooking(booking);
  }

  setPaidStatus(bookingId, paid, actor) {
    return this.setPaymentStatus(bookingId, paid ? "paid" : "due", actor);
  }

  previewDeleteBookingsForSubject(request, actor) {
    assertAdmin(actor);
    const start = parseDate(request.start, "start");
    const end = parseDate(request.end, "end");
    const subject = normalizeSubjectCriteria(request);

    return this.bookings
      .filter(isVisibleBooking)
      .filter((booking) => !isBookingPaid(booking))
      .filter((booking) => bookingMatchesSubject(booking, subject))
      .filter((booking) => overlaps(booking.start, booking.end, start, end))
      .sort((left, right) => left.start.getTime() - right.start.getTime())
      .map(sanitizeBooking);
  }

  previewPaidDeleteBookingsForSubject(request, actor) {
    assertAdmin(actor);
    const start = parseDate(request.start, "start");
    const end = parseDate(request.end, "end");
    const subject = normalizeSubjectCriteria(request);

    return this.bookings
      .filter(isVisibleBooking)
      .filter(isBookingPaid)
      .filter((booking) => bookingMatchesSubject(booking, subject))
      .filter((booking) => overlaps(booking.start, booking.end, start, end))
      .sort((left, right) => left.start.getTime() - right.start.getTime())
      .map(sanitizeBooking);
  }

  deleteBookingsForSubject(request, actor) {
    assertAdmin(actor);
    const operationId = request.bulkOperationId ?? `bulk-${this.nextBulkOperationId++}`;
    const matchingIds = new Set(this.previewDeleteBookingsForSubject(request, actor).map((booking) => booking.id));
    const skippedPaid = this.previewPaidDeleteBookingsForSubject(request, actor);
    const affectedReservationGroupIds = new Set();
    const now = new Date();

    for (const booking of this.bookings) {
      if (!matchingIds.has(booking.id)) {
        continue;
      }
      booking.deleted = true;
      booking.Deleted = 1;
      booking.deletedBy = actor.id;
      booking.bulkOperationId = operationId;
      if (booking.reservationGroupId) {
        affectedReservationGroupIds.add(booking.reservationGroupId);
      }
      booking.updatedBy = actor.id;
      booking.updatedAt = now;
      booking.updatedDT = now.toISOString();
    }

    const operation = {
      id: operationId,
      operationType: "reservation_delete",
      status: "applied",
      appliedBy: actor.id,
      appliedDT: now.toISOString(),
      createdBy: actor.id,
      createdDT: now.toISOString(),
      updatedDT: now.toISOString(),
      itemIds: [...matchingIds],
      requestedPayload: { ...request, start: startToIso(request.start), end: startToIso(request.end) }
    };
    this.bulkOperations.push(operation);

    const deletedReservationGroups = [];
    for (const reservationGroup of this.reservationGroups) {
      if (!affectedReservationGroupIds.has(reservationGroup.id)) {
        continue;
      }
      const hasActiveChildren = this.bookings.some((booking) => booking.reservationGroupId === reservationGroup.id && !isDeleted(booking) && booking.status !== "cancelled");
      if (!hasActiveChildren) {
        reservationGroup.deleted = true;
        reservationGroup.Deleted = 1;
        reservationGroup.status = "deleted";
        reservationGroup.updatedDT = now.toISOString();
        deletedReservationGroups.push({ ...reservationGroup });
      }
    }

    return {
      operation,
      deleted: this.bookings.filter((booking) => matchingIds.has(booking.id)).map(sanitizeBooking),
      skippedPaid,
      deletedReservationGroups
    };
  }

  previewBulkReservationOperation(request, actor) {
    assertAdmin(actor);
    const normalized = normalizeBulkReservationRequest(request);
    const items = [];

    for (const date of datesBetween(normalized.startDate, normalized.endDate)) {
      const dayOfWeek = dayOfWeekFromDateKey(date);
      if (!normalized.daysOfWeek.includes(dayOfWeek)) {
        continue;
      }

      const start = dateAtLocalTime(new Date(`${date}T12:00:00Z`), normalized.startTime, this.timezone);
      const end = new Date(start.getTime() + normalized.durationMinutes * 60000);
      const item = {
        subjectId: normalized.subjectId,
        subjectName: normalized.subjectName,
        userId: normalized.userId,
        resourceType: normalized.resourceType,
        courtId: normalized.courtId,
        courtIds: normalized.courtId ? [normalized.courtId] : [],
        courtCountNeeded: normalized.courtCountNeeded,
        start,
        end,
        seasonPriceId: normalized.seasonPriceId,
        seasonLabel: normalized.seasonLabel,
        hourlyRate: normalized.hourlyRate,
        amount: calculateAmount(normalized.hourlyRate, normalized.durationMinutes),
        paymentStatus: normalized.paymentStatus,
        status: "preview",
        conflictReason: null
      };

      try {
        this.validateBookingWindow(start, end);
        this.assertWithinOperatingHours(start, end);
        if (normalized.resourceType === "court") {
          const resolvedCourtIds = this.resolveBulkCourts(normalized, start, end);
          item.courtIds = resolvedCourtIds;
          item.courtId = resolvedCourtIds[0] ?? null;
        } else if (!this.isTrainerAvailable(start, end)) {
          throw new BookingConflictError("No trainer slot is available");
        }
      } catch (error) {
        item.status = "conflict";
        item.conflictReason = error.message;
      }

      items.push(sanitizeBulkOperationItem(item));
    }

    return {
      id: request.id ?? null,
      operationType: "reservation_create",
      label: normalized.label,
      status: request.applyAfter ? "scheduled" : "previewed",
      applyAfter: request.applyAfter ?? null,
      paymentStatus: normalized.paymentStatus,
      conflictResolution: normalized.conflictResolution,
      requestedPayload: normalized,
      items
    };
  }

  saveBulkReservationOperation(request, actor) {
    assertAdmin(actor);
    const preview = this.previewBulkReservationOperation(request, actor);
    const now = new Date().toISOString();
    const operation = {
      ...preview,
      id: request.id ?? `bulk-${this.nextBulkOperationId++}`,
      status: request.applyAfter ? "scheduled" : "previewed",
      createdBy: actor.id,
      createdDT: now,
      updatedDT: now
    };
    this.bulkOperations.push(operation);
    return operation;
  }

  applyBulkReservationOperation(request, actor) {
    assertAdmin(actor);
    const operation = this.saveBulkReservationOperation(request, actor);
    const reservationGroupCreatedAt = new Date().toISOString();
    const reservationGroup = {
      id: request.reservationGroupId ?? `reservation-group-${this.nextReservationGroupId++}`,
      label: operation.label,
      subjectId: operation.requestedPayload.subjectId,
      subjectTeamId: operation.requestedPayload.subjectTeamId ?? null,
      bulkOperationId: operation.id,
      resourceType: operation.requestedPayload.resourceType,
      startDate: operation.requestedPayload.startDate,
      endDate: operation.requestedPayload.endDate,
      status: "active",
      createdBy: actor.id,
      createdDT: reservationGroupCreatedAt,
      updatedDT: reservationGroupCreatedAt
    };
    const appliedItemIds = [];

    for (const item of operation.items) {
      if (item.status === "conflict") {
        if (operation.conflictResolution === "fail_all") {
          throw new BookingConflictError("Bulk operation has conflicts", { operation });
        }
        continue;
      }

      const courtIds = item.resourceType === "court" ? item.courtIds?.length ? item.courtIds : [item.courtId] : [null];
      for (const courtId of courtIds) {
        const booking = this.persistBooking({
          userId: item.userId,
          teamId: item.subjectName,
          subjectId: item.subjectId,
          resourceType: item.resourceType,
          courtId,
          start: parseDate(item.start, "item.start"),
          end: parseDate(item.end, "item.end"),
          status: "confirmed",
          paymentStatus: item.paymentStatus,
          seasonPriceId: item.seasonPriceId,
          seasonLabel: item.seasonLabel,
          hourlyRate: item.hourlyRate,
          amount: item.amount,
          createdBy: actor.id,
          bulkOperationId: operation.id,
          reservationGroupId: reservationGroup.id
        });
        appliedItemIds.push(booking.id);
      }
    }

    const now = new Date().toISOString();
    operation.status = "applied";
    operation.appliedBy = actor.id;
    operation.appliedDT = now;
    operation.updatedDT = now;
    operation.appliedReservationIds = appliedItemIds;
    this.reservationGroups.push(reservationGroup);

    return {
      operation,
      reservationGroup,
      created: this.bookings.filter((booking) => appliedItemIds.includes(booking.id)).map(sanitizeBooking)
    };
  }

  undoBulkOperation(operationId, actor) {
    assertAdmin(actor);
    const operation = this.bulkOperations.find((candidate) => candidate.id === operationId && !isDeleted(candidate));
    if (!operation) {
      throw new BookingValidationError("Bulk operation not found", { operationId });
    }

    const now = new Date();
    const affectedIds = new Set(operation.appliedReservationIds ?? operation.itemIds ?? []);
    const deleted = [];
    const skippedPaid = [];
    const affectedReservationGroupIds = new Set();
    for (const booking of this.bookings) {
      if (booking.bulkOperationId !== operationId && !affectedIds.has(booking.id)) {
        continue;
      }

      if (operation.operationType === "reservation_create") {
        if (isDeleted(booking) || booking.status === "cancelled") {
          continue;
        }
        if (isBookingPaid(booking)) {
          skippedPaid.push(sanitizeBooking(booking));
          continue;
        }
        booking.deleted = true;
        booking.Deleted = 1;
        deleted.push(sanitizeBooking(booking));
        if (booking.reservationGroupId) {
          affectedReservationGroupIds.add(booking.reservationGroupId);
        }
      } else if (operation.operationType === "reservation_delete") {
        booking.deleted = false;
        booking.Deleted = 0;
      }

      booking.updatedBy = actor.id;
      booking.updatedAt = now;
      booking.updatedDT = now.toISOString();
    }

    const deletedReservationGroups = [];
    for (const reservationGroup of this.reservationGroups) {
      if (!affectedReservationGroupIds.has(reservationGroup.id)) {
        continue;
      }
      const hasActiveChildren = this.bookings.some((booking) => booking.reservationGroupId === reservationGroup.id && !isDeleted(booking) && booking.status !== "cancelled");
      if (!hasActiveChildren) {
        reservationGroup.deleted = true;
        reservationGroup.Deleted = 1;
        reservationGroup.status = "deleted";
        reservationGroup.updatedDT = now.toISOString();
        deletedReservationGroups.push({ ...reservationGroup });
      }
    }

    if (!skippedPaid.length || operation.operationType !== "reservation_create") {
      operation.status = "undone";
      operation.undoneBy = actor.id;
      operation.undoneDT = now.toISOString();
    }
    operation.updatedDT = now.toISOString();
    return {
      operation,
      deleted,
      skippedPaid,
      deletedReservationGroups
    };
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

  validateBookingWindow(start, end) {
    validateDuration(start, end, this.minBookingMinutes, this.slotIntervalMinutes);
    validateSlotBoundary(start, this.timezone, this.slotIntervalMinutes, "start");
    validateSlotBoundary(end, this.timezone, this.slotIntervalMinutes, "end");
  }

  findCourtBlockers(courtId, start, end) {
    return [
      ...this.findClosureBlockers("court", courtId, start, end),
      ...this.findFixedReservationBlockers("court", courtId, start, end),
      ...this.bookings
        .filter(isVisibleBooking)
        .filter((booking) => booking.resourceType === "court")
        .filter((booking) => booking.courtId === courtId)
        .filter((booking) => overlaps(booking.start, booking.end, start, end))
        .map((booking) => ({ type: "booking", id: booking.id }))
    ];
  }

  findClosureBlockers(resourceType, courtId, start, end) {
    return this.closures
      .filter((closure) => !isDeleted(closure))
      .filter((closure) => !closure.resourceType || closure.resourceType === "all" || closure.resourceType === resourceType)
      .filter((closure) => !closure.courtId || closure.courtId === courtId)
      .filter((closure) => overlaps(parseDate(closure.start, "closure.start"), parseDate(closure.end, "closure.end"), start, end))
      .map((closure) => ({ type: "closure", id: closure.id, reason: closure.reason ?? null }));
  }

  findFixedReservationBlockers(resourceType, courtId, start, end) {
    return this.fixedReservations
      .filter((reservation) => !isDeleted(reservation))
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
        .filter((reservation) => !isDeleted(reservation))
        .filter((reservation) => reservation.resourceType === "trainer")
        .filter((reservation) => fixedReservationOverlaps(reservation, start, end, this.timezone))
        .map((reservation) => ({
          start: maxDate(start, dateAtLocalTime(start, reservation.startTime, this.timezone)),
          end: minDate(end, dateAtLocalTime(start, reservation.endTime, this.timezone)),
          capacity: reservation.capacity ?? 1
        })),
      ...this.bookings
        .filter(isVisibleBooking)
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

  resolveBulkCourt(request, start, end) {
    return this.resolveBulkCourts(request, start, end)[0] ?? null;
  }

  resolveBulkCourts(request, start, end) {
    if (request.resourceType !== "court") {
      return [];
    }

    const requestedCourtId = request.courtId ? this.normalizeCourtId(request.courtId) : null;
    const courtCountNeeded = Math.max(1, Number(request.courtCountNeeded ?? 1));
    const resolvedCourtIds = [];
    if (requestedCourtId && this.isCourtAvailable(requestedCourtId, start, end)) {
      resolvedCourtIds.push(requestedCourtId);
    }

    if (requestedCourtId && !resolvedCourtIds.includes(requestedCourtId) && request.conflictResolution !== "first_available_court") {
      throw new BookingConflictError(`${requestedCourtId} is not available for the requested time`);
    }

    if (resolvedCourtIds.length < courtCountNeeded) {
      for (const candidate of this.courts) {
        if (resolvedCourtIds.includes(candidate)) {
          continue;
        }
        if (this.isCourtAvailable(candidate, start, end)) {
          resolvedCourtIds.push(candidate);
        }
        if (resolvedCourtIds.length >= courtCountNeeded) {
          break;
        }
      }
    }

    if (resolvedCourtIds.length < courtCountNeeded) {
      throw new BookingConflictError("No Court Available");
    }
    return resolvedCourtIds;
  }

  persistBooking(booking) {
    const now = new Date();
    const saved = {
      ...booking,
      id: `booking-${this.nextId++}`,
      paymentStatus: normalizePaymentStatus(booking.paymentStatus ?? (booking.paid ? "paid" : "due")),
      reservationGroupId: booking.reservationGroupId ?? null,
      deleted: Boolean(booking.deleted),
      Deleted: booking.deleted ? 1 : 0,
      createdAt: now,
      updatedAt: now,
      createdDT: now.toISOString(),
      updatedDT: now.toISOString()
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

function assertAdmin(actor) {
  if (!isAdmin(actor)) {
    throw new AuthorizationError("Only admins can manage bulk operations");
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

function validateDuration(start, end, minMinutes = DEFAULT_MIN_BOOKING_MINUTES, intervalMinutes = DEFAULT_SLOT_INTERVAL_MINUTES) {
  const minutes = (end.getTime() - start.getTime()) / 60000;
  if (minutes < minMinutes) {
    throw new BookingValidationError("Bookings must be at least 1 hour");
  }
  if (minutes % intervalMinutes !== 0) {
    throw new BookingValidationError("Bookings must use 30 minute increments");
  }
}

function validateSlotBoundary(date, timezone, intervalMinutes, fieldName) {
  const parts = zonedParts(date, timezone);
  const minutes = parts.hour * 60 + parts.minute;
  if (minutes % intervalMinutes !== 0) {
    throw new BookingValidationError(`${fieldName} time must be on a ${intervalMinutes} minute boundary`);
  }
}

function normalizeBookingStatus(status) {
  const normalizedStatus = status ?? "confirmed";
  if (!["pending", "confirmed", "cancelled"].includes(normalizedStatus)) {
    throw new BookingValidationError("Unsupported booking status");
  }
  return normalizedStatus;
}

function normalizePaymentStatus(paymentStatus) {
  if (!["due", "paid", "waived", "refunded"].includes(paymentStatus)) {
    throw new BookingValidationError("Unsupported payment status");
  }
  return paymentStatus;
}

function isVisibleBooking(booking) {
  return !isDeleted(booking) && booking.status !== "cancelled";
}

function isDeleted(record) {
  return record?.deleted === true || record?.Deleted === 1 || record?.Deleted === true;
}

function normalizeSubjectCriteria(request) {
  if (!request.subjectId && !request.subjectName && !request.userId && !request.teamId) {
    throw new BookingValidationError("A team or coach is required");
  }

  return {
    subjectId: request.subjectId ?? null,
    subjectName: request.subjectName ?? request.teamId ?? null,
    userId: request.userId ?? null
  };
}

function bookingMatchesSubject(booking, subject) {
  return Boolean(
    (subject.subjectId && (booking.subjectId === subject.subjectId || booking.teamId === subject.subjectId || booking.userId === subject.subjectId))
      || (subject.subjectName && (booking.teamId === subject.subjectName || booking.subjectName === subject.subjectName))
      || (subject.userId && booking.userId === subject.userId)
  );
}

function normalizeBulkReservationRequest(request) {
  const daysOfWeek = request.daysOfWeek?.length
    ? request.daysOfWeek.map(Number)
    : [1, 2, 3, 4, 5];
  const durationMinutes = Number(request.durationMinutes ?? DEFAULT_MIN_BOOKING_MINUTES);
  const resourceType = request.resourceType ?? "court";
  const courtCountNeeded = Math.max(1, Number(request.courtCountNeeded ?? 1));
  if (resourceType !== "court" && resourceType !== "trainer") {
    throw new BookingValidationError("resourceType must be court or trainer");
  }

  return {
    label: request.label ?? "Bulk reservation",
    subjectId: request.subjectId ?? null,
    subjectName: request.subjectName ?? request.teamId ?? "Temporary subject",
    userId: request.userId ?? request.subjectId ?? request.teamId ?? "admin-temp",
    resourceType,
    courtId: resourceType === "court" ? request.courtId ?? null : null,
    courtCountNeeded: resourceType === "court" ? courtCountNeeded : 1,
    startDate: request.startDate,
    endDate: request.endDate ?? request.startDate,
    startTime: request.startTime,
    durationMinutes,
    daysOfWeek,
    seasonPriceId: request.seasonPriceId ?? null,
    seasonLabel: request.seasonLabel ?? null,
    hourlyRate: request.hourlyRate == null ? null : Number(request.hourlyRate),
    paymentStatus: normalizePaymentStatus(request.paymentStatus ?? (request.paid ? "paid" : "due")),
    conflictResolution: request.conflictResolution ?? "skip_conflicts"
  };
}

function datesBetween(startDate, endDate) {
  if (!startDate || !endDate || startDate > endDate) {
    throw new BookingValidationError("Start and end dates are required");
  }

  const dates = [];
  const cursor = new Date(`${startDate}T12:00:00Z`);
  const last = new Date(`${endDate}T12:00:00Z`);
  while (cursor <= last) {
    dates.push(cursor.toISOString().slice(0, 10));
    cursor.setUTCDate(cursor.getUTCDate() + 1);
  }
  return dates;
}

function dayOfWeekFromDateKey(dateKey) {
  const [year, month, day] = dateKey.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day, 12)).getUTCDay();
}

function sanitizeBulkOperationItem(item) {
  return {
    id: item.id ?? null,
    subjectId: item.subjectId,
    subjectName: item.subjectName,
    userId: item.userId,
    resourceType: item.resourceType,
    courtId: item.courtId,
    courtIds: item.courtIds ?? [],
    courtCountNeeded: item.courtCountNeeded ?? 1,
    start: item.start instanceof Date ? item.start.toISOString() : item.start,
    end: item.end instanceof Date ? item.end.toISOString() : item.end,
    seasonPriceId: item.seasonPriceId ?? null,
    seasonLabel: item.seasonLabel ?? null,
    hourlyRate: item.hourlyRate,
    amount: item.amount ?? item.amountDue,
    paymentStatus: normalizePaymentStatus(item.paymentStatus ?? (item.paid ? "paid" : "due")),
    status: item.status,
    conflictReason: item.conflictReason
  };
}

function normalizeStoredBulkOperation(operation) {
  return {
    ...operation,
    deleted: Boolean(operation.deleted ?? operation.Deleted)
  };
}

function startToIso(value) {
  return value instanceof Date ? value.toISOString() : value;
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
    subjectId: booking.subjectId ?? null,
    resourceType: booking.resourceType,
    courtId: booking.courtId,
    start: booking.start.toISOString(),
    end: booking.end.toISOString(),
    status: booking.status,
    paymentStatus: booking.paymentStatus,
    paymentStatus: normalizePaymentStatus(booking.paymentStatus ?? (booking.paid ? "paid" : "due")),
    seasonPriceId: booking.seasonPriceId ?? null,
    seasonLabel: booking.seasonLabel ?? null,
    hourlyRate: booking.hourlyRate ?? null,
    amount: booking.amount ?? booking.amountDue ?? null,
    deleted: Boolean(booking.deleted),
    Deleted: booking.deleted ? 1 : 0,
    bulkOperationId: booking.bulkOperationId ?? null,
    reservationGroupId: booking.reservationGroupId ?? null,
    createdDT: booking.createdDT ?? booking.createdAt?.toISOString?.() ?? null,
    updatedDT: booking.updatedDT ?? booking.updatedAt?.toISOString?.() ?? null
  };
}

function normalizeStoredBooking(booking) {
  const paymentStatus = normalizePaymentStatus(booking.paymentStatus ?? (booking.paid ? "paid" : "due"));
  return {
    ...booking,
    paymentStatus,
    hourlyRate: booking.hourlyRate == null ? null : Number(booking.hourlyRate),
    amount: booking.amount == null && booking.amountDue == null ? null : Number(booking.amount ?? booking.amountDue),
    reservationGroupId: booking.reservationGroupId ?? null,
    deleted: Boolean(booking.deleted ?? booking.Deleted),
    start: parseDate(booking.start, "booking.start"),
    end: parseDate(booking.end, "booking.end"),
    createdAt: booking.createdAt ? parseDate(booking.createdAt, "booking.createdAt") : null,
    updatedAt: booking.updatedAt ? parseDate(booking.updatedAt, "booking.updatedAt") : null
  };
}

function calculateAmount(hourlyRate, durationMinutes) {
  return hourlyRate == null ? null : Number(hourlyRate) * (Number(durationMinutes) / 60);
}

function isBookingPaid(booking) {
  return normalizePaymentStatus(booking.paymentStatus ?? (booking.paid ? "paid" : "due")) === "paid";
}
