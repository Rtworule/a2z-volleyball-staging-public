import { SchedulingService } from "./scheduler.js";

const COURT_COUNT = 9;
const TRAINER_CAPACITY = 2;
const WEEKDAY_HOURS = { open: "10:00", close: "23:00" };
const WEEKEND_HOURS = { open: "08:00", close: "21:00" };
const VIEWER = { id: "demo-user", authenticated: true, approved: true, role: "user" };

const seededBookings = [
  courtBooking("court-1", "2026-06-01T10:00:00-04:00", "2026-06-01T12:00:00-04:00"),
  courtBooking("court-3", "2026-06-01T13:00:00-04:00", "2026-06-01T15:00:00-04:00"),
  courtBooking("court-5", "2026-06-01T18:00:00-04:00", "2026-06-01T20:00:00-04:00"),
  courtBooking("court-8", "2026-06-01T20:00:00-04:00", "2026-06-01T22:00:00-04:00"),
  trainerBooking("2026-06-01T11:00:00-04:00", "2026-06-01T13:00:00-04:00"),
  trainerBooking("2026-06-01T12:00:00-04:00", "2026-06-01T14:00:00-04:00"),
  trainerBooking("2026-06-01T17:00:00-04:00", "2026-06-01T18:00:00-04:00")
];

const fixedReservations = [
  {
    id: "season-team-a",
    resourceType: "court",
    courtId: "court-2",
    daysOfWeek: [1, 3],
    startDate: "2026-06-01",
    endDate: "2026-08-31",
    startTime: "18:00",
    endTime: "20:00"
  }
];

const closures = [
  {
    id: "maintenance",
    resourceType: "court",
    courtId: "court-9",
    start: "2026-06-01T14:00:00-04:00",
    end: "2026-06-01T16:00:00-04:00",
    reason: "Maintenance"
  }
];

const scheduler = new SchedulingService({
  bookings: seededBookings,
  fixedReservations,
  closures
});

const state = {
  selectedDate: "2026-06-01",
  durationHours: 1
};

const calendar = document.querySelector("[data-calendar]");
const dateInput = document.querySelector("[data-date-input]");
const durationSelect = document.querySelector("[data-duration-select]");
const summary = document.querySelector("[data-summary]");
const weekdayHours = document.querySelector("[data-weekday-hours]");
const weekendHours = document.querySelector("[data-weekend-hours]");

dateInput.value = state.selectedDate;
durationSelect.value = String(state.durationHours);
weekdayHours.textContent = `${formatDisplayTime(WEEKDAY_HOURS.open)}-${formatDisplayTime(WEEKDAY_HOURS.close)}`;
weekendHours.textContent = `${formatDisplayTime(WEEKEND_HOURS.open)}-${formatDisplayTime(WEEKEND_HOURS.close)}`;

dateInput.addEventListener("change", (event) => {
  state.selectedDate = event.target.value;
  render();
});

durationSelect.addEventListener("change", (event) => {
  state.durationHours = Number(event.target.value);
  render();
});

render();

function render() {
  const resources = [
    ...Array.from({ length: COURT_COUNT }, (_, index) => ({
      id: `court-${index + 1}`,
      label: `Court ${index + 1}`,
      type: "court"
    })),
    { id: "trainer", label: "Gym Trainers", type: "trainer" }
  ];
  const slots = buildTimeSlots(state.selectedDate, state.durationHours);

  calendar.replaceChildren();
  calendar.style.setProperty("--slot-count", String(slots.length));

  calendar.appendChild(cell("calendar__corner", "Resource"));
  for (const slot of slots) {
    const header = cell("calendar__time", formatDisplayTime(slot.startTime));
    header.title = `${formatDisplayTime(slot.startTime)} to ${formatDisplayTime(slot.endTime)}`;
    calendar.appendChild(header);
  }

  let openCourtSlots = 0;
  let openTrainerSlots = 0;

  for (const resource of resources) {
    calendar.appendChild(resourceHeader(resource));

    for (const slot of slots) {
      const availability = availabilityFor(resource, slot);
      const button = slotButton(resource, slot, availability);

      if (resource.type === "court" && availability.available) {
        openCourtSlots += 1;
      }
      if (resource.type === "trainer") {
        openTrainerSlots += availability.availableSlots;
      }

      calendar.appendChild(button);
    }
  }

  summary.textContent = `${openCourtSlots} open court slots and ${openTrainerSlots} trainer openings for ${formatLongDate(state.selectedDate)}.`;
}

function buildTimeSlots(dateKey, durationHours) {
  const day = new Date(`${dateKey}T12:00:00`);
  const hours = [0, 6].includes(day.getDay()) ? WEEKEND_HOURS : WEEKDAY_HOURS;
  const open = timeToMinutes(hours.open);
  const close = timeToMinutes(hours.close);
  const duration = durationHours * 60;
  const slots = [];

  for (let minute = open; minute + duration <= close; minute += 60) {
    slots.push({
      start: localIso(dateKey, minute),
      end: localIso(dateKey, minute + duration),
      startTime: minutesToTime(minute),
      endTime: minutesToTime(minute + duration)
    });
  }

  return slots;
}

function availabilityFor(resource, slot) {
  const availability = scheduler.getAvailability({
    start: slot.start,
    end: slot.end,
    viewer: VIEWER
  });

  if (resource.type === "trainer") {
    return availability.trainer;
  }

  return availability.courts.find((court) => court.courtId === resource.id);
}

function slotButton(resource, slot, availability) {
  const button = document.createElement("button");
  const isTrainer = resource.type === "trainer";
  const trainerFull = isTrainer && availability.availableSlots === 0;
  const statusLabel = availability.available ? "Available" : "Booked";

  button.type = "button";
  button.className = `calendar__slot ${availability.available ? "is-open" : "is-booked"}`;
  button.disabled = !availability.available;
  button.setAttribute("aria-label", `${resource.label}, ${formatDisplayTime(slot.startTime)} to ${formatDisplayTime(slot.endTime)}, ${statusLabel}`);

  if (isTrainer) {
    button.innerHTML = `
      <span>${trainerFull ? "Full" : `${availability.availableSlots}/${TRAINER_CAPACITY}`}</span>
      <small>trainers</small>
    `;
  } else {
    button.innerHTML = `
      <span>${availability.available ? "Open" : "Busy"}</span>
      <small>${formatDisplayTime(slot.startTime)}</small>
    `;
  }

  return button;
}

function resourceHeader(resource) {
  const wrapper = document.createElement("div");
  wrapper.className = "calendar__resource";
  wrapper.innerHTML = `
    <span>${resource.label}</span>
    <small>${resource.type === "trainer" ? "2 trainer capacity" : "Volleyball"}</small>
  `;
  return wrapper;
}

function cell(className, text) {
  const element = document.createElement("div");
  element.className = className;
  element.textContent = text;
  return element;
}

function courtBooking(courtId, start, end) {
  return {
    id: `${courtId}-${start}`,
    userId: "seed-user",
    teamId: null,
    resourceType: "court",
    courtId,
    start: new Date(start),
    end: new Date(end),
    status: "confirmed",
    paymentStatus: "paid"
  };
}

function trainerBooking(start, end) {
  return {
    id: `trainer-${start}`,
    userId: "seed-user",
    teamId: null,
    resourceType: "trainer",
    courtId: null,
    start: new Date(start),
    end: new Date(end),
    status: "confirmed",
    paymentStatus: "due"
  };
}

function localIso(dateKey, minutes) {
  return `${dateKey}T${minutesToTime(minutes)}:00-04:00`;
}

function timeToMinutes(time) {
  const [hour, minute] = time.split(":").map(Number);
  return hour * 60 + minute;
}

function minutesToTime(totalMinutes) {
  const hour = Math.floor(totalMinutes / 60);
  const minute = totalMinutes % 60;
  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

function formatDisplayTime(time) {
  const [hour, minute] = time.split(":").map(Number);
  const suffix = hour >= 12 ? "PM" : "AM";
  const displayHour = hour % 12 || 12;
  return `${displayHour}${minute ? `:${String(minute).padStart(2, "0")}` : ""} ${suffix}`;
}

function formatLongDate(dateKey) {
  return new Intl.DateTimeFormat("en-US", {
    weekday: "long",
    month: "long",
    day: "numeric"
  }).format(new Date(`${dateKey}T12:00:00`));
}
