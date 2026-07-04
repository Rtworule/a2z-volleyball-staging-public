export const COURTS = Array.from({ length: 9 }, (_, index) => `court-${index + 1}`);

export const DAY_LABELS = [
  "Sunday",
  "Monday",
  "Tuesday",
  "Wednesday",
  "Thursday",
  "Friday",
  "Saturday"
];

export const RESOURCE_TYPES = ["all", "court", "trainer"];

export const DEFAULT_WEEKLY_HOURS = {
  0: { open: "08:00", close: "21:00", closed: false },
  1: { open: "10:00", close: "23:00", closed: false },
  2: { open: "10:00", close: "23:00", closed: false },
  3: { open: "10:00", close: "23:00", closed: false },
  4: { open: "10:00", close: "23:00", closed: false },
  5: { open: "10:00", close: "23:00", closed: false },
  6: { open: "08:00", close: "21:00", closed: false }
};

export const DEFAULT_PRICING = {
  courtHourlyRate: 75,
  trainerHourlyRate: 110,
  fixedReservationDeposit: 250
};

export class AdminSettingsError extends Error {
  constructor(message, details = {}) {
    super(message);
    this.name = "AdminSettingsError";
    this.details = details;
  }
}

export function createDefaultAdminSettings(overrides = {}) {
  return normalizeSettings({
    operatingHours: DEFAULT_WEEKLY_HOURS,
    pricing: DEFAULT_PRICING,
    closures: [],
    fixedReservations: [],
    ...overrides
  });
}

export function normalizeSettings(settings = {}) {
  const operatingHours = {};
  for (const dayIndex of Object.keys(DEFAULT_WEEKLY_HOURS)) {
    const hours = {
      ...DEFAULT_WEEKLY_HOURS[dayIndex],
      ...(settings.operatingHours?.[dayIndex] ?? {})
    };
    operatingHours[dayIndex] = normalizeHours(hours, dayIndex);
  }

  return {
    operatingHours,
    pricing: normalizePricing(settings.pricing ?? DEFAULT_PRICING),
    closures: (settings.closures ?? []).map(normalizeClosure),
    fixedReservations: (settings.fixedReservations ?? []).map(normalizeFixedReservation)
  };
}

export function updateOperatingHours(settings, dayIndex, patch, actor) {
  assertAdmin(actor);
  const normalized = normalizeSettings(settings);
  normalized.operatingHours[dayIndex] = normalizeHours({
    ...normalized.operatingHours[dayIndex],
    ...patch
  }, dayIndex);
  return normalized;
}

export function updatePricing(settings, patch, actor) {
  assertAdmin(actor);
  const normalized = normalizeSettings(settings);
  normalized.pricing = normalizePricing({
    ...normalized.pricing,
    ...patch
  });
  return normalized;
}

export function addClosure(settings, closure, actor) {
  assertAdmin(actor);
  const normalized = normalizeSettings(settings);
  normalized.closures = [
    ...normalized.closures,
    normalizeClosure({
      ...closure,
      id: closure.id || makeId("closure")
    })
  ];
  return normalized;
}

export function updateClosure(settings, closureId, patch, actor) {
  assertAdmin(actor);
  const normalized = normalizeSettings(settings);
  let found = false;
  normalized.closures = normalized.closures.map((closure) => {
    if (closure.id !== closureId) {
      return closure;
    }
    found = true;
    return normalizeClosure({ ...closure, ...patch, id: closure.id });
  });
  if (!found) {
    throw new AdminSettingsError("Closure not found", { closureId });
  }
  return normalized;
}

export function removeClosure(settings, closureId, actor) {
  assertAdmin(actor);
  const normalized = normalizeSettings(settings);
  normalized.closures = normalized.closures.filter((closure) => closure.id !== closureId);
  return normalized;
}

export function addFixedReservation(settings, reservation, actor) {
  assertAdmin(actor);
  const normalized = normalizeSettings(settings);
  normalized.fixedReservations = [
    ...normalized.fixedReservations,
    normalizeFixedReservation({
      ...reservation,
      id: reservation.id || makeId("reservation")
    })
  ];
  return normalized;
}

export function updateFixedReservation(settings, reservationId, patch, actor) {
  assertAdmin(actor);
  const normalized = normalizeSettings(settings);
  let found = false;
  normalized.fixedReservations = normalized.fixedReservations.map((reservation) => {
    if (reservation.id !== reservationId) {
      return reservation;
    }
    found = true;
    return normalizeFixedReservation({ ...reservation, ...patch, id: reservation.id });
  });
  if (!found) {
    throw new AdminSettingsError("Fixed reservation not found", { reservationId });
  }
  return normalized;
}

export function removeFixedReservation(settings, reservationId, actor) {
  assertAdmin(actor);
  const normalized = normalizeSettings(settings);
  normalized.fixedReservations = normalized.fixedReservations.filter((reservation) => reservation.id !== reservationId);
  return normalized;
}

export function summarizeAdminSettings(settings) {
  const normalized = normalizeSettings(settings);
  const openDays = Object.values(normalized.operatingHours).filter((day) => !day.closed).length;
  const closedDays = 7 - openDays;
  const allDayClosures = normalized.closures.filter((closure) => closure.resourceType === "all").length;

  return {
    openDays,
    closedDays,
    closureCount: normalized.closures.length,
    allDayClosures,
    fixedReservationCount: normalized.fixedReservations.length,
    courtHourlyRate: normalized.pricing.courtHourlyRate,
    trainerHourlyRate: normalized.pricing.trainerHourlyRate
  };
}

export function toSchedulerOptions(settings) {
  const normalized = normalizeSettings(settings);
  return {
    operatingHours: normalized.operatingHours,
    closures: normalized.closures,
    fixedReservations: normalized.fixedReservations
  };
}

export function formatCurrency(value) {
  return new Intl.NumberFormat("en-US", {
    style: "currency",
    currency: "USD",
    maximumFractionDigits: 0
  }).format(value);
}

export function formatDayList(daysOfWeek) {
  return daysOfWeek.map((day) => DAY_LABELS[day].slice(0, 3)).join(", ");
}

function assertAdmin(actor) {
  if (actor?.role !== "admin") {
    throw new AdminSettingsError("Only admins can manage center settings");
  }
}

function normalizeHours(hours, dayIndex) {
  if (!Object.hasOwn(DEFAULT_WEEKLY_HOURS, String(dayIndex))) {
    throw new AdminSettingsError("Invalid day index", { dayIndex });
  }

  const closed = Boolean(hours.closed);
  if (closed) {
    return { open: hours.open ?? "00:00", close: hours.close ?? "00:00", closed };
  }

  validateTime(hours.open, "open");
  validateTime(hours.close, "close");
  if (timeToMinutes(hours.open) >= timeToMinutes(hours.close)) {
    throw new AdminSettingsError("Opening time must be before closing time", { dayIndex });
  }

  return { open: hours.open, close: hours.close, closed };
}

function normalizePricing(pricing) {
  return {
    courtHourlyRate: normalizeMoney(pricing.courtHourlyRate, "courtHourlyRate"),
    trainerHourlyRate: normalizeMoney(pricing.trainerHourlyRate, "trainerHourlyRate"),
    fixedReservationDeposit: normalizeMoney(pricing.fixedReservationDeposit, "fixedReservationDeposit")
  };
}

function normalizeClosure(closure) {
  const start = validateDateTime(closure.start, "closure.start");
  const end = validateDateTime(closure.end, "closure.end");
  if (start >= end) {
    throw new AdminSettingsError("Closure start must be before end");
  }

  const resourceType = normalizeResourceType(closure.resourceType ?? "all");
  return {
    id: requireText(closure.id, "closure.id"),
    resourceType,
    courtId: normalizeOptionalCourt(closure.courtId, resourceType),
    start: closure.start,
    end: closure.end,
    reason: requireText(closure.reason ?? "Closed", "closure.reason")
  };
}

function normalizeFixedReservation(reservation) {
  const resourceType = reservation.resourceType === "trainer" ? "trainer" : "court";
  const startDate = validateDate(reservation.startDate, "reservation.startDate");
  const endDate = validateDate(reservation.endDate, "reservation.endDate");
  if (startDate > endDate) {
    throw new AdminSettingsError("Reservation start date must be before end date");
  }

  validateTime(reservation.startTime, "reservation.startTime");
  validateTime(reservation.endTime, "reservation.endTime");
  if (timeToMinutes(reservation.startTime) >= timeToMinutes(reservation.endTime)) {
    throw new AdminSettingsError("Reservation start time must be before end time");
  }

  const daysOfWeek = normalizeDays(reservation.daysOfWeek);
  const normalized = {
    id: requireText(reservation.id, "reservation.id"),
    title: requireText(reservation.title ?? "Fixed reservation", "reservation.title"),
    resourceType,
    courtId: normalizeOptionalCourt(reservation.courtId, resourceType),
    daysOfWeek,
    startDate: reservation.startDate,
    endDate: reservation.endDate,
    startTime: reservation.startTime,
    endTime: reservation.endTime
  };

  if (resourceType === "trainer") {
    normalized.capacity = normalizeCapacity(reservation.capacity ?? 1);
  }

  return normalized;
}

function normalizeResourceType(resourceType) {
  if (!RESOURCE_TYPES.includes(resourceType)) {
    throw new AdminSettingsError("Unsupported resource type", { resourceType });
  }
  return resourceType;
}

function normalizeOptionalCourt(courtId, resourceType) {
  if (resourceType === "trainer" || resourceType === "all") {
    return null;
  }
  if (!courtId) {
    return null;
  }
  if (!COURTS.includes(courtId)) {
    throw new AdminSettingsError("Unknown court", { courtId });
  }
  return courtId;
}

function normalizeDays(daysOfWeek) {
  if (!Array.isArray(daysOfWeek) || daysOfWeek.length === 0) {
    throw new AdminSettingsError("Choose at least one day of the week");
  }
  const unique = [...new Set(daysOfWeek.map(Number))].sort((left, right) => left - right);
  if (unique.some((day) => !Number.isInteger(day) || day < 0 || day > 6)) {
    throw new AdminSettingsError("Invalid day of week", { daysOfWeek });
  }
  return unique;
}

function normalizeMoney(value, fieldName) {
  const amount = Number(value);
  if (!Number.isFinite(amount) || amount < 0) {
    throw new AdminSettingsError("Price must be zero or greater", { fieldName });
  }
  return amount;
}

function normalizeCapacity(value) {
  const capacity = Number(value);
  if (!Number.isInteger(capacity) || capacity < 1 || capacity > 2) {
    throw new AdminSettingsError("Trainer capacity reservation must be 1 or 2");
  }
  return capacity;
}

function requireText(value, fieldName) {
  if (typeof value !== "string" || value.trim().length === 0) {
    throw new AdminSettingsError("Required text is missing", { fieldName });
  }
  return value.trim();
}

function validateTime(value, fieldName) {
  if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(value ?? "")) {
    throw new AdminSettingsError("Time must use HH:mm format", { fieldName });
  }
}

function validateDate(value, fieldName) {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value ?? "")) {
    throw new AdminSettingsError("Date must use YYYY-MM-DD format", { fieldName });
  }
  return new Date(`${value}T00:00:00Z`);
}

function validateDateTime(value, fieldName) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) {
    throw new AdminSettingsError("Date and time are invalid", { fieldName });
  }
  return date;
}

function timeToMinutes(time) {
  const [hours, minutes] = time.split(":").map(Number);
  return hours * 60 + minutes;
}

function makeId(prefix) {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}`;
}
