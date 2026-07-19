import { SchedulingService } from "./scheduler.js";
import {
  COURTS,
  approvedMember,
  buildHourlySlots,
  formatClock,
  formatResource,
  formatTimeRange,
  getSlotAvailability,
  guestUser,
  submitReservation
} from "./booking-flow-state.js";

const scheduler = new SchedulingService({
  bookings: [
    seededCourtBooking("court-1", "2026-06-01T10:00:00-04:00", "2026-06-01T12:00:00-04:00"),
    seededCourtBooking("court-3", "2026-06-01T13:00:00-04:00", "2026-06-01T15:00:00-04:00"),
    seededCourtBooking("court-5", "2026-06-01T18:00:00-04:00", "2026-06-01T20:00:00-04:00"),
    seededTrainerBooking("2026-06-01T11:00:00-04:00", "2026-06-01T13:00:00-04:00")
  ],
  fixedReservations: [
    {
      id: "junior-league",
      resourceType: "court",
      courtId: "court-2",
      daysOfWeek: [1, 3],
      startDate: "2026-06-01",
      endDate: "2026-08-31",
      startTime: "18:00",
      endTime: "20:00"
    }
  ],
  closures: [
    {
      id: "court-9-service",
      resourceType: "court",
      courtId: "court-9",
      start: "2026-06-01T14:00:00-04:00",
      end: "2026-06-01T16:00:00-04:00",
      reason: "Maintenance"
    }
  ]
});

const state = {
  viewer: approvedMember,
  dateKey: "2026-06-01",
  durationHours: 1,
  resourceType: "court",
  courtId: "",
  selectedSlot: null,
  status: "Choose an available time to request a reservation."
};

const elements = {
  accountStatus: document.querySelector("#accountStatus"),
  sessionToggle: document.querySelector("#sessionToggle"),
  bookingDate: document.querySelector("#bookingDate"),
  durationHours: document.querySelector("#durationHours"),
  courtSelect: document.querySelector("#courtSelect"),
  courtMode: document.querySelector("#courtMode"),
  trainerMode: document.querySelector("#trainerMode"),
  slotHeading: document.querySelector("#slotHeading"),
  availabilitySummary: document.querySelector("#availabilitySummary"),
  slotGrid: document.querySelector("#slotGrid"),
  requestTitle: document.querySelector("#requestTitle"),
  requestMeta: document.querySelector("#requestMeta"),
  bookingStatus: document.querySelector("#bookingStatus"),
  reserveButton: document.querySelector("#reserveButton"),
  bookingCount: document.querySelector("#bookingCount"),
  bookingList: document.querySelector("#bookingList")
};

for (const courtId of COURTS) {
  const option = document.createElement("option");
  option.value = courtId;
  option.textContent = `Court ${courtId.replace("court-", "")}`;
  elements.courtSelect.appendChild(option);
}

elements.bookingDate.addEventListener("change", (event) => {
  state.dateKey = event.target.value;
  state.selectedSlot = null;
  render();
});

elements.durationHours.addEventListener("change", (event) => {
  state.durationHours = Number(event.target.value);
  state.selectedSlot = null;
  render();
});

elements.courtSelect.addEventListener("change", (event) => {
  state.courtId = event.target.value;
  state.selectedSlot = null;
  render();
});

elements.courtMode.addEventListener("click", () => setResourceType("court"));
elements.trainerMode.addEventListener("click", () => setResourceType("trainer"));

elements.sessionToggle.addEventListener("click", () => {
  state.viewer = state.viewer.authenticated ? guestUser : approvedMember;
  state.selectedSlot = null;
  state.status = state.viewer.authenticated
    ? "Approved account restored. Choose a slot to reserve."
    : "Guest mode blocks reservation requests.";
  render();
});

elements.reserveButton.addEventListener("click", () => {
  if (!state.selectedSlot) {
    return;
  }

  const result = submitReservation(scheduler, state.selectedSlot, {
    viewer: state.viewer,
    durationHours: state.durationHours,
    resourceType: state.resourceType,
    courtId: state.courtId
  });

  state.status = result.message;
  if (result.ok) {
    state.selectedSlot = null;
  }
  render();
});

render();

function setResourceType(resourceType) {
  state.resourceType = resourceType;
  state.selectedSlot = null;
  elements.courtSelect.disabled = resourceType === "trainer";
  render();
}

function render() {
  const slots = buildHourlySlots(state.dateKey, state.durationHours);
  const slotModels = slots.map((slot) => ({
    slot,
    availability: getSlotAvailability(scheduler, slot, {
      viewer: state.viewer,
      resourceType: state.resourceType,
      courtId: state.courtId
    })
  }));
  const openCount = slotModels.filter((model) => model.availability.available).length;

  elements.accountStatus.textContent = state.viewer.authenticated ? "Approved member" : "Guest";
  elements.accountStatus.classList.toggle("is-guest", !state.viewer.authenticated);
  elements.sessionToggle.textContent = state.viewer.authenticated ? "Use guest" : "Use approved account";

  elements.courtMode.classList.toggle("is-active", state.resourceType === "court");
  elements.trainerMode.classList.toggle("is-active", state.resourceType === "trainer");
  elements.courtMode.setAttribute("aria-pressed", String(state.resourceType === "court"));
  elements.trainerMode.setAttribute("aria-pressed", String(state.resourceType === "trainer"));

  elements.slotHeading.textContent = `${state.durationHours} hour ${state.resourceType} slots`;
  elements.availabilitySummary.textContent = `${openCount} open`;
  renderSlots(slotModels);
  renderRequest();
  renderBookings();
}

function renderSlots(slotModels) {
  elements.slotGrid.replaceChildren(
    ...slotModels.map(({ slot, availability }) => {
      const button = document.createElement("button");
      const selected = state.selectedSlot?.start === slot.start;

      button.type = "button";
      button.className = `slot-button ${availability.available ? "is-open" : "is-closed"}${selected ? " is-selected" : ""}`;
      button.disabled = !availability.available;
      button.setAttribute("aria-pressed", String(selected));
      button.innerHTML = `
        <span>${formatClock(slot.startTime)}</span>
        <small>${availability.label}</small>
      `;
      button.addEventListener("click", () => {
        state.selectedSlot = slot;
        state.status = state.viewer.authenticated
          ? "Reservation request ready."
          : "Sign in with an approved account before requesting this slot.";
        render();
      });

      return button;
    })
  );
}

function renderRequest() {
  const selectedSlot = state.selectedSlot;
  elements.bookingStatus.textContent = state.status;
  elements.bookingStatus.classList.toggle("is-warning", !state.viewer.authenticated);

  if (!selectedSlot) {
    elements.requestTitle.textContent = "No slot selected";
    elements.requestMeta.textContent = "Choose an available time to prepare a reservation.";
    elements.reserveButton.disabled = true;
    return;
  }

  const availability = getSlotAvailability(scheduler, selectedSlot, {
    viewer: state.viewer,
    resourceType: state.resourceType,
    courtId: state.courtId
  });

  elements.requestTitle.textContent = `${state.resourceType === "trainer" ? "Trainer" : "Court"} request`;
  elements.requestMeta.textContent = `${formatTimeRange(selectedSlot)} on ${state.dateKey}. ${availability.label}.`;
  elements.reserveButton.disabled = !availability.available || !state.viewer.authenticated;
}

function renderBookings() {
  let bookings = [];
  if (state.viewer.authenticated) {
    bookings = scheduler.listUserBookings(state.viewer.id, state.viewer);
  }

  elements.bookingCount.textContent = String(bookings.length);
  if (bookings.length === 0) {
    elements.bookingList.innerHTML = '<div class="empty-state">No reservations yet.</div>';
    return;
  }

  elements.bookingList.replaceChildren(
    ...bookings.map((booking) => {
      const item = document.createElement("article");
      item.className = "booking-item";
      const start = new Date(booking.start);
      const end = new Date(booking.end);
      item.innerHTML = `
        <strong>${formatResource(booking)}</strong>
        <span>${start.toLocaleDateString("en-US", { month: "short", day: "numeric" })}, ${start.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })}-${end.toLocaleTimeString("en-US", { hour: "numeric", minute: "2-digit" })}</span>
        <em>${booking.status} / ${booking.paymentStatus}</em>
      `;
      return item;
    })
  );
}

function seededCourtBooking(courtId, start, end) {
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

function seededTrainerBooking(start, end) {
  return {
    id: `trainer-${start}`,
    userId: "seed-user",
    teamId: null,
    resourceType: "trainer",
    courtId: null,
    start: new Date(start),
    end: new Date(end),
    status: "confirmed",
    paymentStatus: "paid"
  };
}
