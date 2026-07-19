import {
  AuthorizationError,
  BookingConflictError,
  BookingValidationError
} from "./scheduler.js";

export const COURTS = Array.from({ length: 9 }, (_, index) => `court-${index + 1}`);
export const DEFAULT_HOURS = {
  weekday: { open: "10:00", close: "23:00" },
  weekend: { open: "08:00", close: "21:00" }
};
const TIMEZONE = "America/New_York";

export const approvedMember = {
  id: "member-1",
  authenticated: true,
  approved: true,
  role: "user",
  name: "Avery Stone"
};

export const pendingMember = {
  id: "member-pending",
  authenticated: true,
  approved: false,
  role: "user",
  name: "Pending Member"
};

export const guestUser = {
  id: "guest",
  authenticated: false,
  approved: false,
  role: "guest",
  name: "Guest"
};

export function buildHourlySlots(dateKey, durationHours, hours = DEFAULT_HOURS) {
  validateDurationChoice(durationHours);

  const dayHours = [0, 6].includes(dayOfWeekFromDateKey(dateKey)) ? hours.weekend : hours.weekday;
  const openMinutes = timeToMinutes(dayHours.open);
  const closeMinutes = timeToMinutes(dayHours.close);
  const durationMinutes = Number(durationHours) * 60;
  const slots = [];

  for (let minute = openMinutes; minute + durationMinutes <= closeMinutes; minute += 60) {
    slots.push({
      startTime: minutesToTime(minute),
      endTime: minutesToTime(minute + durationMinutes),
      start: localIso(dateKey, minute),
      end: localIso(dateKey, minute + durationMinutes)
    });
  }

  return slots;
}

export function getSlotAvailability(scheduler, slot, options) {
  const availability = scheduler.getAvailability({
    start: slot.start,
    end: slot.end,
    viewer: options.viewer
  });

  if (options.resourceType === "trainer") {
    return {
      available: availability.trainer.available,
      label: availability.trainer.available
        ? `${availability.trainer.availableSlots} trainer opening${availability.trainer.availableSlots === 1 ? "" : "s"}`
        : "Trainer full"
    };
  }

  const court = options.courtId
    ? availability.courts.find((candidate) => candidate.courtId === options.courtId)
    : availability.courts.find((candidate) => candidate.available);

  return {
    available: Boolean(court?.available),
    courtId: court?.courtId ?? options.courtId ?? null,
    label: court?.available ? `${formatCourt(court.courtId)} open` : "No court open"
  };
}

export function createReservationRequest(slot, options) {
  validateDurationChoice(options.durationHours);

  return {
    resourceType: options.resourceType,
    courtId: options.resourceType === "court" ? options.courtId || undefined : undefined,
    userId: options.viewer?.id,
    start: slot.start,
    end: slot.end,
    paymentStatus: "due"
  };
}

export function canViewerReserve(viewer) {
  return Boolean(viewer?.authenticated && (viewer.approved || viewer.role === "admin"));
}

export function accountStatusLabel(viewer) {
  if (!viewer?.authenticated) {
    return "Guest";
  }

  if (canViewerReserve(viewer)) {
    return viewer.role === "admin" ? "Admin" : "Approved member";
  }

  return "Pending approval";
}

export function submitReservation(scheduler, slot, options) {
  try {
    const booking = scheduler.createBooking(createReservationRequest(slot, options), options.viewer);
    return {
      ok: true,
      booking,
      message: `${formatResource(booking)} reserved for ${formatTimeRange(slot)}.`
    };
  } catch (error) {
    return {
      ok: false,
      error,
      message: bookingErrorMessage(error)
    };
  }
}

export function bookingErrorMessage(error) {
  if (error instanceof AuthorizationError) {
    return "Sign in with an approved account before requesting a reservation.";
  }

  if (error instanceof BookingConflictError) {
    return error.message;
  }

  if (error instanceof BookingValidationError) {
    return error.message;
  }

  return "The reservation could not be completed.";
}

export function formatCourt(courtId) {
  return `Court ${courtId.replace("court-", "")}`;
}

export function formatTimeRange(slot) {
  return `${formatClock(slot.startTime)}-${formatClock(slot.endTime)}`;
}

export function formatClock(time) {
  const [hourText, minuteText] = time.split(":");
  const hour = Number(hourText);
  const suffix = hour >= 12 ? "PM" : "AM";
  const displayHour = hour % 12 || 12;
  return `${displayHour}:${minuteText} ${suffix}`;
}

export function formatResource(booking) {
  return booking.resourceType === "trainer" ? "Trainer session" : formatCourt(booking.courtId);
}

function validateDurationChoice(durationHours) {
  const duration = Number(durationHours);
  if (!Number.isInteger(duration) || duration < 1 || duration > 4) {
    throw new BookingValidationError("Select a booking duration from 1 to 4 hours");
  }
}

function timeToMinutes(time) {
  const [hours, minutes] = time.split(":").map(Number);
  return hours * 60 + minutes;
}

function minutesToTime(minutes) {
  const hour = Math.floor(minutes / 60);
  const minute = minutes % 60;
  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

function dayOfWeekFromDateKey(dateKey) {
  const [year, month, day] = dateKey.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day, 12)).getUTCDay();
}

function localIso(dateKey, minutes) {
  const hours = Math.floor(minutes / 60);
  const mins = minutes % 60;
  const desiredUtc = Date.UTC(
    Number(dateKey.slice(0, 4)),
    Number(dateKey.slice(5, 7)) - 1,
    Number(dateKey.slice(8, 10)),
    hours,
    mins
  );
  const utcGuess = new Date(desiredUtc);
  const parts = zonedParts(utcGuess);
  const zonedAsUtc = Date.UTC(
    Number(parts.year),
    Number(parts.month) - 1,
    Number(parts.day),
    Number(parts.hour),
    Number(parts.minute)
  );
  return new Date(utcGuess.getTime() - (zonedAsUtc - desiredUtc)).toISOString();
}

function zonedParts(date) {
  const formatter = new Intl.DateTimeFormat("en-US", {
    timeZone: TIMEZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23"
  });
  return Object.fromEntries(formatter.formatToParts(date).map((part) => [part.type, part.value]));
}
