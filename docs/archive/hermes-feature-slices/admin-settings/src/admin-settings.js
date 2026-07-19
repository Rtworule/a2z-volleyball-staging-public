import {
  COURTS,
  DAY_LABELS,
  addClosure,
  addFixedReservation,
  createDefaultAdminSettings,
  formatCurrency,
  formatDayList,
  removeClosure,
  removeFixedReservation,
  summarizeAdminSettings,
  toSchedulerOptions,
  updateOperatingHours,
  updatePricing
} from "./admin-settings-state.js";

const admin = { id: "admin-1", role: "admin" };

let settings = createDefaultAdminSettings({
  closures: [{
    id: "memorial-day",
    resourceType: "all",
    courtId: null,
    start: "2026-05-25T00:00:00-04:00",
    end: "2026-05-26T00:00:00-04:00",
    reason: "Memorial Day"
  }],
  fixedReservations: [{
    id: "club-league",
    title: "Club league",
    resourceType: "court",
    courtId: "court-4",
    daysOfWeek: [2, 4],
    startDate: "2026-06-01",
    endDate: "2026-08-31",
    startTime: "18:00",
    endTime: "20:00"
  }]
});

const elements = {
  hoursGrid: document.querySelector("[data-hours-grid]"),
  closureList: document.querySelector("[data-closure-list]"),
  reservationList: document.querySelector("[data-reservation-list]"),
  closureForm: document.querySelector("[data-closure-form]"),
  reservationForm: document.querySelector("[data-reservation-form]"),
  pricingForm: document.querySelector("[data-pricing-form]"),
  status: document.querySelector("[data-status]"),
  summaryOpenDays: document.querySelector("[data-summary-open-days]"),
  summaryClosures: document.querySelector("[data-summary-closures]"),
  summaryFixed: document.querySelector("[data-summary-fixed]"),
  summaryRates: document.querySelector("[data-summary-rates]"),
  schedulerPreview: document.querySelector("[data-scheduler-preview]")
};

for (const select of document.querySelectorAll("[data-court-options]")) {
  select.append(...COURTS.map((courtId) => {
    const option = document.createElement("option");
    option.value = courtId;
    option.textContent = `Court ${courtId.replace("court-", "")}`;
    return option;
  }));
}

render();

elements.pricingForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const form = new FormData(elements.pricingForm);
  applyChange(() => {
    settings = updatePricing(settings, {
      courtHourlyRate: form.get("courtHourlyRate"),
      trainerHourlyRate: form.get("trainerHourlyRate"),
      fixedReservationDeposit: form.get("fixedReservationDeposit")
    }, admin);
  }, "Pricing updated.");
});

elements.closureForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const form = new FormData(elements.closureForm);
  applyChange(() => {
    settings = addClosure(settings, {
      resourceType: form.get("resourceType"),
      courtId: form.get("courtId") || null,
      start: form.get("start"),
      end: form.get("end"),
      reason: form.get("reason")
    }, admin);
  }, "Closure added.");
  elements.closureForm.reset();
});

elements.reservationForm.addEventListener("submit", (event) => {
  event.preventDefault();
  const form = new FormData(elements.reservationForm);
  applyChange(() => {
    settings = addFixedReservation(settings, {
      title: form.get("title"),
      resourceType: form.get("resourceType"),
      courtId: form.get("courtId") || null,
      daysOfWeek: form.getAll("daysOfWeek"),
      startDate: form.get("startDate"),
      endDate: form.get("endDate"),
      startTime: form.get("startTime"),
      endTime: form.get("endTime"),
      capacity: form.get("capacity")
    }, admin);
  }, "Fixed reservation added.");
  elements.reservationForm.reset();
});

elements.closureList.addEventListener("click", (event) => {
  const button = event.target.closest("[data-remove-closure]");
  if (!button) {
    return;
  }
  applyChange(() => {
    settings = removeClosure(settings, button.dataset.removeClosure, admin);
  }, "Closure removed.");
});

elements.reservationList.addEventListener("click", (event) => {
  const button = event.target.closest("[data-remove-reservation]");
  if (!button) {
    return;
  }
  applyChange(() => {
    settings = removeFixedReservation(settings, button.dataset.removeReservation, admin);
  }, "Fixed reservation removed.");
});

function render() {
  renderHours();
  renderPricing();
  renderClosures();
  renderReservations();
  renderSummary();
}

function renderHours() {
  elements.hoursGrid.replaceChildren(
    ...DAY_LABELS.map((label, dayIndex) => {
      const hours = settings.operatingHours[dayIndex];
      const row = document.createElement("form");
      row.className = "hours-row";
      row.innerHTML = `
        <div>
          <strong>${label}</strong>
          <small>${hours.closed ? "Closed" : `${hours.open} to ${hours.close}`}</small>
        </div>
        <label>
          <span>Closed</span>
          <input type="checkbox" name="closed" ${hours.closed ? "checked" : ""}>
        </label>
        <label>
          <span>Open</span>
          <input type="time" name="open" value="${hours.open}" ${hours.closed ? "disabled" : ""}>
        </label>
        <label>
          <span>Close</span>
          <input type="time" name="close" value="${hours.close}" ${hours.closed ? "disabled" : ""}>
        </label>
        <button type="submit">Apply</button>
      `;
      row.addEventListener("change", (event) => {
        if (event.target.name === "closed") {
          row.open.disabled = event.target.checked;
          row.close.disabled = event.target.checked;
        }
      });
      row.addEventListener("submit", (event) => {
        event.preventDefault();
        applyChange(() => {
          settings = updateOperatingHours(settings, dayIndex, {
            closed: row.closed.checked,
            open: row.open.value,
            close: row.close.value
          }, admin);
        }, `${label} hours updated.`);
      });
      return row;
    })
  );
}

function renderPricing() {
  elements.pricingForm.courtHourlyRate.value = settings.pricing.courtHourlyRate;
  elements.pricingForm.trainerHourlyRate.value = settings.pricing.trainerHourlyRate;
  elements.pricingForm.fixedReservationDeposit.value = settings.pricing.fixedReservationDeposit;
}

function renderClosures() {
  elements.closureList.replaceChildren(
    ...settings.closures.map((closure) => {
      const item = document.createElement("li");
      item.className = "settings-item";
      item.innerHTML = `
        <div>
          <strong>${closure.reason}</strong>
          <span>${formatResource(closure)} | ${formatDateTime(closure.start)} to ${formatDateTime(closure.end)}</span>
        </div>
        <button type="button" data-remove-closure="${closure.id}" aria-label="Remove ${closure.reason}">Remove</button>
      `;
      return item;
    })
  );
}

function renderReservations() {
  elements.reservationList.replaceChildren(
    ...settings.fixedReservations.map((reservation) => {
      const item = document.createElement("li");
      item.className = "settings-item";
      item.innerHTML = `
        <div>
          <strong>${reservation.title}</strong>
          <span>${formatResource(reservation)} | ${formatDayList(reservation.daysOfWeek)} | ${reservation.startTime}-${reservation.endTime} | ${reservation.startDate} to ${reservation.endDate}</span>
        </div>
        <button type="button" data-remove-reservation="${reservation.id}" aria-label="Remove ${reservation.title}">Remove</button>
      `;
      return item;
    })
  );
}

function renderSummary() {
  const summary = summarizeAdminSettings(settings);
  elements.summaryOpenDays.textContent = `${summary.openDays} open / ${summary.closedDays} closed`;
  elements.summaryClosures.textContent = String(summary.closureCount);
  elements.summaryFixed.textContent = String(summary.fixedReservationCount);
  elements.summaryRates.textContent = `${formatCurrency(summary.courtHourlyRate)} court | ${formatCurrency(summary.trainerHourlyRate)} trainer`;
  elements.schedulerPreview.textContent = JSON.stringify(toSchedulerOptions(settings), null, 2);
}

function applyChange(change, successMessage) {
  try {
    change();
    setStatus(successMessage, "success");
    render();
  } catch (error) {
    setStatus(error.message, "error");
  }
}

function setStatus(message, tone) {
  elements.status.textContent = message;
  elements.status.dataset.tone = tone;
}

function formatResource(entry) {
  if (entry.resourceType === "all") {
    return "All resources";
  }
  if (entry.resourceType === "trainer") {
    return "Gym trainers";
  }
  return entry.courtId ? `Court ${entry.courtId.replace("court-", "")}` : "All courts";
}

function formatDateTime(value) {
  return new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit"
  }).format(new Date(value));
}
