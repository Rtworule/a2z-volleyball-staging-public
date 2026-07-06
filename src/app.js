import { SchedulingService } from "./scheduler.js";
import { supabase, supabaseConfig } from "./supabaseClient.js";

const HERO_IMAGE = "/hero-court.svg";
const BALL_IMAGE = "/ball-court.svg";
const TRAINING_IMAGE = "/window-panels.svg";
const FACILITY_TIMEZONE = "America/New_York";
const DEFAULT_MESSAGE_DISPLAY_SECONDS = 5;
const isLocalPreview = ["", "localhost", "127.0.0.1"].includes(window.location.hostname) || window.location.protocol === "file:";
const todayKey = todayDateKey();
const currentInvoiceMonth = todayKey.slice(0, 7);
let noticeTimer = null;
let teamCreateInFlight = false;

const defaultAdminMenuItems = [
  { key: "payments", name: "Payment Due", pageOrder: 10, isActive: true },
  { key: "invoices", name: "Invoices", pageOrder: 20, isActive: true },
  { key: "past-payments", name: "Payments", pageOrder: 30, isActive: true },
  { key: "clients", name: "Clients", pageOrder: 40, isActive: true },
  { key: "bulk-reservations", name: "Bulk Reserve", pageOrder: 50, isActive: true },
  { key: "calendar", name: "Calendar", pageOrder: 60, isActive: true },
  { key: "reports", name: "Reports", pageOrder: 70, isActive: true },
  { key: "club-seasons", name: "Club Seasons", pageOrder: 80, isActive: true },
  { key: "bulk-delete", name: "Bulk Delete", pageOrder: 90, isActive: true },
  { key: "users", name: "Users", pageOrder: 95, isActive: true },
  { key: "settings", name: "Settings", pageOrder: 100, isActive: true }
];

const demoUsers = [
  {
    id: "member-1",
    username: "member",
    email: "member@a2z.local",
    password: "A2zMember1",
    authenticated: true,
    approved: true,
    role: "user",
    name: "Jordan Lee"
  },
  {
    id: "pending-1",
    username: "pending",
    email: "pending@a2z.local",
    password: "A2zPending1",
    authenticated: true,
    approved: false,
    role: "user",
    name: "Sam Patel"
  },
  {
    id: "admin-1",
    username: "owner",
    email: "owner@a2z.local",
    password: "A2zOwner1",
    authenticated: true,
    approved: true,
    role: "admin",
    name: "Maya Rivera"
  }
];

const defaultSettings = {
  courtCount: 9,
  trainerCapacity: 2,
  slotIntervalMinutes: 30,
  minBookingMinutes: 60,
  messageDisplaySeconds: DEFAULT_MESSAGE_DISPLAY_SECONDS,
  adminEmail: "admin@a2zvolleyball.local",
  emailTemplates: {
    reservationReminder: {
      subject: "Reservation reminder for <teamname>",
      body: "Hi <teamname>,\n\nThis is a reminder for your reservation on <reservationdate> from <starttime> to <endtime> on <courts>.\n\nA to Z Volleyball Center"
    },
    invoice: {
      subject: "Invoice <invoicenumber> for <teamname>",
      body: "Hi <teamname>,\n\nYour invoice <invoicenumber> for <amountdue> is ready.\n\nA to Z Volleyball Center"
    }
  },
  pricing: {
    courtHourlyRate: 75,
    gymHourlyRate: 110
  },
  operatingHours: {
    0: { open: "08:00", close: "21:00", closed: false },
    1: { open: "10:00", close: "23:00", closed: false },
    2: { open: "10:00", close: "23:00", closed: false },
    3: { open: "10:00", close: "23:00", closed: false },
    4: { open: "10:00", close: "23:00", closed: false },
    5: { open: "10:00", close: "23:00", closed: false },
    6: { open: "08:00", close: "21:00", closed: false }
  },
  closures: [
    {
      id: "maintenance",
      resourceType: "court",
      courtId: "court-7",
      start: "2026-06-01T15:00:00-04:00",
      end: "2026-06-01T18:00:00-04:00",
      reason: "Floor maintenance"
    }
  ],
  fixedReservations: [
    {
      id: "season-14u",
      resourceType: "court",
      courtId: "court-4",
      daysOfWeek: [1, 3],
      startDate: "2026-06-01",
      endDate: "2026-08-31",
      startTime: "18:00",
      endTime: "20:00"
    },
    {
      id: "trainer-block",
      resourceType: "trainer",
      daysOfWeek: [1],
      startDate: "2026-06-01",
      endDate: "2026-07-31",
      startTime: "19:00",
      endTime: "20:00",
      capacity: 1
    }
  ]
};

const state = {
  view: currentView(),
  user: null,
  loginMode: "password",
  loginId: "",
  loginPassword: "",
  signupForm: {
    email: "",
    password: "",
    username: "",
    displayName: "",
    teamName: ""
  },
  date: "2026-06-01",
  time: "18:00",
  memberPortalLoadedFrom: null,
  memberContexts: [],
  myReservations: [],
  bookingContextKey: "",
  lessonBracket: "1-2",
  bracketPrices: [],
  resetPasswordValue: "",
  editingReservationId: null,
  durationMinutes: 120,
  resourceType: "court",
  selectedCourt: "court-3",
  bookingSubjectId: "",
  bookingSubjectTeamId: "",
  bookingSeasonPriceId: "",
  notice: "",
  settings: structuredClone(defaultSettings),
  adminTab: "payments",
  adminAllMenuItems: defaultAdminMenuItems.map((item) => ({ ...item })),
  adminMenuItems: defaultAdminMenuItems.map((item) => ({ ...item })),
  adminMenuRights: [],
  settingsTab: "configuration",
  invoiceFilters: {
    subjectId: "",
    type: "",
    year: currentInvoiceMonth.slice(0, 4),
    month: currentInvoiceMonth.slice(5, 7),
    sortBy: "createdAt",
    sortDirection: "desc"
  },
  reportFilters: {
    subjectId: "",
    startDate: todayDateKey(),
    endDate: todayDateKey()
  },
  report: null,
  allUsers: demoUsers.map((user) => ({ ...user, approvalStatus: user.approved ? "approved" : "pending" })),
  pendingUsers: demoUsers.filter((user) => user.authenticated && !user.approved),
  bookings: [
    {
      id: "booking-301",
      userId: "member-1",
      teamId: "Riverside 16U",
      resourceType: "court",
      courtId: "court-1",
      start: "2026-06-01T17:00:00-04:00",
      end: "2026-06-01T19:00:00-04:00",
      status: "confirmed",
      paymentStatus: "paid",
      amount: 150,
      deleted: false
    },
    {
      id: "booking-302",
      userId: "team-storm",
      teamId: "Storm Elite",
      resourceType: "court",
      courtId: "court-5",
      start: "2026-06-01T18:00:00-04:00",
      end: "2026-06-01T20:00:00-04:00",
      status: "confirmed",
      paymentStatus: "due",
      amount: 150,
      deleted: false
    },
    {
      id: "booking-303",
      userId: "member-1",
      teamId: null,
      resourceType: "trainer",
      courtId: null,
      start: "2026-06-01T18:30:00-04:00",
      end: "2026-06-01T19:30:00-04:00",
      status: "confirmed",
      paymentStatus: "due",
      amount: 110,
      deleted: false
    },
    {
      id: "booking-304",
      userId: "academy-12",
      teamId: "Northside 14U",
      resourceType: "court",
      courtId: "court-8",
      start: "2026-06-01T20:00:00-04:00",
      end: "2026-06-01T22:00:00-04:00",
      status: "confirmed",
      paymentStatus: "due",
      amount: 150,
      deleted: false
    }
  ],
  adminSubjects: [
    {
      id: "subject-team-storm",
      subjectType: "Club",
      clientTypeName: "Club",
      clientTypeHaveTeams: true,
      displayName: "Storm Elite",
      shortName: "Storm",
      contactName: "",
      contactEmail: "storm@example.com",
      contactPhone: "",
      notes: "Temporary team record",
      teams: [{ id: "team-storm-16u", subjectId: "subject-team-storm", name: "Storm Elite 16U", shortName: "Storm 16U", deleted: false }],
      deleted: false
    },
    {
      id: "subject-coach-a2z",
      subjectType: "Coach",
      clientTypeName: "Coach",
      clientTypeHaveTeams: false,
      displayName: "Coach rental",
      shortName: "Coach",
      contactName: "",
      contactEmail: "",
      contactPhone: "",
      notes: "Temporary coach record",
      teams: [],
      deleted: false
    }
  ],
  clientTypes: [
    { id: "client-type-club", name: "Club", haveTeams: true, deleted: false },
    { id: "client-type-academy", name: "Academy", haveTeams: true, deleted: false },
    { id: "client-type-coach", name: "Coach", haveTeams: false, deleted: false },
    { id: "client-type-pickleball", name: "Pickleball", haveTeams: false, deleted: false }
  ],
  clientTypeForm: {
    name: "",
    haveTeams: false
  },
  editingClientTypeId: null,
  editClientTypeForm: {
    name: "",
    haveTeams: false
  },
  adminSubjectForm: {
    clientTypeId: "client-type-club",
    displayName: "",
    shortName: "",
    contactName: "",
    contactEmail: "",
    contactPhone: "",
    notes: ""
  },
  editingSubjectId: null,
  editSubjectForm: {
    displayName: "",
    shortName: "",
    contactEmail: "",
    contactName: "",
    contactPhone: "",
    notes: "",
    clientTypeId: "client-type-club"
  },
  teamForm: {
    name: "",
    shortName: "",
    coachName: "",
    coachEmail: "",
    coachPhone: "",
    coachSafeSport: false,
    coachBackgroundCheck: false,
    coachConcussion: false,
    clubInsuranceReceived: false
  },
  editingTeamId: null,
  editTeamForm: {
    name: "",
    shortName: "",
    coachName: "",
    coachEmail: "",
    coachPhone: "",
    coachSafeSport: false,
    coachBackgroundCheck: false,
    coachConcussion: false,
    clubInsuranceReceived: false
  },
  closureForm: {
    resourceType: "all",
    courtId: "",
    startDate: todayDateKey(),
    endDate: todayDateKey(),
    startTime: "00:00",
    endTime: "23:59",
    reason: ""
  },
  seasonForm: {
    startYear: 2026
  },
  editingSeasonId: null,
  editSeasonForm: {
    startYear: 2026,
    displayName: "2026/27"
  },
  seasonPriceForm: {
    subjectId: "subject-team-storm",
    seasonId: "season-2026",
    hourlyRate: 75,
    documentsReceived: false,
    deposit: 0
  },
  editingSeasonPriceId: null,
  editSeasonPriceForm: {
    subjectId: "",
    seasonId: "season-2026",
    hourlyRate: 0,
    documentsReceived: false,
    deposit: 0
  },
  editingUserId: null,
  editingUserRightsId: null,
  editUserForm: {
    name: "",
    role: "user"
  },
  editUserRightsForm: {},
  bulkForm: {
    subjectId: "subject-team-storm",
    subjectTeamId: "team-storm-16u",
    resourceType: "court",
    courtId: "",
    courtCountNeeded: 1,
    startDate: todayDateKey(),
    endDate: addDateDays(todayDateKey(), 30),
    startTime: "18:00",
    durationMinutes: 120,
    hourlyRate: 75,
    useSeasonPrice: true,
    daysOfWeek: [1, 2, 3, 4, 5],
    seasonPriceId: "",
    conflictResolution: "skip_conflicts",
    applyAfter: ""
  },
  bulkDeleteForm: {
    subjectId: "subject-team-storm",
    startDate: "2026-06-01",
    endDate: "2026-06-30"
  },
  bulkPreview: null,
  bulkCalendarOpen: false,
  bulkDeletePreview: [],
  bulkDeleteSkippedPaid: [],
  bulkOperations: [],
  invoices: [],
  payments: [],
  expandedPaymentKeys: [],
  expandedPastPaymentKeys: [],
  seasonPriceYearFilter: "",
  adminCalendar: {
    mode: "month",
    month: todayDateKey().slice(0, 7),
    date: todayDateKey(),
    selectedBookingId: null,
    selectedSlot: null,
    editingBookingId: null
  },
  seasons: [
    {
      id: "season-2026",
      startYear: 2026,
      displayName: "2026/27",
      deleted: false
    }
  ],
  teamSeasonPrices: [
    {
      id: "price-storm-2026",
      subjectId: "subject-team-storm",
      teamName: "Storm Elite",
      seasonId: "season-2026",
      season: "2026/27",
      seasonYear: 2026,
      seasonDisplayName: "2026/27",
      hourlyRate: 75,
      documentsReceived: false,
      deposit: 0,
      deleted: false
    }
  ]
};

window.addEventListener("hashchange", () => {
  state.view = currentView();
  ensureAllowedView();
  render();
});

document.addEventListener("click", (event) => {
  const target = event.target.closest("[data-action], [data-view], [data-admin-tab], [data-settings-tab], [data-time], [data-court], [data-social-provider]");
  if (!target) {
    return;
  }

  if (target.dataset.view) {
    setView(target.dataset.view);
  }

  if (target.dataset.adminTab && isAdminSession()) {
    state.adminTab = target.dataset.adminTab;
    render();
  }

  if (target.dataset.settingsTab && isAdminSession()) {
    state.settingsTab = target.dataset.settingsTab;
    render();
  }

  if (target.dataset.time) {
    state.time = target.dataset.time;
    render();
  }

  if (target.dataset.court && isApprovedMember()) {
    state.selectedCourt = target.dataset.court;
    state.resourceType = "court";
    setView("book");
  }

  if (target.dataset.action === "logout") {
    void signOut();
  }

  if (target.dataset.action === "book") {
    void bookSelectedSlot();
  }

  if (target.dataset.action === "cancel-reservation") {
    void cancelMyReservation(target.dataset.reservation);
  }

  if (target.dataset.action === "edit-reservation") {
    beginEditReservation(target.dataset.reservation);
  }

  if (target.dataset.action === "cancel-edit") {
    state.editingReservationId = null;
    setView("my-bookings");
  }

  if (target.dataset.action === "forgot-password") {
    void sendPasswordReset();
  }

  if (target.dataset.action === "confirm-password-reset") {
    void confirmPasswordReset();
  }

  if (target.dataset.gridTime && target.dataset.gridCourt && isApprovedMember()) {
    state.time = target.dataset.gridTime;
    if (target.dataset.gridCourt === "trainer") {
      state.resourceType = "trainer";
      state.selectedCourt = "";
    } else {
      state.resourceType = "court";
      state.selectedCourt = target.dataset.gridCourt;
    }
    setView("book");
  }

  if (target.dataset.action === "approve") {
    approvePendingUser(target.dataset.user);
  }

  if (target.dataset.action === "reject") {
    rejectUser(target.dataset.user);
  }

  if (target.dataset.action === "disable-user") {
    disableUser(target.dataset.user);
  }

  if (target.dataset.action === "enable-subject") {
    enableSubject(target.dataset.subject);
  }

  if (target.dataset.action === "edit-user") {
    startEditUser(target.dataset.user);
  }

  if (target.dataset.action === "cancel-edit-user") {
    cancelEditUser();
  }

  if (target.dataset.action === "save-user") {
    saveUser(target.dataset.user);
  }

  if (target.dataset.action === "edit-admin-rights") {
    startEditAdminRights(target.dataset.user);
  }

  if (target.dataset.action === "cancel-admin-rights") {
    cancelEditAdminRights();
  }

  if (target.dataset.action === "save-admin-rights") {
    saveAdminRights(target.dataset.user);
  }

  if (target.dataset.action === "mark-paid") {
    markBookingPaid(target.dataset.booking);
  }

  if (target.dataset.action === "mark-payment-paid") {
    markPaymentPaid(target.dataset.paymentKey);
  }

  if (target.dataset.action === "toggle-payment-panel") {
    togglePaymentPanel(target.dataset.paymentKey);
  }

  if (target.dataset.action === "toggle-past-payment-panel") {
    togglePastPaymentPanel(target.dataset.paymentKey);
  }

  if (target.dataset.action === "create-invoice") {
    createInvoiceForPayment(target.dataset.paymentKey);
  }

  if (target.dataset.action === "generate-all-invoices") {
    generateAllInvoices();
  }

  if (target.dataset.action === "calendar-mode") {
    setAdminCalendarMode(target.dataset.mode);
  }

  if (target.dataset.action === "calendar-previous") {
    moveAdminCalendar(-1);
  }

  if (target.dataset.action === "calendar-next") {
    moveAdminCalendar(1);
  }

  if (target.dataset.action === "calendar-day") {
    selectAdminCalendarDay(target.dataset.date);
  }

  if (target.dataset.action === "calendar-slot") {
    selectAdminCalendarSlot(target.dataset.date, target.dataset.time, target.dataset.court);
  }

  if (target.dataset.action === "calendar-reservation") {
    selectAdminCalendarReservation(target.dataset.booking);
  }

  if (target.dataset.action === "calendar-add-reservation") {
    addCalendarReservation();
  }

  if (target.dataset.action === "calendar-edit-reservation") {
    editCalendarReservation(target.dataset.booking);
  }

  if (target.dataset.action === "calendar-delete-reservation") {
    deleteCalendarReservation(target.dataset.booking);
  }

  if (target.dataset.action === "calendar-save-edit") {
    saveCalendarReservationEdit(target.dataset.booking);
  }

  if (target.dataset.action === "print-invoice") {
    printInvoice(target.dataset.invoice);
  }

  if (target.dataset.action === "email-invoice-admin") {
    emailInvoice(target.dataset.invoice, "admin");
  }

  if (target.dataset.action === "email-invoice-user") {
    emailInvoice(target.dataset.invoice, "user");
  }

  if (target.dataset.action === "sort-invoices") {
    sortInvoices(target.dataset.sort);
  }

  if (target.dataset.action === "create-admin-subject") {
    createAdminSubject();
  }

  if (target.dataset.action === "edit-subject") {
    startEditSubject(target.dataset.subject);
  }

  if (target.dataset.action === "cancel-edit-subject") {
    cancelEditSubject();
  }

  if (target.dataset.action === "save-subject") {
    saveSubject(target.dataset.subject);
  }

  if (target.dataset.action === "invite-subject") {
    inviteSubject(target.dataset.subject);
  }

  if (target.dataset.action === "disable-subject") {
    disableSubject(target.dataset.subject);
  }

  if (target.dataset.action === "create-client-type") {
    createClientType();
  }

  if (target.dataset.action === "edit-client-type") {
    startEditClientType(target.dataset.clientType);
  }

  if (target.dataset.action === "save-client-type") {
    saveClientType(target.dataset.clientType);
  }

  if (target.dataset.action === "cancel-edit-client-type") {
    cancelEditClientType();
  }

  if (target.dataset.action === "delete-client-type") {
    deleteClientType(target.dataset.clientType);
  }

  if (target.dataset.action === "create-subject-team") {
    createSubjectTeam(target.closest('[data-form="create-subject-team"]'));
  }

  if (target.dataset.action === "edit-subject-team") {
    startEditSubjectTeam(target.dataset.team);
  }

  if (target.dataset.action === "save-subject-team") {
    saveSubjectTeam(target.dataset.team);
  }

  if (target.dataset.action === "cancel-edit-subject-team") {
    cancelEditSubjectTeam();
  }

  if (target.dataset.action === "delete-subject-team") {
    deleteSubjectTeam(target.dataset.team);
  }

  if (target.dataset.action === "create-closure") {
    createClosure();
  }

  if (target.dataset.action === "delete-closure") {
    deleteClosure(target.dataset.closure);
  }

  if (target.dataset.action === "create-season") {
    createSeason();
  }

  if (target.dataset.action === "edit-season") {
    startEditSeason(target.dataset.season);
  }

  if (target.dataset.action === "cancel-edit-season") {
    cancelEditSeason();
  }

  if (target.dataset.action === "save-season") {
    saveSeason(target.dataset.season);
  }

  if (target.dataset.action === "delete-season") {
    deleteSeason(target.dataset.season);
  }

  if (target.dataset.action === "create-season-price") {
    createSeasonPrice();
  }

  if (target.dataset.action === "edit-season-price") {
    startEditSeasonPrice(target.dataset.price);
  }

  if (target.dataset.action === "cancel-edit-season-price") {
    cancelEditSeasonPrice();
  }

  if (target.dataset.action === "save-season-price") {
    saveSeasonPrice(target.dataset.price);
  }

  if (target.dataset.action === "delete-season-price") {
    deleteSeasonPrice(target.dataset.price);
  }

  if (target.dataset.action === "bulk-preview") {
    previewBulkReservation();
  }

  if (target.dataset.action === "bulk-apply") {
    applyBulkReservation();
  }

  if (target.dataset.action === "bulk-calendar-open") {
    state.bulkCalendarOpen = true;
    render();
  }

  if (target.dataset.action === "bulk-calendar-close") {
    state.bulkCalendarOpen = false;
    render();
  }

  if (target.dataset.action === "bulk-delete-preview") {
    previewBulkDelete();
  }

  if (target.dataset.action === "bulk-delete-apply") {
    applyBulkDelete();
  }

  if (target.dataset.action === "bulk-delete-operation") {
    deleteBulkOperation(target.dataset.operation);
  }

  if (target.dataset.action === "bulk-operation-calendar") {
    viewBulkOperationCalendar(target.dataset.operation);
  }

  if (target.dataset.action === "save-admin-settings") {
    saveAdminSettings();
  }

  if (target.dataset.action === "copy-signup-link") {
    copySignupLink();
  }

  if (target.dataset.action === "create-report") {
    createReport();
  }

  if (target.dataset.action === "print-report") {
    printReport();
  }

  if (target.dataset.action === "print-report-summary") {
    printReportSummary();
  }

  if (target.dataset.socialProvider) {
    if (shouldUseLiveAuth()) {
      void signInWithProvider(target.dataset.socialProvider.toLowerCase());
      return;
    }
    state.notice = `${target.dataset.socialProvider} sign-in is unavailable in local preview. Use email and password.`;
    setView("login");
  }
});

document.addEventListener("input", (event) => {
  const control = event.target.closest("[data-control], [data-config], [data-email-template], [data-admin-subject], [data-edit-subject], [data-client-type], [data-edit-client-type], [data-subject-team], [data-edit-subject-team], [data-closure], [data-season-record], [data-edit-season-record], [data-season-price], [data-edit-season-price], [data-season-price-filter], [data-signup], [data-edit-user], [data-admin-right], [data-admin-rights-all], [data-bulk], [data-bulk-day], [data-bulk-delete], [data-invoice-filter], [data-report-filter], [data-calendar]");
  if (!control) {
    return;
  }
  let shouldRender = control.tagName === "SELECT" || control.type === "checkbox" || control.type === "radio";

  if (control.dataset.control) {
    updateBookingControl(control);
    shouldRender = shouldRender || ["bookingSubjectId", "resourceType", "bookingContextKey", "date"].includes(control.dataset.control);
    if (control.dataset.control === "date" && shouldUseLiveAuth() && isApprovedMember()
      && state.memberPortalLoadedFrom && state.date && state.date !== state.memberPortalLoadedFrom) {
      void loadMemberPortal();
    }
  }

  if (control.dataset.config && isAdminSession()) {
    updateConfigControl(control);
  }

  if (control.dataset.emailTemplate && isAdminSession()) {
    updateEmailTemplateControl(control);
  }

  if (control.dataset.adminSubject && isAdminSession()) {
    updateAdminSubjectControl(control);
    shouldRender = shouldRender || control.dataset.adminSubject === "clientTypeId";
  }

  if (control.dataset.signup) {
    updateSignupControl(control);
  }

  if (control.dataset.editUser && isAdminSession()) {
    updateEditUserControl(control);
  }

  if (control.dataset.adminRight && isAdminSession()) {
    updateAdminRightControl(control);
  }

  if (control.dataset.adminRightsAll !== undefined && isAdminSession()) {
    updateAdminRightsAllControl(control);
  }

  if (control.dataset.editSubject && isAdminSession()) {
    updateEditSubjectControl(control);
    shouldRender = shouldRender || control.dataset.editSubject === "clientTypeId";
  }

  if (control.dataset.clientType && isAdminSession()) {
    updateClientTypeControl(control);
  }

  if (control.dataset.editClientType && isAdminSession()) {
    updateEditClientTypeControl(control);
  }

  if (control.dataset.subjectTeam && isAdminSession()) {
    updateSubjectTeamControl(control);
  }

  if (control.dataset.editSubjectTeam && isAdminSession()) {
    updateEditSubjectTeamControl(control);
  }

  if (control.dataset.closure && isAdminSession()) {
    updateClosureControl(control);
    shouldRender = shouldRender || ["resourceType", "startDate"].includes(control.dataset.closure);
  }

  if (control.dataset.seasonRecord && isAdminSession()) {
    updateSeasonControl(control);
  }

  if (control.dataset.editSeasonRecord && isAdminSession()) {
    updateEditSeasonControl(control);
  }

  if (control.dataset.seasonPrice && isAdminSession()) {
    updateSeasonPriceControl(control);
  }

  if (control.dataset.editSeasonPrice && isAdminSession()) {
    updateEditSeasonPriceControl(control);
  }

  if (control.dataset.seasonPriceFilter && isAdminSession()) {
    updateSeasonPriceFilter(control);
  }

  if (control.dataset.bulk && isAdminSession()) {
    updateBulkControl(control);
    shouldRender = shouldRender || ["subjectId", "resourceType", "useSeasonPrice"].includes(control.dataset.bulk);
  }

  if (control.dataset.bulkDay && isAdminSession()) {
    updateBulkDayControl(control);
    shouldRender = true;
  }

  if (control.dataset.bulkDelete && isAdminSession()) {
    updateBulkDeleteControl(control);
  }

  if (control.dataset.invoiceFilter && isAdminSession()) {
    updateInvoiceFilter(control);
    shouldRender = true;
  }

  if (control.dataset.reportFilter && isAdminSession()) {
    updateReportFilter(control);
    shouldRender = true;
  }

  if (control.dataset.calendar && isAdminSession()) {
    updateAdminCalendarControl(control);
    shouldRender = true;
  }

  if (shouldRender) {
    render();
  }
});

document.addEventListener("submit", (event) => {
  const form = event.target.closest("[data-form]");
  if (!form) {
    return;
  }

  event.preventDefault();
  if (form.dataset.form === "login") {
    void signIn(new FormData(form));
  }
  if (form.dataset.form === "signup") {
    void signUp(new FormData(form));
  }
  if (form.dataset.form === "create-subject-team" && isAdminSession()) {
    void createSubjectTeam(form);
  }
});

void initializeApp();

function render() {
  ensureAllowedView();
  document.querySelector("#app").innerHTML = `
    ${state.view === "admin" ? "" : renderTopbar()}
    ${state.notice ? `<div class="notice app-toast" role="status" aria-live="polite">${escapeHtml(state.notice)}</div>` : ""}
    <main class="${state.view === "admin" ? "admin-main" : ""}">
      ${renderHero()}
      ${state.view === "home" ? renderHomeView() : ""}
      ${state.view === "login" ? renderLoginView() : ""}
      ${state.view === "signup" ? renderSignupView() : ""}
      ${state.view === "reset-password" ? renderResetPasswordView() : ""}
      ${state.view === "programs" ? renderProgramsView() : ""}
      ${state.view === "schedule" ? renderScheduleView() : ""}
      ${state.view === "book" ? renderBookingView() : ""}
      ${state.view === "my-bookings" ? renderMyBookingsView() : ""}
      ${state.view === "admin" ? renderAdminView() : ""}
    </main>
    ${renderMobileNav()}
  `;
  syncAdminRightsSelectAllControl();
  scheduleNoticeClear();
}

function scheduleNoticeClear() {
  if (noticeTimer) {
    window.clearTimeout(noticeTimer);
    noticeTimer = null;
  }
  if (!state.notice) {
    return;
  }
  const seconds = Math.max(1, Number(state.settings.messageDisplaySeconds ?? DEFAULT_MESSAGE_DISPLAY_SECONDS));
  noticeTimer = window.setTimeout(() => {
    state.notice = "";
    render();
  }, seconds * 1000);
}

function renderTopbar() {
  return `
    <header class="topbar">
      <a class="brand" href="#home" aria-label="A to Z Volleyball Center home">
        <img class="brand-logo" src="/atoz-volleyball-logo.png" alt="">
        <span>
          <strong>A to Z Volleyball Center</strong>
          <small>Courts, training, teams</small>
        </span>
      </a>
      <nav class="desktop-nav" aria-label="Primary">
        ${navButton("home", "Home")}
        ${navButton("programs", "Programs")}
        ${isApprovedMember() ? navButton("schedule", "Schedule") : ""}
        ${isApprovedMember() ? navButton("book", "Reserve") : ""}
        ${isApprovedMember() ? navButton("my-bookings", "My bookings") : ""}
        ${isAdminSession() ? navButton("admin", "Admin") : ""}
      </nav>
      <div class="account-actions">
        ${state.user ? `<span class="status-pill is-open">${state.user.name}</span><button type="button" data-action="logout">Sign out</button>` : `<button type="button" class="primary-action compact" data-view="login">Log in</button>`}
      </div>
    </header>
  `;
}

function renderHero() {
  if (state.view === "admin") {
    return "";
  }

  if (isAdminSession()) {
    return `
      <section class="hero public-hero" style="--hero-image: url('${HERO_IMAGE}')">
        <div class="hero-copy">
          <p class="eyebrow">Facility controls</p>
          <h1>A to Z Volleyball Center</h1>
          <p class="hero-text">Manage rates, operating hours, court capacity, account approvals, closures, and payments from the control page.</p>
        </div>
        <div class="hero-actions">
          <button type="button" class="primary-action" data-view="admin">Open controls</button>
        </div>
      </section>
    `;
  }

  if (isApprovedMember()) {
    return `
      <section class="hero" style="--hero-image: url('${HERO_IMAGE}')">
        <div class="hero-copy">
          <p class="eyebrow">Approved member scheduling</p>
          <h1>A to Z Volleyball Center</h1>
          <p class="hero-text">Choose half-hour start times, reserve court space, and book trainer gym time in one place.</p>
        </div>
        <form class="booking-dock" aria-label="Quick booking">
          <label>
            Date
            <input data-control="date" type="date" value="${state.date}">
          </label>
          <label>
            Start
            <select data-control="time">
              ${timeOptions().map((time) => `<option value="${time}" ${time === state.time ? "selected" : ""}>${formatTime(time)}</option>`).join("")}
            </select>
          </label>
          <label>
            Duration
            <select data-control="durationMinutes">
              ${durationOptions().map((minutes) => `<option value="${minutes}" ${minutes === state.durationMinutes ? "selected" : ""}>${formatDuration(minutes)}</option>`).join("")}
            </select>
          </label>
          <button type="button" class="primary-action" data-view="book">Reserve</button>
        </form>
        <div class="facility-strip" aria-label="Facility snapshot">
          <span><strong>${state.settings.courtCount}</strong> courts</span>
          <span><strong>Rentable</strong> Weight Training &amp; Stretching Room</span>
          <span><strong>${formatCurrency(state.settings.pricing.courtHourlyRate)}</strong> court/hr</span>
        </div>
      </section>
    `;
  }

  return `
    <section class="hero public-hero crest-hero">
      <div class="hero-copy">
        <p class="eyebrow">Nine courts · One roof · Chantilly, VA</p>
        <h1>Where <em class="accent-red">every serve</em> finds a <em class="accent-blue">court.</em></h1>
        <p class="hero-text">Reserve PVC sport-tile courts from one hour, in 30-minute steps. Run private lessons on court or rent the Weight Training &amp; Stretching Room, and manage your club's whole season from one schedule. Invoices arrive after you play.</p>
        <div class="hero-actions">
          ${state.user ? "" : `<button type="button" class="primary-action" data-view="signup">Join the roster</button>`}
          ${state.user ? "" : `<button type="button" class="secondary-action" data-view="login">Log in</button>`}
          <button type="button" class="secondary-action" data-view="programs">View programs</button>
        </div>
      </div>
      <aside class="crest-card" aria-label="A to Z Volleyball Center">
        <img src="/atoz-volleyball-logo.png" alt="A to Z Volleyball Center logo">
        <svg viewBox="0 0 400 240" role="img" aria-label="Court in facility colors"><rect width="400" height="240" rx="8" fill="#2aa9e0"/><rect x="28" y="22" width="344" height="196" fill="#de1f26" stroke="#f5c400" stroke-width="4"/><line x1="200" y1="22" x2="200" y2="218" stroke="#f5c400" stroke-width="4"/><line x1="140" y1="22" x2="140" y2="218" stroke="#f5c400" stroke-width="2" stroke-dasharray="8 6"/><line x1="260" y1="22" x2="260" y2="218" stroke="#f5c400" stroke-width="2" stroke-dasharray="8 6"/></svg>
        <div class="crest-cap">CHERRY COURTS · SKYBLUE APRONS · GOLD LINES</div>
        <div class="crest-ring">
          <b class="ring-royal">9</b><b class="ring-cherry">1h</b><b class="ring-gold">30</b><b class="ring-navy">7</b>
        </div>
        <div class="crest-cap muted">COURTS · MIN BOOKING · MIN STEPS · DAYS OPEN</div>
      </aside>
    </section>
  `;
}

function renderHomeView() {
  if (state.user && !canViewScheduling() && !isAdminSession()) {
    return renderPendingView();
  }

  return `
    <section class="tile-grid" aria-label="What you can do here">
      <article class="tile tile-royal"><i class="ph-bold ph-calendar-check"></i><h3>Live schedule</h3><p>Approved members see every open slot across nine courts and the rentable Weight Training &amp; Stretching Room.</p></article>
      <article class="tile tile-cherry"><i class="ph-bold ph-users-three"></i><h3>Club season blocks</h3><p>Two courts, every Monday and Wednesday at 6? Locked for the season, invoiced after play.</p></article>
      <article class="tile tile-gold"><i class="ph-bold ph-chalkboard-teacher"></i><h3>Coach lessons</h3><p>On court or in the training room, sized 1–2 to 5+ players, editable up to 36 hours before.</p></article>
    </section>
    <p class="small-copy access-note">Scheduling opens after account approval — the front desk reviews every new account before booking unlocks.</p>
    <section class="metric-row" aria-label="Facility metrics">
      ${metric(String(state.settings.courtCount), "PVC sport-tile courts", "volleyball")}
      ${metric("1h", "minimum booking", "clock")}
      ${metric(formatCurrency(state.settings.pricing.courtHourlyRate), "court hourly rate", "receipt")}
      ${metric("30m", "increments after the first hour", "arrows-left-right")}
    </section>
    <div class="marquee" aria-hidden="true"><span>SEASON BLOCKS FOR CLUBS · PRIVATE LESSONS 1–2 / 3 / 4 / 5+ · WEIGHT TRAINING &amp; STRETCHING ROOM · INVOICED AFTER PLAY · OPEN 7 DAYS ·&nbsp;</span></div>
    <section class="workspace map-section">
      <div class="workspace-head">
        <div>
          <p class="eyebrow">Facility map</p>
          <h2>Nine courts plus a rentable training room</h2>
        </div>
      </div>
      ${renderFacilityMap({ interactive: isApprovedMember() })}
    </section>
    <section class="workspace hours-section">
      <div class="workspace-head">
        <div>
          <p class="eyebrow">Hours</p>
          <h2>Open seven days a week</h2>
        </div>
      </div>
      <div class="hours-grid">
        ${Object.entries(state.settings.operatingHours).map(([dayIndex, hours]) => `
          <div class="hours-cell${hours.closed ? " closed" : ""}">
            <strong>${dayName(Number(dayIndex))}</strong>
            <span>${hours.closed ? "Closed" : `${formatTime(hours.open)} – ${formatTime(hours.close)}`}</span>
          </div>
        `).join("")}
      </div>
      <p class="small-copy">Court schedules and reservations are available to approved member accounts after sign-in. Invoices are sent after play — no online payment is required.</p><p class="small-copy address-line">44080 Little River Turnpike, Suite 100, Chantilly, VA 20152</p>
    </section>
  `;
}

function renderPendingView() {
  return `
    <section class="workspace narrow-workspace">
      <div class="workspace-head">
        <div>
          <p class="eyebrow">Account review</p>
          <h2>Your account is waiting for approval.</h2>
        </div>
      </div>
      <p class="small-copy">Reservation tools are hidden until your account is approved. You can still view general facility and program information.</p>
      <button type="button" class="secondary-action" data-view="programs">View programs</button>
    </section>
  `;
}

function renderLoginView() {
  return `
    <section class="auth-workspace">
      <article class="panel auth-panel">
        <div class="panel-heading">
          <div>
            <p class="eyebrow">Account access</p>
            <h2>Log in to A2Z</h2>
          </div>
        </div>
        <form class="form-panel" data-form="login" aria-label="Login form">
          <label>
            ${shouldUseLiveAuth() ? "Email" : "Username or email"}
            <input name="loginId" autocomplete="username" value="${escapeHtml(state.loginId)}" placeholder="${shouldUseLiveAuth() ? "you@example.com" : "member or member@a2z.local"}">
          </label>
          <label>
            Password
            <input name="password" type="password" autocomplete="current-password" value="${escapeHtml(state.loginPassword)}" placeholder="Enter password">
          </label>
          <button type="submit" class="primary-action full">Log in</button>
        </form>
        <div class="social-grid" aria-label="Social login options">
          ${socialButton("Google")}
          ${socialButton("Apple")}
          ${socialButton("Facebook")}
        </div>
        ${isLocalPreview ? `<p class="small-copy">Local test logins: member / A2zMember1, pending / A2zPending1, owner / A2zOwner1.</p>` : `<p class="small-copy">Sign in with your email and password, or use Google or Facebook below.</p>`}
        ${shouldUseLiveAuth() ? `
          <button type="button" class="ghost-action" data-action="forgot-password">Forgot password?</button>` : ""}
        <button type="button" class="secondary-action" data-view="signup">Create account</button>
      </article>
      <aside class="panel image-panel">
        <img src="${TRAINING_IMAGE}" alt="Players training on an indoor volleyball court">
        <div>
          <p class="eyebrow">Approval required</p>
          <h2>Reservations stay private until sign-in.</h2>
          <p>Only approved accounts see schedule availability and booking controls.</p>
        </div>
      </aside>
    </section>
  `;
}

function renderSignupView() {
  return `
    <section class="auth-workspace">
      <article class="panel auth-panel">
        <div class="panel-heading">
          <div>
            <p class="eyebrow">New account</p>
            <h2>Sign up for A2Z access</h2>
          </div>
        </div>
        <form class="form-panel" data-form="signup" aria-label="Sign up form">
          <label>
            Email
            <input data-signup="email" name="email" type="email" autocomplete="email" value="${escapeHtml(state.signupForm.email)}" placeholder="name@example.com">
          </label>
          <label>
            Password
            <input data-signup="password" name="password" type="password" autocomplete="new-password" value="${escapeHtml(state.signupForm.password)}" placeholder="Choose a password">
          </label>
          <label>
            Username
            <input data-signup="username" name="username" autocomplete="username" value="${escapeHtml(state.signupForm.username)}" placeholder="coach-name or club-name">
            <small class="field-tip">Short handle for signing in, e.g. coach-kim or rtb-club.</small>
          </label>
          <label>
            Display name
            <input data-signup="displayName" name="displayName" value="${escapeHtml(state.signupForm.displayName)}" placeholder="Full name">
          </label>
          <label>
            Team or organization
            <input data-signup="teamName" name="teamName" value="${escapeHtml(state.signupForm.teamName)}" placeholder="Optional">
          </label>
          <button type="submit" class="primary-action full">Request access</button>
        </form>
        <button type="button" class="secondary-action" data-view="login">Back to log in</button>
      </article>
      <aside class="panel image-panel">
        <img src="${TRAINING_IMAGE}" alt="Players training on an indoor volleyball court">
        <div>
          <p class="eyebrow">Approval required</p>
          <h2>New accounts are reviewed before booking access.</h2>
          <p>After sign-up, the front desk approves your account. You will be able to view schedules and reserve courts once it is approved.</p>
        </div>
      </aside>
    </section>
  `;
}

function renderProgramsView() {
  return `
    <section class="programs">
      <div class="workspace-head">
        <div>
          <p class="eyebrow">Training menu</p>
          <h2>Rentals, teams, lessons, and event blocks.</h2>
        </div>
      </div>
      <div class="program-grid">
        ${program("Court rentals", "Court reservations for approved members, teams, and coaches.", `From ${formatCurrency(state.settings.pricing.courtHourlyRate)}/hr`, isApprovedMember() ? "Book court" : "Log in")}
        ${program("Private lessons", "One-on-one trainer sessions with two simultaneous gym slots available.", `From ${formatCurrency(state.settings.pricing.gymHourlyRate)}/hr`, isApprovedMember() ? "Book trainer" : "Log in")}
        ${program("Team blocks", "Season-long fixed schedules for clubs, camps, and recurring practices.", "Managed schedules", "Contact us")}
        ${program("Tournaments", "Multi-court event holds with payment tracking and closure controls.", "Custom", "Plan event")}
      </div>
    </section>
  `;
}

function renderScheduleView() {
  if (!canViewScheduling()) {
    return "";
  }

  return `
    <section class="workspace">
      <div class="workspace-head">
        <div>
          <p class="eyebrow">${isAdminSession() ? "Operations schedule" : "Availability board"}</p>
          <h2>${formatDateLabel(state.date)} from ${formatTime(state.time)} to ${formatTime(addMinutes(state.time, state.durationMinutes))}</h2>
        </div>
      </div>
      ${isApprovedMember() ? renderScheduleControls() : ""}
      <div class="timeline">
        ${timeOptions().slice(0, 14).map((time) => {
          const snapshot = getAvailabilityFor(time, state.settings.minBookingMinutes);
          const open = snapshot.courts.filter((court) => court.available).length;
          return `<button type="button" class="${time === state.time ? "active" : ""}" data-time="${time}">
            <span>${formatTime(time)}</span>
            <strong>${open}/${state.settings.courtCount}</strong>
          </button>`;
        }).join("")}
      </div>
      ${renderFacilityMap({ interactive: isApprovedMember() })}
      ${isApprovedMember() ? renderDayGrid() : ""}
    </section>
  `;
}

function renderScheduleControls() {
  return `
    <div class="inline-controls">
      <label>
        Date
        <input data-control="date" type="date" value="${state.date}">
      </label>
      <label>
        Duration
        <select data-control="durationMinutes">
          ${durationOptions().map((minutes) => `<option value="${minutes}" ${minutes === state.durationMinutes ? "selected" : ""}>${formatDuration(minutes)}</option>`).join("")}
        </select>
      </label>
    </div>
  `;
}

function renderBookingView() {
  if (!isApprovedMember()) {
    return "";
  }

  const availability = getCurrentAvailability();
  const selectedCourt = availability.courts.find((court) => court.courtId === state.selectedCourt);
  const slotAvailable = state.resourceType === "trainer" ? availability.trainer.available : selectedCourt?.available;
  const bookingSeasonPrice = selectedBookingSeasonPrice();
  const memberContext = !isAdminSession() && shouldUseLiveAuth() ? memberContextByKey(state.bookingContextKey) : null;
  const bracketPrice = memberContext?.type === "private"
    ? state.bracketPrices.find((price) => price.bracket === state.lessonBracket)
    : null;
  const bracketRate = bracketPrice ? (state.resourceType === "trainer" ? bracketPrice.gymHourlyRate : bracketPrice.courtHourlyRate) : null;
  const estimatedRate = bracketRate ?? bookingSeasonPrice?.hourlyRate ?? (state.resourceType === "trainer" ? state.settings.pricing.gymHourlyRate : state.settings.pricing.courtHourlyRate);
  const estimatedDue = estimatedRate * (state.durationMinutes / 60);

  return `
    <section class="workspace booking-workspace">
      <div class="workspace-head">
        <div>
          <p class="eyebrow">Reservation desk</p>
          <h2>${state.resourceType === "trainer" ? "Book trainer gym time" : `Book ${labelCourt(state.selectedCourt)}`}</h2>
        </div>
        <span class="status-pill ${slotAvailable ? "is-open" : "is-busy"}">${slotAvailable ? "Available" : "Not available"}</span>
      </div>
      <div class="booking-layout">
        <form class="panel form-panel" aria-label="Booking form">
          <label>
            Resource
            <select data-control="resourceType">
              <option value="court" ${state.resourceType === "court" ? "selected" : ""}>Court</option>
              <option value="trainer" ${state.resourceType === "trainer" ? "selected" : ""}>Trainer gym</option>
            </select>
          </label>
          <label>
            Date
            <input data-control="date" type="date" value="${state.date}">
          </label>
          <label>
            Start time
            <select data-control="time">
              ${timeOptions().map((time) => `<option value="${time}" ${time === state.time ? "selected" : ""}>${formatTime(time)}</option>`).join("")}
            </select>
          </label>
          <label>
            Duration
            <select data-control="durationMinutes">
              ${durationOptions().map((minutes) => `<option value="${minutes}" ${minutes === state.durationMinutes ? "selected" : ""}>${formatDuration(minutes)}</option>`).join("")}
            </select>
          </label>
          ${state.resourceType === "court" ? `
            <label>
              Court
              <select data-control="selectedCourt">
                ${availability.courts.map((court) => `<option value="${court.courtId}" ${court.courtId === state.selectedCourt ? "selected" : ""}>${labelCourt(court.courtId)} ${court.available ? "" : "(reserved)"}</option>`).join("")}
              </select>
            </label>
          ` : ""}
          ${state.editingReservationId ? `<p class="small-copy edit-banner">Editing your private lesson — adjust the details and confirm, or <button type="button" class="ghost-action" data-action="cancel-edit">keep it as is</button>.</p>` : ""}
          ${!isAdminSession() && shouldUseLiveAuth() ? renderMemberBookingContextFields() : ""}
          ${isAdminSession() ? `
            <label>
              Client
              <select data-control="bookingSubjectId">
                <option value="">Admin account</option>
                ${subjectOptions(state.bookingSubjectId)}
              </select>
            </label>
            ${clientTypeHasTeams(subjectById(state.bookingSubjectId)) ? `
              <label>
                Team
                <select data-control="bookingSubjectTeamId">
                  ${subjectTeamOptions(state.bookingSubjectId, state.bookingSubjectTeamId)}
                </select>
              </label>
            ` : ""}
            ${bookingSeasonPriceOptions(state.bookingSubjectId).length ? `
              <label>
                Season price
                <select data-control="bookingSeasonPriceId">
                  ${bookingSeasonPriceOptions(state.bookingSubjectId).map((price) => `<option value="${price.id}" ${bookingSeasonPrice?.id === price.id ? "selected" : ""}>${escapeHtml(seasonPriceLabel(price))} (${formatCurrency(price.hourlyRate)}/hr)</option>`).join("")}
                </select>
              </label>
            ` : ""}
          ` : ""}
          <button type="button" class="primary-action full" data-action="book" ${(slotAvailable || state.editingReservationId) && !privateBookingBlocked() ? "" : "disabled"}>${state.editingReservationId ? "Update reservation" : "Confirm reservation"}</button>
        </form>
        <div class="panel receipt-panel">
          <p class="eyebrow">Reservation summary</p>
          <h3>${formatDateLabel(state.date)}</h3>
          <dl>
            <div><dt>Time</dt><dd>${formatTime(state.time)}-${formatTime(addMinutes(state.time, state.durationMinutes))}</dd></div>
            <div><dt>Resource</dt><dd>${state.resourceType === "trainer" ? "Trainer gym" : labelCourt(state.selectedCourt)}</dd></div>
            ${bookingSeasonPrice ? `<div><dt>Season</dt><dd>${escapeHtml(seasonPriceLabel(bookingSeasonPrice))}</dd></div>` : ""}
            <div><dt>Hourly rate</dt><dd>${formatCurrency(estimatedRate)}</dd></div>
            <div><dt>Estimated due</dt><dd>${formatCurrency(estimatedDue)}</dd></div>
            <div><dt>Account</dt><dd>${escapeHtml((isAdminSession() ? subjectById(state.bookingSubjectId)?.displayName : memberContextByKey(state.bookingContextKey)?.label) ?? state.user.name)}</dd></div>
          </dl>
          <p class="small-copy">Reservations start on the hour or half-hour and last at least one hour.</p>
        </div>
      </div>
    </section>
  `;
}

function renderMyBookingsView() {
  if (!isApprovedMember()) {
    return "";
  }

  if (shouldUseLiveAuth()) {
    const reservations = [...state.myReservations]
      .filter((reservation) => reservation.status !== "cancelled")
      .sort((a, b) => new Date(a.start) - new Date(b.start));
    return `
      <section class="workspace">
        <div class="workspace-head">
          <div>
            <p class="eyebrow">My bookings</p>
            <h2>${reservations.length} reservation${reservations.length === 1 ? "" : "s"}</h2>
          </div>
        </div>
        <div class="stack-list">
          ${reservations.length ? reservations.map((reservation) => {
            const isFuture = new Date(reservation.start) > new Date();
            const isPaid = reservation.paymentStatus === "paid";
            return `
              <div class="list-row">
                <span>
                  <strong>${reservation.resourceType === "court" ? `Court ${reservation.courtNumber}` : "Trainer gym"}</strong>
                  <small>${formatShortDate(reservation.start)} ${formatShortTime(reservation.start)}-${formatShortTime(reservation.end)} · ${escapeHtml(reservation.teamName ?? "")}${reservation.lessonPlayerBracket ? ` · ${reservation.lessonPlayerBracket} players` : ""}</small>
                </span>
                <span class="row-actions">
                  <span class="status-pill ${isPaid ? "is-open" : "is-due"}">${isPaid ? "paid" : "invoice due"}</span>
                  ${reservation.lessonPlayerBracket && !isPaid && isFuture ? `
                    ${isEditableWindow(reservation.start)
                      ? `<button type="button" class="ghost-action" data-action="edit-reservation" data-reservation="${reservation.id}">Edit</button>`
                      : `<small class="field-tip">Edits within 36h: front desk</small>`}
                    <button type="button" class="ghost-action" data-action="cancel-reservation" data-reservation="${reservation.id}">Cancel${isEditableWindow(reservation.start) ? "" : ` (${cancellationFeePercentFor(reservation.start)}% fee)`}</button>
                  ` : reservation.lessonPlayerBracket ? ""
                    : isFuture ? `<small class="field-tip">Team practices: contact the front desk to change</small>` : ""}
                </span>
              </div>
            `;
          }).join("") : `<p class="small-copy">No reservations yet. Head to the schedule to reserve court or trainer gym time.</p>`}
        </div>
      </section>
    `;
  }

  const bookings = buildScheduler().listUserBookings(state.user.id, state.user);
  return `
    <section class="workspace">
      <div class="workspace-head">
        <div>
          <p class="eyebrow">My bookings</p>
          <h2>${bookings.length} upcoming reservation${bookings.length === 1 ? "" : "s"}</h2>
        </div>
      </div>
      <div class="stack-list">
        ${bookings.length ? bookings.map((booking) => `
          <div class="list-row">
            <span><strong>${booking.resourceType === "court" ? labelCourt(booking.courtId) : "Trainer gym"}</strong><small>${formatShortDate(booking.start)} ${formatShortTime(booking.start)}-${formatShortTime(booking.end)}</small></span>
            <span class="status-pill ${isBookingPaid(booking) ? "is-open" : "is-due"}">${isBookingPaid(booking) ? "paid" : "due"}</span>
          </div>
        `).join("") : `<p class="small-copy">No reservations yet.</p>`}
      </div>
    </section>
  `;
}

function renderAdminView() {
  if (!isAdminSession()) {
    return "";
  }

  ensureAdminTabAvailable();
  const activeTab = state.adminTab;
  const menuItems = activeAdminMenuItems();
  const adminDisplayName = escapeHtml(state.user?.name ?? "Admin");
  return `
    <section class="workspace admin-workspace">
      <div class="admin-shell">
        <nav class="admin-tabs" role="tablist" aria-label="Admin sections">
          <div class="admin-menu-brand" aria-label="A to Z Volleyball Center">
            <img src="/atoz-volleyball-logo.png" alt="A to Z Volleyball Center logo">
            <span>
              <strong>${adminDisplayName}</strong>
              <button type="button" data-action="logout">Sign Out</button>
            </span>
          </div>
          ${menuItems.map((item) => adminTabButton(item.key, item.name)).join("")}
        </nav>
        <div class="admin-tab-panel">
          ${activeTab === "clients" ? renderAdminClientsTab() : ""}
          ${activeTab === "users" ? renderAdminUsersTab() : ""}
          ${activeTab === "payments" ? renderPaymentDueTab() : ""}
          ${activeTab === "invoices" ? renderInvoicesTab() : ""}
          ${activeTab === "past-payments" ? renderPastPaymentsTab() : ""}
          ${activeTab === "bulk-reservations" ? renderBulkReservationsTab() : ""}
          ${activeTab === "calendar" ? renderAdminCalendarTab() : ""}
          ${activeTab === "reports" ? renderReportsTab() : ""}
          ${activeTab === "club-seasons" ? renderTeamSeasonsSettings() : ""}
          ${activeTab === "bulk-delete" ? renderBulkDeleteTab() : ""}
          ${activeTab === "settings" ? renderAdminSettings() : ""}
        </div>
      </div>
    </section>
  `;
}

function adminTabButton(tab, label) {
  return `<button type="button" class="${state.adminTab === tab ? "active" : ""}" data-admin-tab="${tab}" role="tab" aria-selected="${state.adminTab === tab}">${label}</button>`;
}

function renderAdminClientsTab() {
  return `
    <div class="admin-grid single-column">
      ${state.editingSubjectId ? renderClientDetailPage() : renderAdminSubjects()}
      ${state.editingSubjectId ? "" : renderDisabledClientsSection()}
    </div>
  `;
}

function renderAdminUsersTab() {
  const users = adminUsers();
  const pending = users.filter((user) => user.approvalStatus === "pending");
  const approved = users.filter((user) => user.approvalStatus === "approved");
  const rejected = users.filter((user) => user.approvalStatus === "rejected");

  return `
    <div class="admin-grid single-column">
      ${renderUserSection("Pending accounts", pending, "pending")}
      ${renderUserSection("Approved users", approved, "approved")}
      ${renderUserSection("Rejected / Disabled Users", rejected, "rejected")}
    </div>
  `;
}

function renderUserSection(title, users, status) {
  return `
    <article class="panel settings-panel">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">${status}</p>
          <h3>${title} (${users.length})</h3>
        </div>
      </div>
      <div class="stack-list">
        ${users.length ? users.map((user) => renderUserRow(user, status)).join("") : `<p class="small-copy">No ${status} users.</p>`}
      </div>
    </article>
  `;
}

function renderUserRow(user, status) {
  if (state.editingUserId === user.id) {
    return renderUserEditRow(user);
  }
  const isCurrentUser = isCurrentAdminUser(user.id);

  return `
    <div class="user-row-wrap">
      <div class="list-row user-row">
        <span>
          <strong>${escapeHtml(user.name)}</strong>
          <small>${escapeHtml(user.email)}</small>
        </span>
        ${status === "approved" ? "" : `<span class="status-pill ${status === "rejected" ? "is-busy" : "is-due"}">${status}</span>`}
        <div class="row-actions">
          ${status !== "approved" ? `<button type="button" data-action="approve" data-user="${user.id}">${status === "rejected" ? "Enable" : "Approve"}</button>` : ""}
          ${status === "pending" ? `<button type="button" data-action="reject" data-user="${user.id}">Reject</button>` : ""}
          ${status === "approved" ? `<button type="button" data-action="edit-user" data-user="${user.id}">Edit</button>` : ""}
          ${status === "approved" && user.role === "admin" ? `<button type="button" data-action="edit-admin-rights" data-user="${user.id}">Admin rights</button>` : ""}
          ${status === "approved" && !isCurrentUser ? `<button type="button" data-action="disable-user" data-user="${user.id}">Disable</button>` : ""}
        </div>
      </div>
      ${state.editingUserRightsId === user.id ? renderAdminRightsPanel(user) : ""}
    </div>
  `;
}

function renderUserEditRow(user) {
  return `
    <div class="list-row user-row edit-row user-edit-row">
      <label>
        Display name
        <input data-edit-user="name" value="${escapeHtml(state.editUserForm.name)}">
      </label>
      <label>
        Role
        <select data-edit-user="role">
          <option value="user" ${state.editUserForm.role === "user" ? "selected" : ""}>User</option>
          <option value="admin" ${state.editUserForm.role === "admin" ? "selected" : ""}>Admin</option>
        </select>
      </label>
      <div class="row-actions">
        <button type="button" class="primary-action compact" data-action="save-user" data-user="${user.id}">Save</button>
        <button type="button" data-action="cancel-edit-user">Cancel</button>
      </div>
    </div>
  `;
}

function renderAdminRightsPanel(user) {
  const menuItems = allActiveAdminMenuItems();
  const selectedCount = menuItems.filter((item) => state.editUserRightsForm[item.key]).length;
  const allSelected = menuItems.length > 0 && selectedCount === menuItems.length;
  return `
    <div class="admin-rights-panel">
      <div class="panel-heading compact-heading">
        <div>
          <p class="eyebrow">Admin rights</p>
          <h4>${escapeHtml(user.name)}</h4>
        </div>
        <label class="checkbox-label admin-rights-select-all">
          <input type="checkbox" data-admin-rights-all ${allSelected ? "checked" : ""}>
          <span>De/Select All</span>
        </label>
      </div>
      <div class="admin-rights-grid">
        ${menuItems.map((item) => `
          <label class="checkbox-label admin-right-item">
            <input type="checkbox" data-admin-right="${escapeHtml(item.key)}" ${state.editUserRightsForm[item.key] ? "checked" : ""}>
            <span>${escapeHtml(item.name)}</span>
          </label>
        `).join("")}
      </div>
      <div class="row-actions">
        <button type="button" class="primary-action compact" data-action="save-admin-rights" data-user="${user.id}">Save</button>
        <button type="button" data-action="cancel-admin-rights">Cancel</button>
      </div>
    </div>
  `;
}

function renderPaymentDueTab() {
  const payments = paymentDueAccounts();
  const invoiceableCount = payments.filter((payment) => !invoiceForPayment(payment)).length;
  return `
    <article class="panel settings-panel">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">Payment Due</p>
          <h3>${payments.length} payment${payments.length === 1 ? "" : "s"} due</h3>
        </div>
        <button type="button" class="primary-action compact" data-action="generate-all-invoices" ${invoiceableCount ? "" : "disabled"}>Generate All Invoices</button>
      </div>
      <div class="payment-list">
        ${payments.map((payment) => renderPaymentDueAccount(payment)).join("") || `<p class="small-copy">No payment due records for the current rules.</p>`}
      </div>
    </article>
  `;
}

function renderPaymentDueAccount(payment) {
  const invoice = invoiceForPayment(payment);
  const open = isPaymentPanelOpen(payment.key);
  return `
    <section class="payment-panel ${open ? "is-open" : ""}">
      <div class="payment-summary">
        <button type="button" class="icon-button payment-toggle" data-action="toggle-payment-panel" data-payment-key="${payment.key}" aria-expanded="${open}" aria-label="${open ? "Collapse payment" : "Expand payment"}">${open ? "^" : "V"}</button>
        <span class="payment-title">
          <strong>${escapeHtml(payment.name)}</strong>
          <span class="status-pill is-due">${paymentAmountLabel(payment.amount)}</span>
          <small>${payment.reservationCount} reservation${payment.reservationCount === 1 ? "" : "s"}, ${formatDuration(payment.minutes)}</small>
        </span>
        <div class="row-actions payment-summary-actions">
          <button type="button" data-action="create-invoice" data-payment-key="${payment.key}" ${invoice ? "disabled" : ""}>${invoice ? "Invoice Created" : "Create Invoice"}</button>
          <button type="button" data-action="mark-payment-paid" data-payment-key="${payment.key}">Mark Paid</button>
        </div>
      </div>
      ${open ? `
      <div class="payment-panel-body">
        ${invoice ? `<p class="small-copy">Linked invoice: ${escapeHtml(invoice.invoiceNumber)}</p>` : ""}
        <div class="stack-list compact-list">
          ${payment.bookings.map((booking) => `
            <div class="list-row">
              <span>
                <strong>${booking.resourceType === "court" ? labelCourt(booking.courtId) : "Trainer gym"}</strong>
                <small>${formatShortDate(booking.start)} ${formatShortTime(booking.start)}-${formatShortTime(booking.end)} · Reservation ${escapeHtml(booking.id)}</small>
              </span>
              <span class="status-pill is-due">${paymentAmountLabel(bookingAmount(booking))}</span>
            </div>
          `).join("")}
        </div>
      </div>
      ` : ""}
    </section>
  `;
}

function renderPastPaymentsTab() {
  const payments = pastPaymentRecords();
  return `
    <article class="panel settings-panel">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">Payments</p>
          <h3>${payments.length} paid payment${payments.length === 1 ? "" : "s"}</h3>
        </div>
      </div>
      <div class="payment-list">
        ${payments.map((payment) => {
          const open = isPastPaymentPanelOpen(payment.key);
          return `
          <section class="payment-panel ${open ? "is-open" : ""}">
            <div class="payment-summary">
              <button type="button" class="icon-button payment-toggle" data-action="toggle-past-payment-panel" data-payment-key="${payment.key}" aria-expanded="${open}" aria-label="${open ? "Collapse payment" : "Expand payment"}">${open ? "^" : "V"}</button>
              <span class="payment-title">
                <strong>${escapeHtml(payment.name)}</strong>
                <small>${payment.reservationCount} reservation${payment.reservationCount === 1 ? "" : "s"}, ${formatDuration(payment.minutes)}</small>
              </span>
              <span class="status-pill is-open payment-amount-pill">${paymentAmountLabel(payment.amount)}</span>
            </div>
            ${open ? `
            <div class="payment-panel-body">
              <div class="stack-list compact-list">
                ${payment.bookings.map((booking) => `
                  <div class="list-row">
                    <span>
                      <strong>${booking.resourceType === "court" ? labelCourt(booking.courtId) : "Trainer gym"}</strong>
                      <small>${formatShortDate(booking.start)} ${formatShortTime(booking.start)}-${formatShortTime(booking.end)} · Reservation ${escapeHtml(booking.id)}</small>
                    </span>
                    <span class="status-pill is-open">${paymentAmountLabel(bookingAmount(booking))}</span>
                  </div>
                `).join("")}
              </div>
            </div>
            ` : ""}
          </section>
        `;
        }).join("") || `<p class="small-copy">No paid payment records yet.</p>`}
      </div>
    </article>
  `;
}

function renderInvoicesTab() {
  const invoices = filteredInvoices();
  return `
    <article class="panel settings-panel">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">Invoices</p>
          <h3>${invoices.length} invoice${invoices.length === 1 ? "" : "s"}</h3>
        </div>
      </div>
      <div class="admin-form-row invoice-filter-row">
        <label>
          User
          <select data-invoice-filter="subjectId">
            <option value="">All</option>
            ${invoiceSubjectOptions(state.invoiceFilters.subjectId)}
          </select>
        </label>
        <label>
          Type
          <select data-invoice-filter="type">
            <option value="" ${state.invoiceFilters.type === "" ? "selected" : ""}>All</option>
            <option value="team" ${state.invoiceFilters.type === "team" ? "selected" : ""}>Teams</option>
            <option value="coach" ${state.invoiceFilters.type === "coach" ? "selected" : ""}>Coaches</option>
            <option value="user" ${state.invoiceFilters.type === "user" ? "selected" : ""}>Users</option>
          </select>
        </label>
        <label>
          Created year
          <select data-invoice-filter="year">
            ${invoiceYearOptions().map((year) => `<option value="${year}" ${state.invoiceFilters.year === year ? "selected" : ""}>${year}</option>`).join("")}
          </select>
        </label>
        <label>
          Created month
          <select data-invoice-filter="month">
            ${invoiceMonthOptions().map((month) => `<option value="${month.value}" ${state.invoiceFilters.month === month.value ? "selected" : ""}>${month.label}</option>`).join("")}
          </select>
        </label>
      </div>
      <div class="invoice-table-wrap">
        <table class="invoice-table">
          <thead>
            <tr>
              ${invoiceSortHeader("invoiceNumber", "Invoice")}
              ${invoiceSortHeader("subjectName", "User")}
              ${invoiceSortHeader("createdAt", "Created")}
              ${invoiceSortHeader("amount", "Amount")}
              <th class="actions-header">Actions</th>
            </tr>
          </thead>
          <tbody>
            ${invoices.map((invoice) => `
              <tr>
                <td>${escapeHtml(invoice.invoiceNumber)}</td>
                <td>${escapeHtml(invoice.subjectName)}<small>${invoice.subjectType}</small></td>
                <td>${formatShortDate(invoice.createdAt)}</td>
                <td>${formatCurrency(invoice.amount)}</td>
                <td>
                  <div class="row-actions">
                    <button type="button" data-action="print-invoice" data-invoice="${invoice.id}">Print</button>
                    <button type="button" data-action="email-invoice-admin" data-invoice="${invoice.id}">Email Admin</button>
                    <button type="button" data-action="email-invoice-user" data-invoice="${invoice.id}">Email User</button>
                  </div>
                </td>
              </tr>
            `).join("") || `<tr><td colspan="5">No invoices created yet.</td></tr>`}
          </tbody>
        </table>
      </div>
    </article>
  `;
}

function invoiceSortHeader(sortBy, label) {
  const active = state.invoiceFilters.sortBy === sortBy;
  const suffix = active ? state.invoiceFilters.sortDirection === "asc" ? " ↑" : " ↓" : "";
  return `<th><button type="button" data-action="sort-invoices" data-sort="${sortBy}">${label}${suffix}</button></th>`;
}

function renderAdminSubjects() {
  const subjects = activeClients();
  return `
    <article class="panel settings-panel">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">Create Client</p>
          <h3>${subjects.length} active client${subjects.length === 1 ? "" : "s"}</h3>
        </div>
      </div>
      <div class="admin-form-row">
        <label>
          Client type
          <select data-admin-subject="clientTypeId">
            ${clientTypeOptions(state.adminSubjectForm.clientTypeId)}
          </select>
        </label>
        <label>
          Name
          <input data-admin-subject="displayName" value="${escapeHtml(state.adminSubjectForm.displayName)}" placeholder="Name">
        </label>
        <label>
          Short Name
          <input data-admin-subject="shortName" value="${escapeHtml(state.adminSubjectForm.shortName)}" placeholder="Calendar label">
        </label>
        <button type="button" data-action="create-admin-subject">Create Client</button>
      </div>
      <div class="stack-list compact-list">
        ${subjects.map((subject) => renderSubjectRow(subject)).join("")}
      </div>
    </article>
  `;
}

function renderSubjectRow(subject) {
  return `
    <div class="list-row user-row">
      <span>
        <strong>${escapeHtml(subject.displayName)}</strong>
        <small>${escapeHtml(clientDisplayType(subject))} · ${escapeHtml(clientShortName(subject))}${subject.contactEmail ? ` · ${escapeHtml(subject.contactEmail)}` : ""}</small>
      </span>
      <span class="status-pill ${clientTypeHasTeams(subject) ? "is-open" : "is-due"}">${escapeHtml(clientDisplayType(subject))}</span>
      <div class="row-actions">
        <button type="button" data-action="edit-subject" data-subject="${subject.id}">Edit</button>
        <button type="button" data-action="invite-subject" data-subject="${subject.id}">Invite</button>
        <button type="button" data-action="disable-subject" data-subject="${subject.id}">Disable</button>
      </div>
    </div>
  `;
}

function renderClientDetailPage() {
  const subject = subjectById(state.editingSubjectId) ?? disabledClients().find((client) => client.id === state.editingSubjectId);
  if (!subject) {
    state.editingSubjectId = null;
    return "";
  }
  const hasTeams = clientTypeHasTeams({ ...subject, clientTypeId: state.editSubjectForm.clientTypeId });
  return `
    <article class="panel settings-panel client-detail-panel">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">Client</p>
          <h3>Edit ${escapeHtml(subject.displayName)}</h3>
        </div>
        <button type="button" data-action="cancel-edit-subject">Back to clients</button>
      </div>
      <div class="admin-form-row client-detail-grid">
        <label>
          Client type
          <select data-edit-subject="clientTypeId">
            ${clientTypeOptions(state.editSubjectForm.clientTypeId)}
          </select>
        </label>
        <label>
          Name
          <input data-edit-subject="displayName" value="${escapeHtml(state.editSubjectForm.displayName)}">
        </label>
        <label>
          Short name
          <input data-edit-subject="shortName" value="${escapeHtml(state.editSubjectForm.shortName)}">
        </label>
        <label>
          Contact name
          <input data-edit-subject="contactName" value="${escapeHtml(state.editSubjectForm.contactName)}">
        </label>
        <label>
          Email
          <input data-edit-subject="contactEmail" type="email" value="${escapeHtml(state.editSubjectForm.contactEmail)}">
        </label>
        <label>
          Phone
          <input data-edit-subject="contactPhone" value="${escapeHtml(state.editSubjectForm.contactPhone)}">
        </label>
        <label class="wide-field">
          Notes
          <textarea data-edit-subject="notes" rows="5">${escapeHtml(state.editSubjectForm.notes)}</textarea>
        </label>
      </div>
      <div class="button-row preview-actions">
        <button type="button" class="primary-action compact" data-action="save-subject" data-subject="${subject.id}">Save Client</button>
      </div>
      ${hasTeams ? renderSubjectTeamsManager(subject) : ""}
    </article>
  `;
}

function renderSubjectTeamsManager(subject) {
  const teams = subjectTeamsForSubject(subject.id);
  return `
    <section class="embedded-section">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">Teams</p>
          <h3>${teams.length} team${teams.length === 1 ? "" : "s"}</h3>
        </div>
      </div>
      <form class="admin-form-row team-row team-detail-row" data-form="create-subject-team">
        <label>
          Team name
          <input data-subject-team="name" value="${escapeHtml(state.teamForm.name)}" placeholder="Storm Elite 16U">
        </label>
        <label>
          Short name
          <input data-subject-team="shortName" value="${escapeHtml(state.teamForm.shortName)}" placeholder="Storm 16U">
        </label>
        <button type="button" data-action="create-subject-team">Create Team</button>
      </form>
      <div class="stack-list compact-list">
        ${teams.map((team) => state.editingTeamId === team.id ? renderSubjectTeamEditRow(team) : renderSubjectTeamRow(team)).join("") || `<p class="small-copy">No teams yet.</p>`}
      </div>
    </section>
  `;
}

function renderSubjectTeamRow(team) {
  return `
    <div class="list-row user-row">
      <span>
        <strong>${escapeHtml(team.name)}</strong>
        <small>${escapeHtml(team.shortName)}</small>
      </span>
      <div class="row-actions">
        <button type="button" data-action="edit-subject-team" data-team="${team.id}">Edit</button>
        <button type="button" data-action="delete-subject-team" data-team="${team.id}">Delete</button>
      </div>
    </div>
  `;
}

function renderSubjectTeamEditRow(team) {
  return `
    <div class="list-row user-row edit-row team-row team-detail-row">
      <label>
        Team name
        <input data-edit-subject-team="name" value="${escapeHtml(state.editTeamForm.name)}">
      </label>
      <label>
        Short name
        <input data-edit-subject-team="shortName" value="${escapeHtml(state.editTeamForm.shortName)}">
      </label>
      <div class="row-actions">
        <button type="button" class="primary-action compact" data-action="save-subject-team" data-team="${team.id}">Save</button>
        <button type="button" data-action="cancel-edit-subject-team">Cancel</button>
      </div>
    </div>
  `;
}

function renderDisabledClientsSection() {
  const clients = disabledClients();
  return `
    <article class="panel settings-panel">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">disabled clients</p>
          <h3>Disabled Clients (${clients.length})</h3>
        </div>
      </div>
      <div class="stack-list compact-list">
        ${clients.map((client) => `
          <div class="list-row user-row">
            <span>
              <strong>${escapeHtml(client.displayName)}</strong>
              <small>${escapeHtml(clientShortName(client))}</small>
            </span>
            <div class="row-actions">
              <button type="button" data-action="enable-subject" data-subject="${client.id}">Enable</button>
            </div>
          </div>
        `).join("") || `<p class="small-copy">No disabled clients.</p>`}
      </div>
    </article>
  `;
}

function renderBulkReservationsTab() {
  const previewItems = state.bulkPreview?.items ?? [];
  const noCourtItems = bulkNoCourtPreviewItems();
  const conflicts = previewItems.filter((item) => item.status === "conflict").length;
  const today = todayDateKey();
  const latestPrice = latestSeasonPriceForSelectedBulkSubject();
  const selectedClient = subjectById(state.bulkForm.subjectId);
  const bulkRequiresTeam = clientTypeHasTeams(selectedClient);
  return `
    <article class="panel settings-panel">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">Bulk Reserve</p>
          <h3>Preview and create recurring reservations.</h3>
        </div>
        <label class="bulk-price-mode-toggle">
          <input data-bulk="useSeasonPrice" type="checkbox" ${state.bulkForm.useSeasonPrice ? "checked" : ""}>
          ${state.bulkForm.useSeasonPrice ? "Season Price" : "Custom Price"}
        </label>
      </div>
      <div class="admin-form-row bulk-entry-row">
        <label>
          Client
          <select data-bulk="subjectId">
            ${bulkSubjectOptions(state.bulkForm.subjectId)}
          </select>
        </label>
        ${bulkRequiresTeam ? `
          <label>
            Team
            <select data-bulk="subjectTeamId">
              ${subjectTeamOptions(state.bulkForm.subjectId, state.bulkForm.subjectTeamId)}
            </select>
          </label>
        ` : ""}
        ${state.bulkForm.useSeasonPrice && latestPrice ? `
          <label>
            Season price
            <select data-bulk="seasonPriceId">
              <option value="${latestPrice.id}" selected>${escapeHtml(seasonPriceLabel(latestPrice))} (${formatCurrency(latestPrice.hourlyRate)}/hr)</option>
            </select>
          </label>
        ` : state.bulkForm.useSeasonPrice && isBulkTeamSubjectSelected() ? `
          <label class="missing-season-price">
            No season price found. enter hourly rate
            <input data-bulk="hourlyRate" type="number" min="0" step="1" value="${state.bulkForm.hourlyRate}">
          </label>
        ` : `
          <label>
            Custom Price
            <input data-bulk="hourlyRate" type="number" min="0" step="1" value="${state.bulkForm.hourlyRate}">
          </label>
        `}
        <label>
          Resource
          <select data-bulk="resourceType">
            <option value="court" ${state.bulkForm.resourceType === "court" ? "selected" : ""}>Court</option>
            <option value="trainer" ${state.bulkForm.resourceType === "trainer" ? "selected" : ""}>Trainer gym</option>
          </select>
        </label>
        <label>
          Court
          <select data-bulk="courtId" ${state.bulkForm.resourceType === "trainer" ? "disabled" : ""}>
            <option value="" ${state.bulkForm.courtId === "" ? "selected" : ""}>Auto assign</option>
            <option value="auto_except_1" ${state.bulkForm.courtId === "auto_except_1" ? "selected" : ""}>Auto Assign Except Court 1</option>
            ${Array.from({ length: state.settings.courtCount }, (_, index) => `court-${index + 1}`).map((courtId) => `<option value="${courtId}" ${state.bulkForm.courtId === courtId ? "selected" : ""}>${labelCourt(courtId)}</option>`).join("")}
          </select>
        </label>
        <label>
          Courts needed
          <input data-bulk="courtCountNeeded" type="number" min="1" max="${state.settings.courtCount}" step="1" value="${state.bulkForm.courtCountNeeded}" ${state.bulkForm.resourceType === "trainer" ? "disabled" : ""}>
        </label>
        <label>
          Start date
          <input data-bulk="startDate" type="date" min="${today}" value="${state.bulkForm.startDate}">
        </label>
        <label>
          End date
          <input data-bulk="endDate" type="date" min="${today}" value="${state.bulkForm.endDate}">
        </label>
        <label>
          Start
          <select data-bulk="startTime">
            ${bulkStartTimeOptions().map((time) => `<option value="${time}" ${state.bulkForm.startTime === time ? "selected" : ""}>${formatTime(time)}</option>`).join("")}
          </select>
        </label>
        <label>
          Duration
          <select data-bulk="durationMinutes">
            ${durationOptions(15, false).map((minutes) => `<option value="${minutes}" ${state.bulkForm.durationMinutes === minutes ? "selected" : ""}>${formatDuration(minutes)}</option>`).join("")}
          </select>
        </label>
      </div>
      <div class="weekday-row">
        ${[1, 2, 3, 4, 5, 6, 0].map((day) => `
          <label>
            <input data-bulk-day="${day}" type="checkbox" ${state.bulkForm.daysOfWeek.includes(day) ? "checked" : ""}>
            ${dayName(day)}
          </label>
        `).join("")}
      </div>
      <div class="button-row">
        <button type="button" data-action="bulk-preview">Preview</button>
        <button type="button" class="primary-action compact" data-action="bulk-apply">Create</button>
      </div>
      <div class="stack-list compact-list">
        ${state.bulkPreview ? `<p class="small-copy">${previewItems.length} requested, ${conflicts} conflict${conflicts === 1 ? "" : "s"}.</p>` : ""}
        ${state.bulkPreview ? `
          <div class="button-row preview-actions">
            <button type="button" data-action="bulk-calendar-open">View on Calendar</button>
          </div>
        ` : ""}
        ${state.bulkPreview ? `<p class="small-copy"><strong>Conflicted dates</strong></p>` : ""}
        ${state.bulkPreview && !noCourtItems.length ? `<p class="small-copy">No conflicted dates found.</p>` : ""}
        ${noCourtItems.slice(0, 12).map((item) => renderBulkConflictRow(item)).join("")}
      </div>
      ${state.bulkCalendarOpen ? renderBulkAvailabilityCalendar() : ""}
      ${renderBulkOperationsList()}
    </article>
  `;
}

function renderBulkDeleteTab() {
  const skippedPaidCount = state.bulkDeleteSkippedPaid.length;
  return `
    <article class="panel settings-panel">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">Bulk Delete</p>
          <h3>Preview and soft-delete unpaid reservations by client.</h3>
        </div>
      </div>
      <div class="admin-form-row bulk-delete-row">
        <label>
          Client
          <select data-bulk-delete="subjectId">
            ${subjectOptions(state.bulkDeleteForm.subjectId)}
          </select>
        </label>
        <label>
          Start date
          <input data-bulk-delete="startDate" type="date" value="${state.bulkDeleteForm.startDate}">
        </label>
        <label>
          End date
          <input data-bulk-delete="endDate" type="date" value="${state.bulkDeleteForm.endDate}">
        </label>
      </div>
      <div class="button-row two-actions">
        <button type="button" data-action="bulk-delete-preview">Preview delete</button>
        <button type="button" class="primary-action compact" data-action="bulk-delete-apply" ${state.bulkDeletePreview.length ? "" : "disabled"}>Apply delete</button>
      </div>
      <div class="stack-list compact-list">
        ${state.bulkDeletePreview.length ? `<p class="small-copy">${state.bulkDeletePreview.length} unpaid reservation${state.bulkDeletePreview.length === 1 ? "" : "s"} will be soft deleted with the Deleted flag.</p>` : `<p class="small-copy">Preview first, then apply. Deleted reservations are hidden from active views.</p>`}
        ${skippedPaidCount ? `<p class="small-copy"><strong>${skippedPaidCount} paid reservation${skippedPaidCount === 1 ? "" : "s"} protected and skipped.</strong> Mark paid reservations due before deleting them.</p>` : ""}
        ${state.bulkDeletePreview.slice(0, 12).map((booking) => renderBulkDeletePreviewRow(booking)).join("")}
      </div>
    </article>
  `;
}

function renderReportsTab() {
  const report = state.report;
  return `
    <article class="panel settings-panel">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">Reports</p>
          <h3>Reservation financial report</h3>
        </div>
        ${report ? `
          <div class="row-actions">
            <button type="button" data-action="print-report">Print</button>
            <button type="button" data-action="print-report-summary">Print Summary</button>
          </div>
        ` : ""}
      </div>
      <div class="admin-form-row invoice-filter-row">
        <label>
          Client
          <select data-report-filter="subjectId">
            <option value="">All clients</option>
            ${bulkSubjectOptions(state.reportFilters.subjectId)}
          </select>
        </label>
        <label>
          Start date
          <input data-report-filter="startDate" type="date" value="${state.reportFilters.startDate}">
        </label>
        <label>
          End date
          <input data-report-filter="endDate" type="date" value="${state.reportFilters.endDate}">
        </label>
        <button type="button" data-action="create-report">Create</button>
      </div>
      ${report ? renderReportOutput(report) : ""}
    </article>
  `;
}

function renderReportOutput(report) {
  return `
    <div class="report-print-area">
      <section class="report-section">
        <h4>Current/Past</h4>
        <div class="metric-row report-metric-row">
          ${metric(formatCurrency(report.currentPast.due), "Due")}
          ${metric(formatCurrency(report.currentPast.paid), "Paid")}
          ${metric(formatCurrency(report.currentPast.total), "Total")}
          ${metric(report.currentPast.reservations, "Reservations")}
          ${metric(formatDuration(report.currentPast.minutes), "Hours")}
        </div>
      </section>
      <section class="report-section">
        <h4>Future</h4>
        <div class="metric-row report-metric-row">
          ${metric(formatCurrency(report.future.amount), "Amount")}
          ${metric(report.future.reservations, "Reservations")}
          ${metric(formatDuration(report.future.minutes), "Hours")}
        </div>
      </section>
      <section class="report-section">
        <h4>Detail List</h4>
        <div class="invoice-table-wrap">
          <table class="invoice-table">
            <thead>
              <tr><th>Client</th><th>Date</th><th>Total Hours</th><th>Total Courts</th><th>Total Amount</th></tr>
            </thead>
            <tbody>
              ${report.detailRows.map((row) => `
                <tr>
                  <td>${escapeHtml(row.client)}</td>
                  <td>${formatReportDate(row.date)}</td>
                  <td>${formatDuration(row.minutes)}</td>
                  <td>${row.courts}</td>
                  <td>${formatCurrency(row.amount)}</td>
                </tr>
              `).join("") || `<tr><td colspan="5">No reservations match this report.</td></tr>`}
            </tbody>
          </table>
        </div>
      </section>
    </div>
  `;
}

function renderBulkOperationsList() {
  const operations = activeBulkReservationOperations();
  return `
      <div class="stack-list compact-list operation-list">
        ${operations.length ? operations.slice().reverse().map((operation) => renderBulkOperationRow(operation)).join("") : `<p class="small-copy">No created bulk reservation batches yet.</p>`}
      </div>
  `;
}

function renderBulkOperationRow(operation) {
  return `
    <div class="list-row bulk-operation-row">
      <span>
        <strong>${escapeHtml(operation.label ?? operation.operationType)}</strong>
        <small>${bulkOperationMeta(operation)}</small>
      </span>
      <div class="row-actions">
        <button type="button" data-action="bulk-operation-calendar" data-operation="${operation.id}">View on Calendar</button>
        <button type="button" data-action="bulk-delete-operation" data-operation="${operation.id}">Delete</button>
      </div>
    </div>
  `;
}

function bulkOperationMeta(operation) {
  const payload = operation.requestedPayload ?? {};
  const start = operation.startDate ?? payload.startDate;
  const end = operation.endDate ?? payload.endDate;
  const days = (payload.daysOfWeek ?? []).map(dayName).join(", ");
  const hours = payload.durationMinutes ? formatDuration(Number(payload.durationMinutes)) : "";
  return [operation.status, start && end ? `${formatShortDate(start)} - ${formatShortDate(end)}` : "", days, hours].filter(Boolean).join(" · ");
}

function renderBulkPreviewRow(item) {
  return `
    <div class="list-row">
      <span><strong>${item.resourceType === "court" ? labelCourt(item.courtId) : "Trainer gym"}</strong><small>${formatShortDate(item.start)} ${formatShortTime(item.start)}-${formatShortTime(item.end)}</small></span>
      <span class="status-pill is-due">${escapeHtml(item.conflictReason ?? "No Court Available")}</span>
    </div>
  `;
}

function renderBulkConflictRow(item) {
  return `
    <div class="list-row">
      <span><strong>${formatShortDate(item.start)}</strong><small>${formatShortTime(item.start)}-${formatShortTime(item.end)}</small></span>
    </div>
  `;
}

function renderBulkAvailabilityCalendar() {
  const months = bulkPreviewMonths();
  const statusByDate = bulkPreviewStatusByDate();
  return `
    <div class="calendar-popover" role="dialog" aria-label="Bulk availability calendar">
      <div class="calendar-popover-header">
        <strong>Bulk Availability</strong>
        <button type="button" data-action="bulk-calendar-close">Close</button>
      </div>
      <div class="calendar-legend">
        <span><i class="legend-open"></i> Available</span>
        <span><i class="legend-busy"></i> No Court Available</span>
      </div>
      <div class="multi-month-calendar">
        ${months.map((month) => renderBulkCalendarMonth(month, statusByDate)).join("")}
      </div>
    </div>
  `;
}

function renderAdminCalendarTab() {
  const calendar = state.adminCalendar;
  return `
    <article class="panel settings-panel admin-calendar">
      <div class="panel-heading">
        <div>
          <p class="eyebrow">Calendar</p>
          <h3>${formatMonthLabel(calendar.month)} · Eastern time</h3>
        </div>
        <div class="row-actions">
          <button type="button" data-action="calendar-previous">${calendar.mode === "day" ? "Previous day" : "Previous month"}</button>
          <button type="button" data-action="calendar-next">${calendar.mode === "day" ? "Next day" : "Next month"}</button>
        </div>
      </div>
      <div class="admin-form-row calendar-controls">
        <label>
          Month
          <select data-calendar="month">
            ${adminCalendarMonthOptions().map((month) => `<option value="${month}" ${calendar.month === month ? "selected" : ""}>${formatMonthLabel(month)}</option>`).join("")}
          </select>
        </label>
        <label>
          Day
          <input data-calendar="date" type="date" value="${calendar.date}">
        </label>
        <div class="segmented-actions" role="group" aria-label="Calendar view">
          <button type="button" class="${calendar.mode === "month" ? "active" : ""}" data-action="calendar-mode" data-mode="month">Month</button>
          <button type="button" class="${calendar.mode === "day" ? "active" : ""}" data-action="calendar-mode" data-mode="day">Day</button>
        </div>
      </div>
      ${calendar.mode === "month" ? renderAdminCalendarMonth() : ""}
      ${calendar.mode === "day" ? renderAdminCalendarDay() : ""}
    </article>
  `;
}

function renderAdminCalendarMonth() {
  const month = state.adminCalendar.month;
  const first = new Date(`${month}-01T12:00:00Z`);
  const year = first.getUTCFullYear();
  const monthIndex = first.getUTCMonth();
  const daysInMonth = new Date(Date.UTC(year, monthIndex + 1, 0)).getUTCDate();
  const offset = first.getUTCDay();
  const cells = [];
  for (let index = 0; index < offset; index += 1) {
    cells.push(`<span class="admin-calendar-day is-empty"></span>`);
  }
  for (let day = 1; day <= daysInMonth; day += 1) {
    const dateKey = `${month}-${String(day).padStart(2, "0")}`;
    const count = calendarBookingsForDate(dateKey).length;
    const closure = closureForDate(dateKey);
    const selected = state.adminCalendar.date === dateKey ? "is-selected" : "";
    const closedClass = closure ? "is-closed-day" : "";
    const label = closure ? `Closed: ${closure.reason ?? "Closed"}` : count ? `${count} reservation${count === 1 ? "" : "s"}` : "Open";
    cells.push(`
      <button type="button" class="admin-calendar-day ${selected} ${closedClass}" data-action="calendar-day" data-date="${dateKey}">
        <strong>${day}</strong>
        <small>${escapeHtml(label)}</small>
      </button>
    `);
  }
  return `
    <div class="admin-calendar-month">
      <div class="calendar-weekdays">${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map((day) => `<span>${day}</span>`).join("")}</div>
      <div class="admin-calendar-days">${cells.join("")}</div>
    </div>
  `;
}

function renderAdminCalendarDay() {
  const dateKey = state.adminCalendar.date;
  const hours = hoursForDate(dateKey);
  const closure = closureForDate(dateKey);
  if (!hours || hours.closed) {
    return `<p class="small-copy">Facility is closed on ${formatDateLabel(dateKey)}.</p>`;
  }
  const selectedBooking = bookingById(state.adminCalendar.selectedBookingId);
  const slots = calendarHourSlots(dateKey);
  const courts = Array.from({ length: state.settings.courtCount }, (_, index) => `court-${index + 1}`);
  const bookings = calendarBookingsForDate(dateKey);
  const halfHourCount = calendarHalfHourSlotCount(dateKey);
  return `
    <div class="calendar-day-heading">
      <strong>${formatDateLabel(dateKey)}</strong>
      <span>${formatTime(hours.open)} to ${formatTime(hours.close)} ET</span>
    </div>
    ${closure ? `<div class="closed-day-banner"><strong>Closed day</strong><span>${escapeHtml(closure.reason ?? "Closed")} · ${closureResourceLabel(closure)} · ${formatShortTime(closure.start)}-${formatShortTime(closure.end)}</span></div>` : ""}
    ${renderCalendarSelectionPanel(selectedBooking)}
    <div class="court-day-grid" style="--court-count: ${courts.length}; --half-hour-count: ${halfHourCount};">
      <div class="court-day-corner" style="grid-column: 1; grid-row: 1;">Time</div>
      ${courts.map((courtId, index) => `<div class="court-day-head" style="grid-column: ${index + 2}; grid-row: 1;">${labelCourt(courtId)}</div>`).join("")}
      ${slots.map((time) => renderCalendarTimeLabel(dateKey, time)).join("")}
      ${slots.flatMap((time) => courts.map((courtId, index) => renderCalendarHourOpenCell(dateKey, time, courtId, index))).join("")}
      ${bookings.map((booking) => renderCalendarBookingBlock(dateKey, booking, courts)).join("")}
    </div>
  `;
}

function renderCalendarSelectionPanel(selectedBooking) {
  const slot = state.adminCalendar.selectedSlot;
  if (selectedBooking) {
    const editable = isBookingEditable(selectedBooking);
    return `
      <div class="calendar-selection-panel">
        <span>
          <strong>${escapeHtml(bookingDisplayName(selectedBooking))}</strong>
          <small>${labelCourt(selectedBooking.courtId)} · ${formatShortDate(selectedBooking.start)} ${formatShortTime(selectedBooking.start)}-${formatShortTime(selectedBooking.end)}</small>
        </span>
        <div class="row-actions">
          <button type="button" data-action="calendar-edit-reservation" data-booking="${selectedBooking.id}" ${editable ? "" : "disabled"}>Edit</button>
          <button type="button" data-action="calendar-delete-reservation" data-booking="${selectedBooking.id}" ${editable ? "" : "disabled"}>Delete</button>
        </div>
        ${editable && state.adminCalendar.editingBookingId === selectedBooking.id ? renderCalendarReservationForm("calendar-save-edit", selectedBooking.id) : ""}
        ${editable ? "" : `<p class="small-copy">Past reservations are locked.</p>`}
      </div>
    `;
  }
  if (!slot) {
    return `<p class="small-copy">Select a future open slot to add a single team reservation, or select a reservation to edit/delete it.</p>`;
  }
  return `
    <div class="calendar-selection-panel">
      <span>
        <strong>Add reservation</strong>
        <small>${labelCourt(slot.courtId)} · ${formatShortDate(slot.date)} ${formatTime(slot.time)}</small>
      </span>
      ${renderCalendarReservationForm("calendar-add-reservation")}
    </div>
  `;
}

function renderCalendarReservationForm(action, bookingId = "") {
  const selectedClient = subjectById(state.bookingSubjectId);
  const requiresTeam = clientTypeHasTeams(selectedClient);
  return `
    <div class="admin-form-row calendar-reservation-form">
      <label>
        Client
        <select data-control="bookingSubjectId">
          <option value="">Select client</option>
          ${bulkSubjectOptions(state.bookingSubjectId)}
        </select>
      </label>
      ${requiresTeam ? `
        <label>
          Team
          <select data-control="bookingSubjectTeamId">
            ${subjectTeamOptions(state.bookingSubjectId, state.bookingSubjectTeamId)}
          </select>
        </label>
      ` : ""}
      ${bookingSeasonPriceOptions(state.bookingSubjectId).length ? `
        <label>
          Season price
          <select data-control="bookingSeasonPriceId">
            ${bookingSeasonPriceOptions(state.bookingSubjectId).map((price) => `<option value="${price.id}" ${selectedBookingSeasonPrice()?.id === price.id ? "selected" : ""}>${escapeHtml(seasonPriceLabel(price))} (${formatCurrency(price.hourlyRate)}/hr)</option>`).join("")}
          </select>
        </label>
      ` : ""}
      <label>
        Date
        <input data-control="date" type="date" min="${todayDateKey()}" value="${state.date}">
      </label>
      <label>
        Start
        <select data-control="time">
          ${bulkStartTimeOptions().map((time) => `<option value="${time}" ${state.time === time ? "selected" : ""}>${formatTime(time)}</option>`).join("")}
        </select>
      </label>
      <label>
        Duration
        <select data-control="durationMinutes">
          ${durationOptions(15, false).map((minutes) => `<option value="${minutes}" ${state.durationMinutes === minutes ? "selected" : ""}>${formatDuration(minutes)}</option>`).join("")}
        </select>
      </label>
      <label>
        Court
        <select data-control="selectedCourt">
          ${Array.from({ length: state.settings.courtCount }, (_, index) => `court-${index + 1}`).map((courtId) => `<option value="${courtId}" ${state.selectedCourt === courtId ? "selected" : ""}>${labelCourt(courtId)}</option>`).join("")}
        </select>
      </label>
      <button type="button" class="primary-action compact" data-action="${action}" ${bookingId ? `data-booking="${bookingId}"` : ""}>${action === "calendar-save-edit" ? "Save Reservation" : "Add Reservation"}</button>
    </div>
  `;
}

function renderCalendarSlot(dateKey, time, courtId) {
  const booking = bookingForCourtSlot(dateKey, time, courtId);
  if (booking) {
    return `
      <button type="button" class="court-day-slot is-booked" data-action="calendar-reservation" data-booking="${booking.id}" title="${escapeHtml(calendarBookingTitle(booking))}">
        <strong>${escapeHtml(bookingDisplayName(booking))}</strong>
        <small>${formatShortTime(booking.start)}-${formatShortTime(booking.end)}</small>
      </button>
    `;
  }
  const editable = isFutureSlot(dateKey, time);
  return `
    <button type="button" class="court-day-slot ${editable ? "is-open" : "is-past"}" data-action="calendar-slot" data-date="${dateKey}" data-time="${time}" data-court="${courtId}" ${editable ? "" : "disabled"}>
      ${editable ? "Open" : ""}
    </button>
  `;
}

function renderCalendarTimeLabel(dateKey, time) {
  return `
    <div class="court-day-time" style="grid-column: 1; ${calendarHourGridRowStyle(dateKey, time)}">${formatTime(time)}</div>
  `;
}

function renderCalendarHourOpenCell(dateKey, time, courtId, courtIndex) {
  const editable = isFutureSlot(dateKey, time);
  const closed = closureBlocksSlot(dateKey, time, addMinutes(time, state.settings.slotIntervalMinutes), "court", courtId);
  return `
    <button type="button" class="court-day-slot ${closed ? "is-closed-day" : editable ? "is-open" : "is-past"}" style="grid-column: ${courtIndex + 2}; ${calendarHourGridRowStyle(dateKey, time)}" data-action="calendar-slot" data-date="${dateKey}" data-time="${time}" data-court="${courtId}" ${editable ? "" : "disabled"}>
      ${closed ? "Closed" : editable ? "Open" : ""}
    </button>
  `;
}

function renderCalendarBookingBlock(dateKey, booking, courts) {
  const courtIndex = courts.indexOf(booking.courtId);
  if (courtIndex < 0) {
    return "";
  }
  return `
    <button type="button" class="calendar-booking-block" style="grid-column: ${courtIndex + 2}; ${calendarBookingGridRowStyle(dateKey, booking)}" data-action="calendar-reservation" data-booking="${booking.id}" title="${escapeHtml(calendarBookingTitle(booking))}">
      <strong>${escapeHtml(bookingDisplayName(booking))}</strong>
      <small>${formatShortTime(booking.start)}-${formatShortTime(booking.end)} · ${paymentAmountLabel(bookingAmount(booking))}</small>
    </button>
  `;
}

function renderBulkCalendarMonth(month, statusByDate) {
  const first = new Date(`${month}-01T12:00:00Z`);
  const year = first.getUTCFullYear();
  const monthIndex = first.getUTCMonth();
  const daysInMonth = new Date(Date.UTC(year, monthIndex + 1, 0)).getUTCDate();
  const offset = first.getUTCDay();
  const cells = [];
  for (let index = 0; index < offset; index += 1) {
    cells.push(`<span class="calendar-day is-empty"></span>`);
  }
  for (let day = 1; day <= daysInMonth; day += 1) {
    const dateKey = `${month}-${String(day).padStart(2, "0")}`;
    const info = statusByDate.get(dateKey);
    const closure = closureForDate(dateKey);
    const className = closure ? "is-closed-day" : info?.status === "conflict" ? "is-busy" : info?.status === "available" ? "is-open" : "";
    const title = closure ? `Closed: ${closure.reason ?? "Closed"}` : info?.title ?? "";
    cells.push(`<span class="calendar-day ${className}" title="${escapeHtml(title)}">${day}</span>`);
  }
  return `
    <section class="calendar-month">
      <h4>${new Intl.DateTimeFormat("en-US", { month: "long", year: "numeric" }).format(first)}</h4>
      <div class="calendar-weekdays">${["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"].map((day) => `<span>${day}</span>`).join("")}</div>
      <div class="calendar-days">${cells.join("")}</div>
    </section>
  `;
}

function renderBookingAdminRow(booking) {
  return `
    <div class="list-row">
      <span><strong>${escapeHtml(bookingDisplayName(booking))}</strong><small>${booking.resourceType === "court" ? labelCourt(booking.courtId) : "Trainer gym"} ${formatShortDate(booking.start)} ${formatShortTime(booking.start)}-${formatShortTime(booking.end)}</small></span>
      <span class="status-pill ${isBookingPaid(booking) ? "is-open" : "is-due"}">${isBookingPaid(booking) ? "paid" : "due"}</span>
    </div>
  `;
}

function renderBulkDeletePreviewRow(booking) {
  return `
    <div class="list-row">
      <span><strong>${escapeHtml(bookingDisplayName(booking))}</strong><small>${booking.resourceType === "court" ? labelCourt(booking.courtId) : "Trainer gym"} ${formatShortDate(booking.start)} ${formatShortTime(booking.start)}-${formatShortTime(booking.end)}</small></span>
    </div>
  `;
}

function renderAdminSettings() {
  return `
    <article class="panel settings-panel">
      <div class="settings-workspace">
        <nav class="settings-menu" aria-label="Settings sections">
          ${settingsMenuButton("configuration", "Configuration")}
          ${settingsMenuButton("business-hours", "Business Hours")}
          ${settingsMenuButton("closed-days", "Closed Days")}
          ${settingsMenuButton("email-templates", "Email Templates")}
          ${settingsMenuButton("client-types", "Client Types")}
          ${settingsMenuButton("seasons", "Seasons")}
        </nav>
        <div class="settings-content">
          ${state.settingsTab === "configuration" ? renderConfigurationSettings() : ""}
          ${state.settingsTab === "business-hours" ? renderBusinessHoursSettings() : ""}
          ${state.settingsTab === "closed-days" ? renderClosedDaysSettings() : ""}
          ${state.settingsTab === "email-templates" ? renderEmailTemplatesSettings() : ""}
          ${state.settingsTab === "client-types" ? renderClientTypesSettings() : ""}
          ${state.settingsTab === "seasons" ? renderSeasonsSettings() : ""}
        </div>
      </div>
      ${["configuration", "business-hours", "email-templates"].includes(state.settingsTab) ? `<div class="button-row settings-actions two-actions">
        <button type="button" class="primary-action compact" data-action="save-admin-settings">Save</button>
      </div>` : ""}
    </article>
  `;
}

function settingsMenuButton(tab, label) {
  return `<button type="button" class="${state.settingsTab === tab ? "active" : ""}" data-settings-tab="${tab}">${label}</button>`;
}

function settingsTabTitle(tab) {
  return {
    "configuration": "Facility configuration",
    "business-hours": "Business hours",
    "closed-days": "Closed days",
    "email-templates": "Email Templates",
    "client-types": "Client Types",
    "seasons": "Seasons"
  }[tab] ?? "Facility settings";
}

function renderConfigurationSettings() {
  return `
      <div class="setting-grid editable-settings">
        <label>
          Court hourly rate
          <input data-config="courtHourlyRate" type="number" min="0" step="1" value="${state.settings.pricing.courtHourlyRate}">
        </label>
        <label>
          Gym hourly rate
          <input data-config="gymHourlyRate" type="number" min="0" step="1" value="${state.settings.pricing.gymHourlyRate}">
        </label>
        <label>
          Courts
          <input data-config="courtCount" type="number" min="1" max="20" step="1" value="${state.settings.courtCount}">
        </label>
        <label>
          Gym coaching capacity
          <input data-config="trainerCapacity" type="number" min="1" max="10" step="1" value="${state.settings.trainerCapacity}">
        </label>
        <label>
          Admin email
          <input data-config="adminEmail" type="email" value="${escapeHtml(state.settings.adminEmail)}" placeholder="admin@example.com">
        </label>
        <label>
          Message Display time (seconds)
          <input data-config="messageDisplaySeconds" type="number" min="1" max="60" step="1" value="${state.settings.messageDisplaySeconds}">
        </label>
      </div>
  `;
}

function renderEmailTemplatesSettings() {
  return `
    <div class="template-help">
      <strong>Template tokens</strong>
      <p>Use tokens like <code>&lt;teamname&gt;</code>, <code>&lt;reservationdate&gt;</code>, <code>&lt;starttime&gt;</code>, <code>&lt;endtime&gt;</code>, <code>&lt;courts&gt;</code>, <code>&lt;invoicenumber&gt;</code>, and <code>&lt;amountdue&gt;</code>. When an email is created, the token text is replaced with the actual value.</p>
    </div>
    <div class="template-grid">
      ${renderEmailTemplateEditor("reservationReminder", "Reservation Reminder")}
      ${renderEmailTemplateEditor("invoice", "Invoice")}
    </div>
  `;
}

function renderEmailTemplateEditor(templateKey, label) {
  const template = state.settings.emailTemplates[templateKey] ?? { subject: "", body: "" };
  return `
    <section class="template-editor">
      <h4>${label}</h4>
      <label>
        Subject
        <input data-email-template="${templateKey}" data-template-field="subject" value="${escapeHtml(template.subject)}">
      </label>
      <label>
        Body
        <textarea data-email-template="${templateKey}" data-template-field="body" rows="8">${escapeHtml(template.body)}</textarea>
      </label>
    </section>
  `;
}

function renderBusinessHoursSettings() {
  return `
      <div class="hours-grid compact-hours-grid">
        ${Object.entries(state.settings.operatingHours).map(([dayIndex, hours]) => `
          <div class="hours-row">
            <strong>${dayName(Number(dayIndex))}</strong>
            <label>
              Open
              <input data-config="hours-open" data-day="${dayIndex}" type="time" step="1800" value="${hours.open}">
            </label>
            <label>
              Close
              <input data-config="hours-close" data-day="${dayIndex}" type="time" step="1800" value="${hours.close}">
            </label>
          </div>
        `).join("")}
      </div>
  `;
}

function renderClosedDaysSettings() {
  const closure = state.closureForm;
  return `
      <div class="admin-form-row closure-row">
        <label>
          Scope
          <select data-closure="resourceType">
            <option value="all" ${closure.resourceType === "all" ? "selected" : ""}>Facility</option>
            <option value="court" ${closure.resourceType === "court" ? "selected" : ""}>Court</option>
            <option value="trainer" ${closure.resourceType === "trainer" ? "selected" : ""}>Trainer gym</option>
          </select>
        </label>
        ${closure.resourceType === "court" ? `
          <label>
            Court
            <select data-closure="courtId">
              <option value="">All courts</option>
              ${Array.from({ length: state.settings.courtCount }, (_, index) => `court-${index + 1}`).map((courtId) => `<option value="${courtId}" ${closure.courtId === courtId ? "selected" : ""}>${labelCourt(courtId)}</option>`).join("")}
            </select>
          </label>
        ` : ""}
        <label>
          Start date
          <input data-closure="startDate" type="date" value="${closure.startDate}">
        </label>
        <label>
          End date
          <input data-closure="endDate" type="date" value="${closure.endDate}">
        </label>
        <label>
          Start
          <input data-closure="startTime" type="time" value="${closure.startTime}">
        </label>
        <label>
          End
          <input data-closure="endTime" type="time" value="${closure.endTime}">
        </label>
        <label>
          Reason
          <input data-closure="reason" value="${escapeHtml(closure.reason)}" placeholder="Holiday, maintenance, tournament">
        </label>
        <button type="button" data-action="create-closure">Add Closed Day</button>
      </div>
      <div class="stack-list">
        ${state.settings.closures.length ? state.settings.closures.map((closure) => `
          <div class="list-row">
            <span>
              <strong>${escapeHtml(closure.reason ?? "Closed")}</strong>
              <small>${closureResourceLabel(closure)} ${formatShortDate(closure.start)} ${formatShortTime(closure.start)}-${formatShortTime(closure.end)}</small>
            </span>
            <div class="row-actions">
              <button type="button" data-action="delete-closure" data-closure="${closure.id}">Delete</button>
            </div>
          </div>
        `).join("") : `<p class="small-copy">No closed days configured.</p>`}
      </div>
  `;
}

function renderClientTypesSettings() {
  const clientTypes = activeClientTypes();
  return `
    <div class="admin-form-row client-type-row">
      <label>
        Name
        <input data-client-type="name" value="${escapeHtml(state.clientTypeForm.name)}" placeholder="Club">
      </label>
      <label class="checkbox-label">
        <input data-client-type="haveTeams" type="checkbox" ${state.clientTypeForm.haveTeams ? "checked" : ""}>
        Has teams
      </label>
      <button type="button" data-action="create-client-type">Create Type</button>
    </div>
    <div class="stack-list">
      ${clientTypes.map((clientType) => state.editingClientTypeId === clientType.id ? renderClientTypeEditRow(clientType) : renderClientTypeRow(clientType)).join("") || `<p class="small-copy">No client types configured.</p>`}
    </div>
  `;
}

function renderClientTypeRow(clientType) {
  return `
    <div class="list-row user-row">
      <span>
        <strong>${escapeHtml(clientType.name)}</strong>
        <small>${clientType.haveTeams ? "Has teams" : "No team list"}</small>
      </span>
      <div class="row-actions">
        <button type="button" data-action="edit-client-type" data-client-type="${clientType.id}">Edit</button>
        <button type="button" data-action="delete-client-type" data-client-type="${clientType.id}">Delete</button>
      </div>
    </div>
  `;
}

function renderClientTypeEditRow(clientType) {
  return `
    <div class="list-row user-row edit-row client-type-row">
      <label>
        Name
        <input data-edit-client-type="name" value="${escapeHtml(state.editClientTypeForm.name)}">
      </label>
      <label class="checkbox-label">
        <input data-edit-client-type="haveTeams" type="checkbox" ${state.editClientTypeForm.haveTeams ? "checked" : ""}>
        Has teams
      </label>
      <div class="row-actions">
        <button type="button" class="primary-action compact" data-action="save-client-type" data-client-type="${clientType.id}">Save</button>
        <button type="button" data-action="cancel-edit-client-type">Cancel</button>
      </div>
    </div>
  `;
}

function renderTeamSeasonsSettings() {
  const teamPrices = filteredSeasonPrices();
  const selectedYear = selectedSeasonPriceYearFilter();
  return `
      <div class="admin-form-row season-price-row">
        <label>
          Client
          <select data-season-price="subjectId">
            ${teamSubjectOptions(state.seasonPriceForm.subjectId)}
          </select>
        </label>
        <label>
          Season
          <select data-season-price="seasonId">
            ${seasonOptions(state.seasonPriceForm.seasonId)}
          </select>
        </label>
        <label>
          Hourly price
          <input data-season-price="hourlyRate" type="number" min="0" step="1" value="${state.seasonPriceForm.hourlyRate}">
        </label>
        <label>
          Deposit
          <input data-season-price="deposit" type="number" min="0" step="1" value="${state.seasonPriceForm.deposit ?? 0}">
        </label>
        <label class="checkbox-label">
          <input data-season-price="documentsReceived" type="checkbox" ${state.seasonPriceForm.documentsReceived ? "checked" : ""}>
          Documents
        </label>
        <button type="button" data-action="create-season-price">Create</button>
      </div>
      <div class="admin-form-row season-filter-row">
        <label>
          Filter by year
          <select data-season-price-filter="year">
            ${seasonPriceYearOptions().map((year) => `<option value="${year}" ${selectedYear === year ? "selected" : ""}>${year}</option>`).join("")}
          </select>
        </label>
      </div>
      <div class="stack-list">
        ${teamPrices.length ? teamPrices.map((price) => state.editingSeasonPriceId === price.id ? renderSeasonPriceEditRow(price) : renderSeasonPriceRow(price)).join("") : `<p class="small-copy">No club seasons configured.</p>`}
      </div>
      <p class="small-copy">Reservations store the selected season and hourly price at creation time, so future price changes do not rewrite old payment calculations.</p>
  `;
}

function renderSeasonsSettings() {
  const seasons = activeSeasons();
  return `
      <div class="admin-form-row season-row">
        <label>
          Start year
          <input data-season-record="startYear" type="number" min="2020" max="2100" step="1" value="${state.seasonForm.startYear}">
        </label>
        <button type="button" data-action="create-season">Create season</button>
      </div>
      <div class="stack-list">
        ${seasons.length ? seasons.map((season) => state.editingSeasonId === season.id ? renderSeasonEditRow(season) : renderSeasonRow(season)).join("") : `<p class="small-copy">No seasons configured.</p>`}
      </div>
      <p class="small-copy">Season display names are stored with the season record. The start year remains the stable value for sorting and defaults.</p>
  `;
}

function renderSeasonRow(season) {
  return `
    <div class="list-row user-row">
      <span>
        <strong>${escapeHtml(season.displayName)}</strong>
        <small>Starts ${season.startYear}</small>
      </span>
      <div class="row-actions">
        <button type="button" data-action="edit-season" data-season="${season.id}">Edit</button>
        <button type="button" data-action="delete-season" data-season="${season.id}">Delete</button>
      </div>
    </div>
  `;
}

function renderSeasonEditRow(season) {
  return `
    <div class="list-row user-row edit-row season-edit-row">
      <label>
        Start year
        <input data-edit-season-record="startYear" type="number" min="2020" max="2100" step="1" value="${state.editSeasonForm.startYear}">
      </label>
      <label>
        Display as
        <input data-edit-season-record="displayName" value="${escapeHtml(state.editSeasonForm.displayName)}">
      </label>
      <div class="row-actions">
        <button type="button" class="primary-action compact" data-action="save-season" data-season="${season.id}">Save</button>
        <button type="button" data-action="cancel-edit-season">Cancel</button>
      </div>
    </div>
  `;
}

function renderSeasonPriceRow(price) {
  return `
    <div class="list-row user-row">
      <span>
        <strong>${escapeHtml(price.teamName ?? subjectById(price.subjectId)?.displayName ?? "Team")}</strong>
        <small>${escapeHtml(seasonPriceLabel(price))}${price.documentsReceived ? " · documents received" : " · documents missing"} · Deposit ${formatCurrency(price.deposit ?? 0)}</small>
      </span>
      <span class="status-pill is-open">${formatCurrency(price.hourlyRate)}/hr</span>
      <div class="row-actions">
        <button type="button" data-action="edit-season-price" data-price="${price.id}">Edit</button>
        <button type="button" data-action="delete-season-price" data-price="${price.id}">Delete</button>
      </div>
    </div>
  `;
}

function renderSeasonPriceEditRow(price) {
  return `
    <div class="list-row user-row edit-row season-price-edit-row">
      <label>
        Client
        <select data-edit-season-price="subjectId">
          ${teamSubjectOptions(state.editSeasonPriceForm.subjectId)}
        </select>
      </label>
      <label>
        Season
        <select data-edit-season-price="seasonId">
          ${seasonOptions(state.editSeasonPriceForm.seasonId)}
        </select>
      </label>
      <label>
        Hourly price
        <input data-edit-season-price="hourlyRate" type="number" min="0" step="1" value="${state.editSeasonPriceForm.hourlyRate}">
      </label>
      <label>
        Deposit
        <input data-edit-season-price="deposit" type="number" min="0" step="1" value="${state.editSeasonPriceForm.deposit ?? 0}">
      </label>
      <label class="checkbox-label">
        <input data-edit-season-price="documentsReceived" type="checkbox" ${state.editSeasonPriceForm.documentsReceived ? "checked" : ""}>
        Documents
      </label>
      <div class="row-actions">
        <button type="button" class="primary-action compact" data-action="save-season-price" data-price="${price.id}">Save</button>
        <button type="button" data-action="cancel-edit-season-price">Cancel</button>
      </div>
    </div>
  `;
}

function renderCourtMap(readOnly) {
  const availability = getCurrentAvailability();
  return `
    <div class="court-map">
      ${availability.courts.map((court) => {
        const blocker = court.blockers?.[0];
        const status = court.available ? "Open" : isAdminSession() && blocker ? formatBlocker(blocker) : "Reserved";
        const disabled = readOnly || !isApprovedMember() ? "disabled" : "";
        return `
          <button type="button" class="court-tile ${court.available ? "open" : "busy"}" data-court="${court.courtId}" ${disabled}>
            <span>${labelCourt(court.courtId)}</span>
            <strong>${status}</strong>
          </button>
        `;
      }).join("")}
      <div class="trainer-tile ${availability.trainer.available ? "open" : "busy"}">
        <span>Trainer gym</span>
        <strong>${availability.trainer.availableSlots}/${state.settings.trainerCapacity} open</strong>
      </div>
    </div>
  `;
}

function navButton(view, label) {
  return `<button type="button" class="${state.view === view ? "active" : ""}" data-view="${view}">${label}</button>`;
}

function metric(value, label, icon) {
  return `<div class="metric">${icon ? `<i class="ph-bold ph-${icon} metric-icon"></i>` : ""}<span class="metric-body"><strong>${value}</strong><span>${label}</span></span></div>`;
}

function program(title, copy, meta, action) {
  return `
    <article class="program-card">
      <span>${meta}</span>
      <h3>${title}</h3>
      <p>${copy}</p>
      <button type="button" data-view="${isApprovedMember() ? "book" : "login"}">${action}</button>
    </article>
  `;
}

function socialButton(provider) {
  return `<button type="button" class="secondary-action" data-social-provider="${provider}">${provider}</button>`;
}

function renderMobileNav() {
  const buttons = [
    navButton("home", "Home"),
    navButton("programs", "Programs"),
    isApprovedMember() ? navButton("schedule", "Schedule") : "",
    isApprovedMember() ? navButton("book", "Reserve") : "",
    isAdminSession() ? navButton("admin", "Admin") : "",
    !state.user ? navButton("login", "Log in") : ""
  ].filter(Boolean);

  return `<nav class="mobile-nav" aria-label="Mobile primary">${buttons.join("")}</nav>`;
}

async function initializeApp() {
  if (shouldUseLiveAuth() && supabase) {
    supabase.auth.onAuthStateChange((event) => {
      if (event === "PASSWORD_RECOVERY") {
        state.view = "reset-password";
        render();
      }
    });
  }

  if (shouldUseLiveAuth()) {
    clearLiveAdminData();
    await restoreSupabaseSession();
    await loadPublicFacilityInfo();
  }

  ensureAllowedView();
  render();
}

async function restoreSupabaseSession() {
  const { data, error } = await supabase.auth.getSession();
  if (error) {
    state.notice = "Could not restore your login session.";
    return;
  }

  if (data.session?.user) {
    await applySupabaseUser(data.session.user);
  }
}

async function signIn(formData) {
  state.loginId = String(formData.get("loginId") ?? "").trim();
  state.loginPassword = String(formData.get("password") ?? "");

  if (shouldUseLiveAuth()) {
    const { data, error } = await supabase.auth.signInWithPassword({
      email: state.loginId,
      password: state.loginPassword
    });

    state.loginPassword = "";

    if (error) {
      state.notice = "The email or password does not match an account.";
      render();
      return;
    }

    const profileLoaded = await applySupabaseUser(data.user);
    if (!profileLoaded) {
      render();
      return;
    }

    state.notice = `Signed in as ${state.user.name}.`;
    setView(isAdminSession() ? "admin" : isApprovedMember() ? "schedule" : "home");
    return;
  }

  if (!isLocalPreview) {
    state.loginPassword = "";
    state.notice = "Production authentication needs Supabase environment variables.";
    render();
    return;
  }

  const loginKey = state.loginId.toLowerCase();
  const user = demoUsers.find((candidate) => candidate.username === loginKey || candidate.email === loginKey);
  if (!user || user.password !== state.loginPassword) {
    state.notice = "The username or password does not match an account.";
    render();
    return;
  }

  state.user = { ...user };
  state.loginPassword = "";
  state.notice = user.approved || user.role === "admin"
    ? `Signed in as ${user.name}.`
    : "Signed in. Your account is waiting for approval.";
  setView(user.role === "admin" ? "admin" : user.approved ? "schedule" : "home");
}

async function signUp(formData) {
  state.signupForm.email = String(formData.get("email") ?? "").trim();
  state.signupForm.password = String(formData.get("password") ?? "");
  state.signupForm.username = String(formData.get("username") ?? "").trim();
  state.signupForm.displayName = String(formData.get("displayName") ?? "").trim();
  state.signupForm.teamName = String(formData.get("teamName") ?? "").trim();

  if (!state.signupForm.email || !state.signupForm.password || !state.signupForm.username || !state.signupForm.displayName) {
    state.notice = "Email, password, username, and display name are required.";
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    const { error } = await supabase.auth.signUp({
      email: state.signupForm.email,
      password: state.signupForm.password,
      options: {
        emailRedirectTo: window.location.origin,
        data: {
          username: state.signupForm.username,
          display_name: state.signupForm.displayName,
          team_name: state.signupForm.teamName
        }
      }
    });

    state.signupForm.password = "";

    if (error) {
      state.notice = readableSupabaseError(error, "Could not create account.");
      render();
      return;
    }

    state.notice = "Account created. An admin must approve it before reservations are available.";
    setView("login");
    return;
  }

  state.notice = "Sign-up uses Supabase Auth. Use staging or production mode to create a real account.";
  render();
}

async function signOut() {
  if (shouldUseLiveAuth()) {
    await supabase.auth.signOut();
    clearLiveAdminData();
  }

  state.user = null;
  state.notice = "Signed out.";
  setView("home");
}

async function applySupabaseUser(authUser) {
  const { data: profile, error } = await supabase
    .from("profiles")
    .select("id, username, email, display_name, team_name, account_role, approval_status")
    .eq("id", authUser.id)
    .eq("Deleted", 0)
    .single();

  if (error || !profile) {
    state.user = null;
    state.notice = "Login succeeded, but this account does not have an A2Z profile yet.";
    return false;
  }

  state.user = {
    id: profile.id,
    username: profile.username,
    email: profile.email,
    authenticated: true,
    approved: profile.approval_status === "approved",
    role: profile.account_role,
    name: profile.display_name,
    team: profile.team_name
  };

  if (isAdminSession()) {
    await loadAdminDashboard();
  } else if (isApprovedMember()) {
    await loadMemberPortal();
  }

  return true;
}

async function bookSelectedSlot(options = {}) {
  if (!isApprovedMember() && !isAdminSession()) {
    state.notice = "Approved member login is required before reserving.";
    setView("login");
    return;
  }

  if (shouldUseLiveAuth() && isAdminSession() && state.bookingSubjectId) {
    const payload = buildSingleReservationRequest({ allowClosedDay: Boolean(options.allowClosedDay) });
    const { data, error } = await supabase.rpc("admin_create_single_reservation", { payload });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not create reservation.");
      setView(isAdminSession() ? "admin" : "schedule");
      return;
    }
    await loadAdminDashboard();
    state.notice = data?.id ? "Reservation created." : "1 reservation created.";
    setView("admin");
    return;
  }

  if (shouldUseLiveAuth() && isApprovedMember()) {
    const context = memberContextByKey(state.bookingContextKey);
    if (!context) {
      state.notice = "Your account is not linked to a club or coach profile yet. Please contact the front desk.";
      render();
      return;
    }
    const payload = {
      bookingType: context.type,
      subjectId: context.subjectId,
      subjectTeamId: context.teamId ?? null,
      resourceType: state.resourceType,
      courtId: state.resourceType === "court" ? state.selectedCourt : null,
      startDate: state.date,
      startTime: state.time,
      durationMinutes: state.durationMinutes,
      lessonPlayerBracket: context.type === "private" ? state.lessonBracket : null
    };
    if (state.editingReservationId) {
      const { error } = await supabase.rpc("member_update_reservation", {
        p_reservation_id: state.editingReservationId,
        payload
      });
      if (error) {
        state.notice = readableSupabaseError(error, "Could not update the reservation.");
        render();
        return;
      }
      state.editingReservationId = null;
      await loadMemberPortal();
      state.notice = "Reservation updated.";
      setView("my-bookings");
      return;
    }
    const { error } = await supabase.rpc("member_create_reservation", { payload });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not create the reservation.");
      render();
      return;
    }
    await loadMemberPortal();
    state.notice = "Reservation confirmed. The invoice will follow by email.";
    setView("my-bookings");
    return;
  }

  try {
    const scheduler = buildScheduler();
    const subject = subjectById(state.bookingSubjectId);
    const seasonPrice = selectedBookingSeasonPrice();
    const booking = scheduler.createBooking({
      userId: subject ? state.bookingSubjectId : undefined,
      subjectId: subject?.id,
      teamId: subject?.displayName,
      resourceType: state.resourceType,
      courtId: state.resourceType === "court" ? state.selectedCourt : null,
      start: toIso(state.date, state.time),
      end: toIso(state.date, addMinutes(state.time, state.durationMinutes)),
      paymentStatus: "due",
      seasonPriceId: seasonPrice?.id,
      seasonLabel: seasonPrice ? seasonPriceLabel(seasonPrice) : null,
      hourlyRate: seasonPrice?.hourlyRate,
      amount: seasonPrice ? seasonPrice.hourlyRate * (state.durationMinutes / 60) : null
    }, state.user);
    state.bookings = scheduler.bookings.map(storeBooking);
    state.notice = `${booking.resourceType === "court" ? labelCourt(booking.courtId) : "Trainer gym"} reserved. Payment is due.`;
    if (isAdminSession()) {
      state.adminTab = "calendar";
      setView("admin");
    } else {
      setView("my-bookings");
    }
  } catch (error) {
    state.notice = error.message;
    setView(isAdminSession() ? "admin" : "schedule");
  }
}

async function loadAdminDashboard() {
  if (!shouldUseLiveAuth() || !isAdminSession()) {
    return;
  }

  const { data, error } = await supabase.rpc("admin_get_dashboard");
  if (error) {
    state.notice = readableSupabaseError(error, "Could not load admin data.");
    return;
  }

  applyAdminDashboard(data);
}

function applyAdminDashboard(data) {
  if (!data) {
    return;
  }

  const liveUsers = data.users ?? data.allUsers ?? [];
  state.settings = normalizeLiveSettings(data.settings);
  state.allUsers = liveUsers;
  state.pendingUsers = data.pendingUsers ?? liveUsers.filter((user) => (user.approvalStatus ?? user.approval_status) === "pending");
  state.bookings = (data.bookings ?? []).map(storeBooking);
  state.clientTypes = (data.clientTypes ?? state.clientTypes).map(normalizeClientType);
  state.adminSubjects = mergeSubjectTeams(
    (data.adminSubjects ?? []).map(normalizeSubject),
    (data.subjectTeams ?? data.adminSubjectTeams ?? []).map(normalizeSubjectTeam)
  );
  state.seasons = (data.seasons ?? []).map(normalizeSeason);
  state.teamSeasonPrices = (data.teamSeasonPrices ?? []).map(normalizeSeasonPrice);
  state.bulkOperations = data.bulkOperations ?? [];
  state.invoices = (data.invoices ?? state.invoices).map(normalizeInvoice);
  state.payments = (data.payments ?? state.payments).map(normalizePaymentRecord);
  state.adminAllMenuItems = (data.adminAllMenuItems ?? data.allAdminMenuItems ?? data.adminMenuItems ?? state.adminAllMenuItems).map(normalizeAdminMenuItem);
  state.adminMenuItems = (data.adminMenuItems ?? state.adminMenuItems).map(normalizeAdminMenuItem);
  state.adminMenuRights = (data.adminMenuRights ?? data.adminMenuPermissions ?? state.adminMenuRights).map(normalizeAdminMenuRight);
  ensureSelectedSubject();
  ensureAdminTabAvailable();
}

function clearLiveAdminData() {
  state.allUsers = [];
  state.pendingUsers = [];
  state.bookings = [];
  state.adminSubjects = [];
  state.seasons = [];
  state.teamSeasonPrices = [];
  state.bulkPreview = null;
  state.bulkDeletePreview = [];
  state.bulkDeleteSkippedPaid = [];
  state.bulkOperations = [];
  state.invoices = [];
  state.payments = [];
  state.adminAllMenuItems = defaultAdminMenuItems.map((item) => ({ ...item }));
  state.adminMenuItems = defaultAdminMenuItems.map((item) => ({ ...item }));
  state.adminMenuRights = [];
}

async function approvePendingUser(userId) {
  if (!isAdminSession()) {
    return;
  }

  if (shouldUseLiveAuth()) {
    if (!isUuid(userId)) {
      state.notice = "This account is not loaded from Supabase yet. Refresh admin data and try again.";
      render();
      return;
    }
    const { error } = await supabase.rpc("admin_approve_profile", { p_profile_id: userId });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not approve account.");
      render();
      return;
    }
    await loadAdminDashboard();
    state.editingUserId = null;
    state.notice = "Registration approved.";
    render();
    return;
  }

  const user = demoUsers.find((candidate) => candidate.id === userId);
  if (user) {
    user.approved = true;
    user.approvalStatus = "approved";
  }
  state.allUsers = state.allUsers.map((candidate) => candidate.id === userId ? { ...candidate, approved: true, approvalStatus: "approved" } : candidate);
  state.pendingUsers = state.pendingUsers.filter((pending) => pending.id !== userId);
  state.notice = "Registration approved.";
  render();
}

async function rejectUser(userId) {
  if (!isAdminSession()) {
    return;
  }

  if (shouldUseLiveAuth()) {
    if (!isUuid(userId)) {
      state.notice = "This account is not loaded from Supabase yet. Refresh admin data and try again.";
      render();
      return;
    }
    const { error } = await supabase.rpc("admin_reject_profile", { p_profile_id: userId });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not reject account.");
      render();
      return;
    }
    await loadAdminDashboard();
    state.editingUserId = null;
    state.notice = "Registration rejected.";
    render();
    return;
  }

  state.allUsers = state.allUsers.map((candidate) => candidate.id === userId ? { ...candidate, approved: false, approvalStatus: "rejected" } : candidate);
  state.pendingUsers = state.pendingUsers.filter((pending) => pending.id !== userId);
  state.notice = "Registration rejected.";
  render();
}

async function disableUser(userId) {
  if (isCurrentAdminUser(userId)) {
    state.notice = "You cannot disable your own admin account.";
    render();
    return;
  }
  if (!window.confirm("Disable this approved user? They will move to Rejected / disabled and can be approved again later.")) {
    return;
  }
  await rejectUser(userId);
  state.notice = "User disabled.";
  render();
}

function startEditUser(userId) {
  const user = adminUsers().find((candidate) => candidate.id === userId);
  if (!user) {
    return;
  }

  state.editingUserId = user.id;
  state.editingUserRightsId = null;
  state.editUserForm = {
    name: user.name,
    role: user.role ?? "user"
  };
  render();
}

function cancelEditUser() {
  state.editingUserId = null;
  render();
}

async function saveUser(userId) {
  if (!isAdminSession()) {
    return;
  }

  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_update_profile", {
      p_profile_id: userId,
      payload: {
        displayName: state.editUserForm.name,
        accountRole: state.editUserForm.role
      }
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not update user.");
      render();
      return;
    }
    await loadAdminDashboard();
    state.editingUserId = null;
    state.notice = "User updated.";
    render();
    return;
  }

  state.allUsers = state.allUsers.map((user) => user.id === userId ? {
    ...user,
    name: state.editUserForm.name,
    role: state.editUserForm.role
  } : user);
  state.editingUserId = null;
  state.notice = "User updated.";
  render();
}

function startEditAdminRights(userId) {
  const user = adminUsers().find((candidate) => candidate.id === userId);
  if (!user || user.role !== "admin") {
    return;
  }

  state.editingUserId = null;
  state.editingUserRightsId = user.id;
  state.editUserRightsForm = adminRightsFormForUser(user.id);
  render();
}

function cancelEditAdminRights() {
  state.editingUserRightsId = null;
  state.editUserRightsForm = {};
  render();
}

async function saveAdminRights(userId) {
  if (!isAdminSession()) {
    return;
  }

  const enabledMenuKeys = allActiveAdminMenuItems()
    .filter((item) => state.editUserRightsForm[item.key])
    .map((item) => item.key);

  if (shouldUseLiveAuth()) {
    if (!isUuid(userId)) {
      state.notice = "This account is not loaded from Supabase yet, so admin rights cannot be updated.";
      render();
      return;
    }

    const { error } = await supabase.rpc("admin_set_profile_menu_rights", {
      p_profile_id: userId,
      p_menu_keys: enabledMenuKeys
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not update admin rights.");
      render();
      return;
    }
    await loadAdminDashboard();
  } else {
    state.adminMenuRights = [
      ...state.adminMenuRights.filter((right) => normalizeAdminMenuRight(right).profileId !== userId),
      ...allActiveAdminMenuItems().map((item) => ({
        profileId: userId,
        menuKey: item.key,
        hasAccess: enabledMenuKeys.includes(item.key)
      }))
    ];
  }

  state.editingUserRightsId = null;
  state.editUserRightsForm = {};
  state.notice = "Admin rights updated.";
  render();
}

async function copySignupLink() {
  const link = signupUrl();
  try {
    await navigator.clipboard.writeText(link);
    state.notice = "Sign-up link copied.";
  } catch {
    state.notice = `Sign-up link: ${link}`;
  }
  render();
}

async function markBookingPaid(bookingId) {
  if (!isAdminSession()) {
    return;
  }

  if (shouldUseLiveAuth()) {
    if (!isUuid(bookingId)) {
      state.notice = "This reservation is not loaded from Supabase yet. Refresh admin data and try again.";
      render();
      return;
    }
    const { error } = await supabase.rpc("admin_mark_reservation_paid", {
      p_reservation_id: bookingId,
      p_paid: true
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not update paid status.");
      render();
      return;
    }
    await loadAdminDashboard();
    state.notice = "Reservation marked paid.";
    render();
    return;
  }

  const booking = state.bookings.find((candidate) => candidate.id === bookingId);
  if (booking) {
    booking.paymentStatus = "paid";
    booking.updatedDT = new Date().toISOString();
  }
  state.notice = "Reservation marked paid.";
  render();
}

async function markPaymentPaid(paymentKey) {
  if (!isAdminSession()) {
    return;
  }

  const payment = paymentDueAccounts().find((candidate) => candidate.key === paymentKey);
  if (!payment) {
    state.notice = "Payment due record not found.";
    render();
    return;
  }
  if (shouldUseLiveAuth()) {
    if (!payment.bookings.every((booking) => isUuid(booking.id))) {
      state.notice = "This payment includes reservations that are not loaded from Supabase yet. Refresh admin data and try again.";
      render();
      return;
    }
    const { data, error } = await supabase.rpc("admin_mark_payment_paid", { payload: buildPaymentPayload(payment) });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not mark the full payment paid.");
      render();
      return;
    }
    rememberPaymentRecord(normalizePaymentRecord(data ?? { ...payment, status: "paid", paidAt: new Date().toISOString() }));
    await loadAdminDashboard();
    state.notice = `${payment.name} marked paid.`;
    render();
    return;
  }

  const ids = new Set(payment.bookings.map((booking) => booking.id));
  state.bookings = state.bookings.map((booking) => ids.has(booking.id) ? {
    ...booking,
    paymentStatus: "paid",
    updatedDT: new Date().toISOString()
  } : booking);
  rememberPaymentRecord({ ...payment, status: "paid", paidAt: new Date().toISOString() });
  state.notice = `${payment.name} marked paid.`;
  render();
}

function togglePaymentPanel(paymentKey) {
  if (!paymentKey) {
    return;
  }
  const expanded = new Set(state.expandedPaymentKeys);
  if (expanded.has(paymentKey)) {
    expanded.delete(paymentKey);
  } else {
    expanded.add(paymentKey);
  }
  state.expandedPaymentKeys = [...expanded];
  render();
}

function isPaymentPanelOpen(paymentKey) {
  return state.expandedPaymentKeys.includes(paymentKey);
}

function togglePastPaymentPanel(paymentKey) {
  if (!paymentKey) {
    return;
  }
  const expanded = new Set(state.expandedPastPaymentKeys);
  if (expanded.has(paymentKey)) {
    expanded.delete(paymentKey);
  } else {
    expanded.add(paymentKey);
  }
  state.expandedPastPaymentKeys = [...expanded];
  render();
}

function isPastPaymentPanelOpen(paymentKey) {
  return state.expandedPastPaymentKeys.includes(paymentKey);
}

async function createInvoiceForPayment(paymentKey) {
  if (!isAdminSession()) {
    return;
  }

  const payment = paymentDueAccounts().find((candidate) => candidate.key === paymentKey);
  if (!payment) {
    state.notice = "Payment due record not found.";
    render();
    return;
  }

  const invoice = buildInvoice(payment);
  const existingInvoice = invoiceForPayment(payment);
  if (existingInvoice) {
    state.notice = `Invoice ${existingInvoice.invoiceNumber} already exists for this payment.`;
    state.adminTab = "invoices";
    render();
    return;
  }
  if (shouldUseLiveAuth()) {
    if (!payment.bookings.every((booking) => isUuid(booking.id))) {
      state.notice = "This payment includes reservations that are not loaded from Supabase yet. Refresh admin data and try again.";
      render();
      return;
    }
    const { data, error } = await supabase.rpc("admin_create_invoice", { payload: invoice });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not create invoice.");
      render();
      return;
    }
    state.invoices = (data?.invoices ?? state.invoices).map(normalizeInvoice);
    state.payments = (data?.payments ?? state.payments).map(normalizePaymentRecord);
    state.notice = `Invoice ${data?.invoice?.invoiceNumber ?? invoice.invoiceNumber} created.`;
    state.adminTab = "invoices";
    await loadAdminDashboard();
    render();
    return;
  }

  state.invoices = [invoice, ...state.invoices];
  rememberPaymentRecord({ ...payment, status: "invoiced", invoiceId: invoice.id });
  state.notice = `Invoice ${invoice.invoiceNumber} created.`;
  state.adminTab = "invoices";
  render();
}

async function generateAllInvoices() {
  if (!isAdminSession()) {
    return;
  }

  const payments = paymentDueAccounts().filter((payment) => !invoiceForPayment(payment));
  if (!payments.length) {
    state.notice = "No uninvoiced payment due records found.";
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    let createdCount = 0;
    for (const payment of payments) {
      if (!payment.bookings.every((booking) => isUuid(booking.id))) {
        continue;
      }
      const { error } = await supabase.rpc("admin_create_invoice", { payload: buildInvoice(payment) });
      if (error) {
        state.notice = readableSupabaseError(error, `Created ${createdCount} invoice${createdCount === 1 ? "" : "s"} before stopping.`);
        render();
        return;
      }
      createdCount += 1;
    }
    await loadAdminDashboard();
    state.adminTab = "invoices";
    state.notice = `${createdCount} invoice${createdCount === 1 ? "" : "s"} created.`;
    render();
    return;
  }

  const newInvoices = [];
  for (const payment of payments) {
    const invoice = buildInvoice(payment);
    newInvoices.push(invoice);
    state.invoices = [invoice, ...state.invoices];
    rememberPaymentRecord({ ...payment, status: "invoiced", invoiceId: invoice.id });
  }
  state.adminTab = "invoices";
  state.notice = `${newInvoices.length} invoice${newInvoices.length === 1 ? "" : "s"} created.`;
  render();
}

function buildInvoice(payment) {
  const now = new Date();
  return {
    id: `invoice-${nextInvoiceNumber()}`,
    invoiceNumber: `A2Z-${now.getFullYear()}-${String(nextInvoiceNumber()).padStart(4, "0")}`,
    paymentKey: payment.key,
    subjectId: payment.subjectId,
    subjectName: payment.name,
    subjectType: payment.subjectType,
    contactEmail: payment.contactEmail,
    billingRule: payment.billingRule,
    periodStart: payment.periodStart,
    periodEnd: payment.periodEnd,
    amount: payment.amount,
    minutes: payment.minutes,
    reservationIds: payment.bookings.map((booking) => booking.id),
    reservations: payment.bookings,
    createdAt: now.toISOString(),
    status: "created"
  };
}

function buildPaymentPayload(payment) {
  return {
    paymentKey: payment.key,
    subjectId: payment.subjectId,
    subjectName: payment.name,
    subjectType: payment.subjectType,
    contactEmail: payment.contactEmail,
    billingRule: payment.billingRule,
    periodStart: payment.periodStart,
    periodEnd: payment.periodEnd,
    amount: payment.amount,
    minutes: payment.minutes,
    reservationIds: payment.bookings.map((booking) => booking.id)
  };
}

function printInvoice(invoiceId) {
  const invoice = invoiceById(invoiceId);
  if (!invoice) {
    state.notice = "Invoice not found.";
    render();
    return;
  }

  state.notice = printHtmlDocument(invoiceHtml(invoice))
    ? `Invoice ${invoice.invoiceNumber} sent to print.`
    : "Could not prepare invoice print view.";
  render();
}

function emailInvoice(invoiceId, recipientType) {
  const invoice = invoiceById(invoiceId);
  if (!invoice) {
    state.notice = "Invoice not found.";
    render();
    return;
  }

  const recipient = recipientType === "admin" ? state.settings.adminEmail : invoice.contactEmail;
  if (!recipient) {
    state.notice = recipientType === "admin" ? "Add an admin email in Settings first." : "Add an email to the client record first.";
    render();
    return;
  }

  const tokens = invoiceTemplateTokens(invoice);
  const subject = applyTemplateTokens(state.settings.emailTemplates.invoice.subject, tokens);
  const body = `${applyTemplateTokens(state.settings.emailTemplates.invoice.body, tokens)}\n\nPrint-ready invoice:\n${plainInvoiceText(invoice)}`;
  window.location.href = `mailto:${encodeURIComponent(recipient)}?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(body)}`;
  state.notice = `Invoice email opened for ${recipient}.`;
  render();
}

function sortInvoices(sortBy) {
  if (state.invoiceFilters.sortBy === sortBy) {
    state.invoiceFilters.sortDirection = state.invoiceFilters.sortDirection === "asc" ? "desc" : "asc";
  } else {
    state.invoiceFilters.sortBy = sortBy;
    state.invoiceFilters.sortDirection = "asc";
  }
  render();
}

async function createAdminSubject() {
  const displayName = state.adminSubjectForm.displayName.trim();
  if (!displayName) {
    state.notice = "Enter a client name first.";
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    const clientTypeId = resolveClientTypeId(state.adminSubjectForm.clientTypeId);
    if (!isUuid(clientTypeId)) {
      state.notice = "Client types are not loaded from Supabase yet. Refresh admin data and try again.";
      render();
      return;
    }

    const { data, error } = await supabase.rpc("admin_create_subject", {
      payload: {
        ...state.adminSubjectForm,
        clientTypeId,
        displayName,
        shortName: state.adminSubjectForm.shortName.trim() || displayName.slice(0, 24),
        notes: state.adminSubjectForm.notes || "Admin-created client record"
      }
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not create client record.");
      render();
      return;
    }
    state.adminSubjectForm.displayName = "";
    state.adminSubjectForm.shortName = "";
    state.adminSubjectForm.contactName = "";
    state.adminSubjectForm.contactEmail = "";
    state.adminSubjectForm.contactPhone = "";
    await loadAdminDashboard();
    state.bulkForm.subjectId = data?.id ?? state.bulkForm.subjectId;
    state.bulkDeleteForm.subjectId = data?.id ?? state.bulkDeleteForm.subjectId;
    state.notice = "Client record created.";
    render();
    return;
  }

  const now = new Date().toISOString();
  state.adminSubjects.push({
    id: nextSubjectId(),
    subjectType: clientTypeById(state.adminSubjectForm.clientTypeId)?.name ?? "Club",
    clientTypeId: state.adminSubjectForm.clientTypeId,
    clientTypeName: clientTypeById(state.adminSubjectForm.clientTypeId)?.name ?? "Club",
    clientTypeHaveTeams: Boolean(clientTypeById(state.adminSubjectForm.clientTypeId)?.haveTeams),
    displayName,
    shortName: state.adminSubjectForm.shortName.trim() || displayName.slice(0, 24),
    contactName: state.adminSubjectForm.contactName.trim(),
    contactEmail: state.adminSubjectForm.contactEmail.trim(),
    contactPhone: state.adminSubjectForm.contactPhone.trim(),
    notes: state.adminSubjectForm.notes || "Admin-created client record",
    teams: [],
    deleted: false,
    createdDT: now,
    updatedDT: now
  });
  state.adminSubjectForm.displayName = "";
  state.adminSubjectForm.shortName = "";
  state.adminSubjectForm.contactName = "";
  state.adminSubjectForm.contactEmail = "";
  state.adminSubjectForm.contactPhone = "";
  state.adminSubjectForm.notes = "";
  state.notice = "Client record created.";
  render();
}

function startEditSubject(subjectId) {
  const subject = subjectById(subjectId);
  if (!subject) {
    return;
  }

  state.editingSubjectId = subject.id;
  state.editSubjectForm = {
    displayName: subject.displayName,
    shortName: clientShortName(subject),
    contactEmail: subject.contactEmail ?? "",
    contactName: subject.contactName ?? "",
    contactPhone: subject.contactPhone ?? "",
    notes: subject.notes ?? "",
    clientTypeId: subject.clientTypeId ?? clientTypeForSubject(subject)?.id ?? activeClientTypes()[0]?.id ?? ""
  };
  state.teamForm = defaultTeamForm();
  state.editingTeamId = null;
  render();
}

function cancelEditSubject() {
  state.editingSubjectId = null;
  render();
}

async function saveSubject(subjectId) {
  if (!isAdminSession()) {
    return;
  }

  const displayName = state.editSubjectForm.displayName.trim();
  if (!displayName) {
    state.notice = "Enter a name before saving.";
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_update_subject", {
      p_subject_id: subjectId,
      payload: {
        displayName,
        shortName: state.editSubjectForm.shortName.trim() || displayName.slice(0, 24),
        contactEmail: state.editSubjectForm.contactEmail.trim(),
        contactName: state.editSubjectForm.contactName.trim(),
        contactPhone: state.editSubjectForm.contactPhone.trim(),
        notes: state.editSubjectForm.notes,
        clientTypeId: state.editSubjectForm.clientTypeId
      }
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not update client record.");
      render();
      return;
    }
    state.editingSubjectId = null;
    await loadAdminDashboard();
    state.notice = "Client record updated.";
    render();
    return;
  }

  const nextType = clientTypeById(state.editSubjectForm.clientTypeId);
  state.adminSubjects = state.adminSubjects.map((subject) => subject.id === subjectId ? {
    ...subject,
    displayName,
    shortName: state.editSubjectForm.shortName.trim() || displayName.slice(0, 24),
    contactEmail: state.editSubjectForm.contactEmail.trim(),
    contactName: state.editSubjectForm.contactName.trim(),
    contactPhone: state.editSubjectForm.contactPhone.trim(),
    notes: state.editSubjectForm.notes,
    clientTypeId: nextType?.id,
    clientTypeName: nextType?.name,
    clientTypeHaveTeams: Boolean(nextType?.haveTeams),
    subjectType: nextType?.name ?? subject.subjectType,
    updatedDT: new Date().toISOString()
  } : subject);
  state.editingSubjectId = null;
  state.notice = "Client record updated.";
  render();
}

function inviteSubject(subjectId) {
  const subject = subjectById(subjectId);
  const email = subject?.contactEmail?.trim();
  if (!email) {
    state.notice = "Add an email before sending an invite.";
    render();
    return;
  }

  const subjectText = "A2Z Volleyball account invitation";
  const bodyText = `Use this link to create your A2Z account: ${signupUrl()}`;
  window.location.href = `mailto:${encodeURIComponent(email)}?subject=${encodeURIComponent(subjectText)}&body=${encodeURIComponent(bodyText)}`;
  state.notice = `Invite opened for ${email}.`;
  render();
}

async function createClientType() {
  const name = state.clientTypeForm.name.trim();
  if (!name) {
    state.notice = "Enter a client type name.";
    render();
    return;
  }
  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_create_client_type", { payload: { ...state.clientTypeForm, name } });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not create client type.");
      render();
      return;
    }
    await loadAdminDashboard();
  } else {
    state.clientTypes.push({ id: `client-type-${Date.now()}`, name, haveTeams: Boolean(state.clientTypeForm.haveTeams), deleted: false });
  }
  state.clientTypeForm = { name: "", haveTeams: false };
  state.notice = "Client type created.";
  render();
}

function startEditClientType(clientTypeId) {
  const clientType = clientTypeById(clientTypeId);
  if (!clientType) {
    return;
  }
  state.editingClientTypeId = clientType.id;
  state.editClientTypeForm = { name: clientType.name, haveTeams: Boolean(clientType.haveTeams) };
  render();
}

function cancelEditClientType() {
  state.editingClientTypeId = null;
  render();
}

async function saveClientType(clientTypeId) {
  const name = state.editClientTypeForm.name.trim();
  if (!name) {
    state.notice = "Enter a client type name.";
    render();
    return;
  }
  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_update_client_type", {
      p_client_type_id: clientTypeId,
      payload: { ...state.editClientTypeForm, name }
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not update client type.");
      render();
      return;
    }
    await loadAdminDashboard();
  } else {
    state.clientTypes = state.clientTypes.map((type) => type.id === clientTypeId ? { ...type, name, haveTeams: Boolean(state.editClientTypeForm.haveTeams) } : type);
  }
  state.editingClientTypeId = null;
  state.notice = "Client type updated.";
  render();
}

async function deleteClientType(clientTypeId) {
  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_delete_client_type", { p_client_type_id: clientTypeId });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not delete client type.");
      render();
      return;
    }
    await loadAdminDashboard();
  } else {
    if (allClients().some((client) => client.clientTypeId === clientTypeId)) {
      state.notice = "Client type is used by active clients. Move those clients before deleting it.";
      render();
      return;
    }
    state.clientTypes = state.clientTypes.map((type) => type.id === clientTypeId ? { ...type, deleted: true, Deleted: 1 } : type);
  }
  state.notice = "Client type deleted.";
  render();
}

async function disableSubject(subjectId) {
  const subject = subjectById(subjectId);
  if (!subject) {
    return;
  }
  const future = activeBookings()
    .filter((booking) => booking.subjectId === subjectId && new Date(booking.end).getTime() >= Date.now())
    .sort((left, right) => new Date(left.start) - new Date(right.start))
    .slice(0, 3);
  if (future.length) {
    state.notice = `Client has future reservations: ${future.map((booking) => `${formatShortDate(booking.start)} ${formatShortTime(booking.start)}`).join(", ")}. Cancel or delete those first.`;
    render();
    return;
  }
  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_disable_subject", { p_subject_id: subjectId, p_reason: "Disabled by admin" });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not disable client.");
      render();
      return;
    }
    await loadAdminDashboard();
  } else {
    state.adminSubjects = state.adminSubjects.map((client) => client.id === subjectId ? { ...client, disabled: true, disabledAt: new Date().toISOString(), disabledReason: "Disabled by admin" } : client);
  }
  state.notice = "Client disabled.";
  render();
}

async function enableSubject(subjectId) {
  const subject = disabledClients().find((client) => client.id === subjectId);
  if (!subject || !isAdminSession()) {
    return;
  }

  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_enable_subject", { p_subject_id: subjectId });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not enable client.");
      render();
      return;
    }
    await loadAdminDashboard();
  } else {
    state.adminSubjects = state.adminSubjects.map((client) => client.id === subjectId ? {
      ...client,
      disabled: false,
      disabledAt: null,
      disabledReason: ""
    } : client);
  }
  state.notice = "Client enabled.";
  render();
}

async function createSubjectTeam(form = null) {
  if (teamCreateInFlight) {
    return;
  }
  const subjectId = state.editingSubjectId;
  const teamForm = form ? currentTeamFormFromForm(form) : state.teamForm;
  const name = teamForm.name.trim();
  if (!subjectId || !name) {
    state.notice = "Enter a team name.";
    render();
    return;
  }
  teamCreateInFlight = true;
  const payload = buildSubjectTeamPayload(subjectId, teamForm, name);
  try {
    if (shouldUseLiveAuth()) {
      const { error } = await supabase.rpc("admin_create_subject_team", { payload });
      if (error) {
        state.notice = readableSupabaseError(error, "Could not create team.");
        render();
        return;
      }
      await loadAdminDashboard();
    } else {
      state.adminSubjects = state.adminSubjects.map((subject) => subject.id === subjectId ? {
        ...subject,
        teams: [...(subject.teams ?? []), { id: `team-${Date.now()}`, ...payload, deleted: false }]
      } : subject);
    }
    state.teamForm = defaultTeamForm();
    state.notice = "Team created.";
    render();
  } finally {
    teamCreateInFlight = false;
  }
}

function currentTeamFormFromForm(form) {
  return {
    ...state.teamForm,
    name: form.querySelector('[data-subject-team="name"]')?.value ?? state.teamForm.name,
    shortName: form.querySelector('[data-subject-team="shortName"]')?.value ?? state.teamForm.shortName
  };
}

function startEditSubjectTeam(teamId) {
  const team = subjectTeamById(teamId);
  if (!team) {
    return;
  }
  state.editingTeamId = team.id;
  state.editTeamForm = teamFormFromTeam(team);
  render();
}

function cancelEditSubjectTeam() {
  state.editingTeamId = null;
  render();
}

async function saveSubjectTeam(teamId) {
  const name = state.editTeamForm.name.trim();
  if (!name) {
    state.notice = "Enter a team name.";
    render();
    return;
  }
  const payload = buildSubjectTeamPayload(subjectTeamById(teamId)?.subjectId ?? "", state.editTeamForm, name);
  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_update_subject_team", { p_team_id: teamId, payload });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not update team.");
      render();
      return;
    }
    await loadAdminDashboard();
  } else {
    state.adminSubjects = state.adminSubjects.map((subject) => ({
      ...subject,
      teams: (subject.teams ?? []).map((team) => team.id === teamId ? { ...team, ...payload } : team)
    }));
  }
  state.editingTeamId = null;
  state.notice = "Team updated.";
  render();
}

async function createClosure() {
  if (!isAdminSession()) {
    return;
  }
  if (!state.closureForm.startDate || !state.closureForm.endDate) {
    state.notice = "Start and end dates are required for closed days.";
    render();
    return;
  }
  if (state.closureForm.endDate < state.closureForm.startDate) {
    state.notice = "Closed day end date must be on or after start date.";
    render();
    return;
  }

  const payload = { ...state.closureForm };
  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_create_closure", { payload });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not add closed day.");
      render();
      return;
    }
    await loadAdminDashboard();
  } else {
    state.settings.closures = [
      ...state.settings.closures,
      {
        id: `closure-${Date.now()}`,
        resourceType: payload.resourceType,
        courtId: payload.resourceType === "court" ? payload.courtId || null : null,
        start: toIso(payload.startDate, payload.startTime || "00:00"),
        end: toIso(payload.endDate, payload.endTime || "23:59"),
        reason: payload.reason || "Closed"
      }
    ];
  }
  state.closureForm = defaultClosureForm();
  state.notice = "Closed day added.";
  render();
}

async function deleteClosure(closureId) {
  if (!isAdminSession()) {
    return;
  }
  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_delete_closure", { p_closure_id: closureId });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not delete closed day.");
      render();
      return;
    }
    await loadAdminDashboard();
  } else {
    state.settings.closures = state.settings.closures.filter((closure) => closure.id !== closureId);
  }
  state.notice = "Closed day deleted.";
  render();
}

async function deleteSubjectTeam(teamId) {
  const activeCount = activeBookings().filter((booking) => booking.subjectTeamId === teamId).length;
  if (activeCount) {
    state.notice = `Team has ${activeCount} active reservation${activeCount === 1 ? "" : "s"}. Delete or cancel those reservations before deleting the team.`;
    render();
    return;
  }
  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_delete_subject_team", { p_team_id: teamId });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not delete team.");
      render();
      return;
    }
    await loadAdminDashboard();
  } else {
    state.adminSubjects = state.adminSubjects.map((subject) => ({
      ...subject,
      teams: (subject.teams ?? []).map((team) => team.id === teamId ? { ...team, deleted: true, Deleted: 1 } : team)
    }));
  }
  state.notice = "Team deleted.";
  render();
}

async function createSeason() {
  if (!isAdminSession()) {
    return;
  }

  const startYear = Number(state.seasonForm.startYear);
  if (!validSeasonYear(startYear)) {
    state.notice = "Season start year must be between 2020 and 2100.";
    render();
    return;
  }

  const displayName = formatSeasonYear(startYear);
  if (activeSeasons().some((season) => season.startYear === startYear)) {
    state.notice = "That season already exists.";
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_create_season", {
      payload: { startYear, displayName }
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not create season.");
      render();
      return;
    }
    await loadAdminDashboard();
    state.notice = "Season created.";
    render();
    return;
  }

  const now = new Date().toISOString();
  state.seasons.push({
    id: `season-${startYear}`,
    startYear,
    displayName,
    deleted: false,
    createdDT: now,
    updatedDT: now
  });
  state.seasonPriceForm.seasonId = latestSeason()?.id ?? "";
  state.notice = "Season created.";
  render();
}

function startEditSeason(seasonId) {
  const season = seasonById(seasonId);
  if (!season) {
    return;
  }

  state.editingSeasonId = season.id;
  state.editSeasonForm = {
    startYear: season.startYear,
    displayName: season.displayName
  };
  render();
}

function cancelEditSeason() {
  state.editingSeasonId = null;
  render();
}

async function saveSeason(seasonId) {
  if (!isAdminSession()) {
    return;
  }

  const startYear = Number(state.editSeasonForm.startYear);
  const displayName = String(state.editSeasonForm.displayName ?? "").trim() || formatSeasonYear(startYear);
  if (!validSeasonYear(startYear)) {
    state.notice = "Season start year must be between 2020 and 2100.";
    render();
    return;
  }
  if (activeSeasons().some((season) => season.id !== seasonId && season.startYear === startYear)) {
    state.notice = "That season already exists.";
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_update_season", {
      p_season_id: seasonId,
      payload: { startYear, displayName }
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not update season.");
      render();
      return;
    }
    state.editingSeasonId = null;
    await loadAdminDashboard();
    state.notice = "Season updated.";
    render();
    return;
  }

  state.seasons = state.seasons.map((season) => season.id === seasonId ? {
    ...season,
    startYear,
    displayName,
    updatedDT: new Date().toISOString()
  } : season);
  state.teamSeasonPrices = state.teamSeasonPrices.map((price) => price.seasonId === seasonId ? {
    ...price,
    season: displayName,
    seasonYear: startYear,
    seasonDisplayName: displayName
  } : price);
  state.editingSeasonId = null;
  state.notice = "Season updated.";
  render();
}

async function deleteSeason(seasonId) {
  if (!isAdminSession()) {
    return;
  }

  if (activeSeasonPrices().some((price) => price.seasonId === seasonId)) {
    state.notice = "This season is used by club pricing. Delete or edit those club seasons first.";
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_delete_season", { p_season_id: seasonId });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not delete season.");
      render();
      return;
    }
    state.editingSeasonId = null;
    await loadAdminDashboard();
    state.notice = "Season deleted.";
    render();
    return;
  }

  state.seasons = state.seasons.map((season) => season.id === seasonId ? {
    ...season,
    deleted: true,
    Deleted: 1,
    updatedDT: new Date().toISOString()
  } : season);
  state.editingSeasonId = null;
  state.seasonPriceForm.seasonId = latestSeason()?.id ?? "";
  state.notice = "Season deleted.";
  render();
}

async function createSeasonPrice() {
  if (!isAdminSession()) {
    return;
  }

  const subject = subjectById(state.seasonPriceForm.subjectId);
  const selectedSeason = seasonById(state.seasonPriceForm.seasonId);
  const hourlyRate = Number(state.seasonPriceForm.hourlyRate);

  if (!subject || !clientTypeHasTeams(subject)) {
    state.notice = "Select a client with teams before creating a club season.";
    render();
    return;
  }
  if (!selectedSeason || hourlyRate < 0) {
    state.notice = "Season and hourly price are required.";
    render();
    return;
  }
  if (activeSeasonPrices().some((price) => price.subjectId === subject.id && price.seasonId === selectedSeason.id)) {
    state.notice = "A season price already exists for this client and season. Edit the existing price instead of creating a duplicate.";
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_create_team_season_price", {
      payload: {
        subjectId: subject.id,
        seasonId: selectedSeason.id,
        hourlyRate,
        documentsReceived: Boolean(state.seasonPriceForm.documentsReceived),
        deposit: Number(state.seasonPriceForm.deposit ?? 0)
      }
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not create season price.");
      render();
      return;
    }
    await loadAdminDashboard();
    state.bulkForm.seasonPriceId = latestSeasonPriceForSubject(state.bulkForm.subjectId)?.id ?? "";
    state.bookingSeasonPriceId = latestSeasonPriceForSubject(state.bookingSubjectId)?.id ?? "";
    state.notice = "Season price created.";
    render();
    return;
  }

  const now = new Date().toISOString();
  const price = {
    id: `price-${subject.id}-${selectedSeason.startYear}-${state.teamSeasonPrices.length + 1}`,
    subjectId: subject.id,
    teamName: subject.displayName,
    seasonId: selectedSeason.id,
    season: selectedSeason.displayName,
    seasonYear: selectedSeason.startYear,
    seasonDisplayName: selectedSeason.displayName,
    hourlyRate,
    documentsReceived: Boolean(state.seasonPriceForm.documentsReceived),
    deposit: Number(state.seasonPriceForm.deposit ?? 0),
    deleted: false,
    createdDT: now,
    updatedDT: now
  };
  state.teamSeasonPrices.push(price);
  state.bulkForm.seasonPriceId = latestSeasonPriceForSubject(state.bulkForm.subjectId)?.id ?? "";
  state.bookingSeasonPriceId = latestSeasonPriceForSubject(state.bookingSubjectId)?.id ?? "";
  state.notice = "Season price created.";
  render();
}

function seasonPriceById(priceId) {
  return state.teamSeasonPrices.find((price) => price.id === priceId && !price.deleted && price.Deleted !== 1);
}

function startEditSeasonPrice(priceId) {
  const price = seasonPriceById(priceId);
  if (!price) {
    return;
  }

  state.editingSeasonPriceId = price.id;
  state.editSeasonPriceForm = {
    subjectId: price.subjectId,
    seasonId: price.seasonId ?? seasonByYear(price.seasonYear)?.id ?? "",
    hourlyRate: price.hourlyRate,
    documentsReceived: Boolean(price.documentsReceived),
    deposit: Number(price.deposit ?? 0)
  };
  render();
}

function cancelEditSeasonPrice() {
  state.editingSeasonPriceId = null;
  render();
}

async function saveSeasonPrice(priceId) {
  if (!isAdminSession()) {
    return;
  }

  const subject = subjectById(state.editSeasonPriceForm.subjectId);
  const selectedSeason = seasonById(state.editSeasonPriceForm.seasonId);
  const hourlyRate = Number(state.editSeasonPriceForm.hourlyRate);

  if (!subject || !clientTypeHasTeams(subject)) {
    state.notice = "Select a client with teams before saving the club season.";
    render();
    return;
  }
  if (!selectedSeason || hourlyRate < 0) {
    state.notice = "Season and hourly price are required.";
    render();
    return;
  }
  if (activeSeasonPrices().some((price) => price.id !== priceId && price.subjectId === subject.id && price.seasonId === selectedSeason.id)) {
    state.notice = "A season price already exists for this client and season. Edit the existing price instead of creating a duplicate.";
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_update_team_season_price", {
      p_price_id: priceId,
      payload: {
        subjectId: subject.id,
        seasonId: selectedSeason.id,
        hourlyRate,
        documentsReceived: Boolean(state.editSeasonPriceForm.documentsReceived),
        deposit: Number(state.editSeasonPriceForm.deposit ?? 0)
      }
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not update season price.");
      render();
      return;
    }
    state.editingSeasonPriceId = null;
    await loadAdminDashboard();
    state.notice = "Season price updated.";
    render();
    return;
  }

  state.teamSeasonPrices = state.teamSeasonPrices.map((price) => price.id === priceId ? {
    ...price,
    subjectId: subject.id,
    teamName: subject.displayName,
    seasonId: selectedSeason.id,
    season: selectedSeason.displayName,
    seasonYear: selectedSeason.startYear,
    seasonDisplayName: selectedSeason.displayName,
    hourlyRate,
    documentsReceived: Boolean(state.editSeasonPriceForm.documentsReceived),
    deposit: Number(state.editSeasonPriceForm.deposit ?? 0),
    updatedDT: new Date().toISOString()
  } : price);
  state.editingSeasonPriceId = null;
  state.notice = "Season price updated.";
  render();
}

async function deleteSeasonPrice(priceId) {
  if (!isAdminSession()) {
    return;
  }

  if (shouldUseLiveAuth()) {
    const { error } = await supabase.rpc("admin_delete_team_season_price", { p_price_id: priceId });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not delete season price.");
      render();
      return;
    }
    state.editingSeasonPriceId = null;
    await loadAdminDashboard();
    state.notice = "Season price deleted.";
    render();
    return;
  }

  state.teamSeasonPrices = state.teamSeasonPrices.map((price) => price.id === priceId ? {
    ...price,
    deleted: true,
    Deleted: 1,
    updatedDT: new Date().toISOString()
  } : price);
  state.editingSeasonPriceId = null;
  state.bulkForm.seasonPriceId = latestSeasonPriceForSubject(state.bulkForm.subjectId)?.id ?? "";
  state.bookingSeasonPriceId = latestSeasonPriceForSubject(state.bookingSubjectId)?.id ?? "";
  state.notice = "Season price deleted.";
  render();
}

async function previewBulkReservation() {
  let payload;
  try {
    payload = buildBulkRequest();
  } catch (error) {
    state.notice = error.message;
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    const { data, error } = await supabase.rpc("admin_preview_bulk_reservations", { payload });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not preview bulk reservations.");
      render();
      return;
    }
    state.bulkPreview = data;
    state.notice = "Bulk reservation preview is ready.";
    render();
    return;
  }

  try {
    const scheduler = buildScheduler();
    state.bulkPreview = scheduler.previewBulkReservationOperation(payload, state.user);
    state.notice = "Bulk reservation preview is ready.";
  } catch (error) {
    state.notice = error.message;
  }
  render();
}

async function applyBulkReservation() {
  let payload;
  try {
    payload = buildBulkRequest();
  } catch (error) {
    state.notice = error.message;
    render();
    return;
  }

  if (bulkPreviewHasOutsideHours(state.bulkPreview) && !window.confirm("Some of the reservations are out of business hours. Are you sure?")) {
    state.notice = "Bulk reservation create cancelled.";
    render();
    return;
  }

  if (shouldUseLiveAuth()) {
    const { data, error } = await supabase.rpc("admin_apply_bulk_reservations", { payload });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not apply bulk reservations.");
      render();
      return;
    }
    state.bulkPreview = data?.operation ? { ...data.operation, items: data.items ?? [] } : null;
    await loadAdminDashboard();
    resetBulkForm({ preserveDatesAndClient: true });
    state.notice = `${data?.created?.length ?? 0} reservation${data?.created?.length === 1 ? "" : "s"} created.`;
    render();
    return;
  }

  try {
    const scheduler = buildScheduler();
    const result = scheduler.applyBulkReservationOperation(payload, state.user);
    state.bookings = scheduler.bookings.map(storeBooking);
    state.bulkOperations = scheduler.bulkOperations;
    state.bulkPreview = result.operation;
    resetBulkForm({ preserveDatesAndClient: true });
    state.notice = `${result.created.length} reservation${result.created.length === 1 ? "" : "s"} created.`;
  } catch (error) {
    state.notice = error.message;
  }
  render();
}

async function previewBulkDelete() {
  if (shouldUseLiveAuth()) {
    const { data, error } = await supabase.rpc("admin_preview_delete_reservations", {
      p_subject_id: state.bulkDeleteForm.subjectId,
      p_start_date: state.bulkDeleteForm.startDate,
      p_end_date: state.bulkDeleteForm.endDate
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not preview bulk delete.");
      render();
      return;
    }
    applyBulkDeletePreviewResult(data);
    state.notice = bulkDeleteNotice("Bulk delete preview is ready.", state.bulkDeletePreview.length, state.bulkDeleteSkippedPaid.length);
    render();
    return;
  }

  try {
    const scheduler = buildScheduler();
    const request = buildBulkDeleteRequest();
    state.bulkDeletePreview = scheduler.previewDeleteBookingsForSubject(request, state.user);
    state.bulkDeleteSkippedPaid = scheduler.previewPaidDeleteBookingsForSubject(request, state.user);
    state.notice = bulkDeleteNotice("Bulk delete preview is ready.", state.bulkDeletePreview.length, state.bulkDeleteSkippedPaid.length);
  } catch (error) {
    state.notice = error.message;
  }
  render();
}

async function applyBulkDelete() {
  if (shouldUseLiveAuth()) {
    const { data, error } = await supabase.rpc("admin_apply_delete_reservations", {
      p_subject_id: state.bulkDeleteForm.subjectId,
      p_start_date: state.bulkDeleteForm.startDate,
      p_end_date: state.bulkDeleteForm.endDate
    });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not apply bulk delete.");
      render();
      return;
    }
    const deletedCount = data?.deleted?.length ?? 0;
    const skippedPaidCount = data?.skippedPaid?.length ?? 0;
    state.bulkDeletePreview = [];
    state.bulkDeleteSkippedPaid = data?.skippedPaid ?? [];
    await loadAdminDashboard();
    state.notice = bulkDeleteNotice(`${deletedCount} reservation${deletedCount === 1 ? "" : "s"} soft deleted with the Deleted flag.`, deletedCount, skippedPaidCount);
    render();
    return;
  }

  try {
    const scheduler = buildScheduler();
    const result = scheduler.deleteBookingsForSubject(buildBulkDeleteRequest(), state.user);
    state.bookings = scheduler.bookings.map(storeBooking);
    state.bulkOperations = scheduler.bulkOperations;
    state.bulkDeletePreview = [];
    state.bulkDeleteSkippedPaid = result.skippedPaid ?? [];
    state.notice = bulkDeleteNotice(`${result.deleted.length} reservation${result.deleted.length === 1 ? "" : "s"} soft deleted with the Deleted flag.`, result.deleted.length, state.bulkDeleteSkippedPaid.length);
  } catch (error) {
    state.notice = error.message;
  }
  render();
}

async function deleteBulkOperation(operationId) {
  if (shouldUseLiveAuth()) {
    const { data, error } = await supabase.rpc("admin_undo_bulk_operation", { p_operation_id: operationId });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not delete bulk reservation batch.");
      render();
      return;
    }
    const deletedCount = data?.deleted?.length ?? 0;
    const skippedPaidCount = data?.skippedPaid?.length ?? 0;
    state.bulkDeletePreview = [];
    state.bulkDeleteSkippedPaid = data?.skippedPaid ?? [];
    state.bulkPreview = null;
    await loadAdminDashboard();
    state.notice = bulkOperationDeleteNotice(deletedCount, skippedPaidCount);
    render();
    return;
  }

  try {
    const scheduler = buildScheduler();
    const result = scheduler.undoBulkOperation(operationId, state.user);
    state.bookings = scheduler.bookings.map(storeBooking);
    state.bulkOperations = scheduler.bulkOperations;
    state.bulkDeletePreview = [];
    state.bulkDeleteSkippedPaid = result.skippedPaid ?? [];
    state.bulkPreview = null;
    state.notice = bulkOperationDeleteNotice(result.deleted?.length ?? 0, state.bulkDeleteSkippedPaid.length);
  } catch (error) {
    state.notice = error.message;
  }
  render();
}

function viewBulkOperationCalendar(operationId) {
  const operation = activeBulkOperations().find((candidate) => candidate.id === operationId);
  const items = activeBulkOperationBookings(operation).map(bulkCalendarItemFromBooking);
  if (!items.length) {
    state.notice = "No active reservations are available for this bulk reservation.";
    render();
    return;
  }

  state.bulkPreview = {
    ...operation,
    items
  };
  state.bulkCalendarOpen = true;
  state.adminTab = "bulk-reservations";
  const payload = operation.requestedPayload ?? {};
  state.bulkForm = {
    ...state.bulkForm,
    subjectId: payload.subjectId ?? state.bulkForm.subjectId,
    subjectTeamId: payload.subjectTeamId ?? state.bulkForm.subjectTeamId,
    resourceType: payload.resourceType ?? state.bulkForm.resourceType,
    courtId: payload.courtId ?? "",
    courtCountNeeded: Number(payload.courtCountNeeded ?? state.bulkForm.courtCountNeeded),
    startDate: payload.startDate ?? state.bulkForm.startDate,
    endDate: payload.endDate ?? state.bulkForm.endDate,
    startTime: payload.startTime ?? state.bulkForm.startTime,
    durationMinutes: Number(payload.durationMinutes ?? state.bulkForm.durationMinutes),
    daysOfWeek: payload.daysOfWeek ?? state.bulkForm.daysOfWeek,
    seasonPriceId: payload.seasonPriceId ?? state.bulkForm.seasonPriceId,
    useSeasonPrice: Boolean(payload.seasonPriceId),
    hourlyRate: Number(payload.hourlyRate ?? state.bulkForm.hourlyRate ?? state.settings.pricing.courtHourlyRate)
  };
  render();
}

function setAdminCalendarMode(mode) {
  if (!["month", "day"].includes(mode)) {
    return;
  }
  state.adminCalendar.mode = mode;
  render();
}

function moveAdminCalendar(direction) {
  if (state.adminCalendar.mode === "day") {
    selectAdminCalendarDay(addDateDays(state.adminCalendar.date, direction));
    return;
  }
  state.adminCalendar.month = addMonths(state.adminCalendar.month, direction);
  state.adminCalendar.date = `${state.adminCalendar.month}-01`;
  state.adminCalendar.selectedBookingId = null;
  state.adminCalendar.selectedSlot = null;
  render();
}

function selectAdminCalendarDay(dateKey) {
  state.adminCalendar.date = dateKey;
  state.adminCalendar.month = dateKey.slice(0, 7);
  state.adminCalendar.mode = "day";
  state.adminCalendar.selectedBookingId = null;
  state.adminCalendar.selectedSlot = null;
  render();
}

function selectAdminCalendarSlot(dateKey, time, courtId) {
  if (!isFutureSlot(dateKey, time)) {
    state.notice = "Past calendar slots cannot be changed.";
    render();
    return;
  }
  state.adminCalendar.date = dateKey;
  state.adminCalendar.month = dateKey.slice(0, 7);
  state.adminCalendar.mode = "day";
  state.adminCalendar.selectedBookingId = null;
  state.adminCalendar.editingBookingId = null;
  state.adminCalendar.selectedSlot = { date: dateKey, time, courtId };
  state.date = dateKey;
  state.time = time;
  state.resourceType = "court";
  state.selectedCourt = courtId;
  state.durationMinutes = Math.max(state.settings.minBookingMinutes, state.settings.slotIntervalMinutes);
  ensureSelectedSubject();
  render();
}

function selectAdminCalendarReservation(bookingId) {
  const booking = bookingById(bookingId);
  if (!booking) {
    state.notice = "Reservation not found.";
    render();
    return;
  }
  state.adminCalendar.date = isoDateKey(booking.start);
  state.adminCalendar.month = state.adminCalendar.date.slice(0, 7);
  state.adminCalendar.mode = "day";
  state.adminCalendar.selectedBookingId = booking.id;
  state.adminCalendar.selectedSlot = null;
  render();
}

async function addCalendarReservation(options = {}) {
  if (!state.bookingSubjectId) {
    state.notice = "Select a client before adding a reservation.";
    render();
    return;
  }
  const closure = closureForReservationForm();
  const allowClosedDay = Boolean(options.allowClosedDay || closure);
  if (closure && !options.allowClosedDay && !window.confirm(`This reservation is on a closed day (${closure.reason ?? "Closed"}). Create it anyway?`)) {
    state.notice = "Reservation create cancelled.";
    render();
    return;
  }
  const conflictMessage = singleReservationConflictMessage();
  if (conflictMessage) {
    state.notice = conflictMessage;
    render();
    return;
  }
  await bookSelectedSlot({ allowClosedDay });
  state.adminTab = "calendar";
  state.adminCalendar.selectedSlot = null;
}

function editCalendarReservation(bookingId) {
  const booking = bookingById(bookingId);
  if (!booking || !isBookingEditable(booking)) {
    state.notice = "Only future reservations can be edited.";
    render();
    return;
  }
  state.adminCalendar.editingBookingId = booking.id;
  state.date = isoDateKey(booking.start);
  state.time = easternTimeKey(booking.start);
  state.durationMinutes = reservationMinutes(booking);
  state.resourceType = booking.resourceType;
  state.selectedCourt = booking.courtId ?? "court-1";
  state.bookingSubjectId = booking.subjectId ?? "";
  state.bookingSeasonPriceId = booking.seasonPriceId ?? latestSeasonPriceForSubject(state.bookingSubjectId)?.id ?? "";
  render();
}

async function saveCalendarReservationEdit(bookingId) {
  const booking = bookingById(bookingId);
  if (!booking || !isBookingEditable(booking)) {
    state.notice = "Only future reservations can be edited.";
    render();
    return;
  }
  const closure = closureForReservationForm();
  const allowClosedDay = Boolean(closure);
  if (closure && !window.confirm(`This reservation is on a closed day (${closure.reason ?? "Closed"}). Save it anyway?`)) {
    state.notice = "Reservation update cancelled.";
    render();
    return;
  }
  const conflictMessage = singleReservationConflictMessage(bookingId);
  if (conflictMessage) {
    state.notice = conflictMessage;
    render();
    return;
  }
  const deleted = await deleteCalendarReservation(bookingId, { silent: true });
  if (!deleted) {
    return;
  }
  await addCalendarReservation({ allowClosedDay });
  state.adminCalendar.editingBookingId = null;
  state.adminCalendar.selectedBookingId = null;
  state.notice = "Reservation updated.";
  render();
}

async function deleteCalendarReservation(bookingId, options = {}) {
  const booking = bookingById(bookingId);
  if (!booking || !isBookingEditable(booking)) {
    state.notice = "Only future reservations can be deleted.";
    render();
    return false;
  }
  if (isBookingPaid(booking)) {
    state.notice = "Paid reservations cannot be deleted from the calendar.";
    render();
    return false;
  }

  if (shouldUseLiveAuth()) {
    if (!isUuid(bookingId)) {
      state.notice = "This reservation is not loaded from Supabase yet. Refresh admin data and try again.";
      render();
      return false;
    }
    const { error } = await supabase.rpc("admin_delete_reservation", { p_reservation_id: bookingId });
    if (error) {
      state.notice = readableSupabaseError(error, "Could not delete reservation.");
      render();
      return false;
    }
    await loadAdminDashboard();
  } else {
    state.bookings = state.bookings.map((candidate) => candidate.id === bookingId ? {
      ...candidate,
      deleted: true,
      Deleted: 1,
      updatedDT: new Date().toISOString()
    } : candidate);
  }

  state.adminCalendar.selectedBookingId = null;
  state.adminCalendar.selectedSlot = null;
  if (!options.silent) {
    state.notice = "Reservation deleted.";
    render();
  }
  return true;
}

async function saveAdminSettings() {
  if (!isAdminSession()) {
    return;
  }

  if (!shouldUseLiveAuth()) {
    state.notice = "Settings saved for this local preview.";
    render();
    return;
  }

  const configPayload = {
    courtCount: state.settings.courtCount,
    trainerCapacity: state.settings.trainerCapacity,
    courtHourlyRate: state.settings.pricing.courtHourlyRate,
    gymHourlyRate: state.settings.pricing.gymHourlyRate,
    minBookingMinutes: state.settings.minBookingMinutes,
    slotIntervalMinutes: state.settings.slotIntervalMinutes,
    messageDisplaySeconds: state.settings.messageDisplaySeconds,
    adminEmail: state.settings.adminEmail,
    emailTemplates: state.settings.emailTemplates
  };
  const { error: configError } = await supabase.rpc("admin_update_facility_config", { payload: configPayload });
  if (configError) {
    state.notice = readableSupabaseError(configError, "Could not save facility settings.");
    render();
    return;
  }

  for (const [dayIndex, hours] of Object.entries(state.settings.operatingHours)) {
    const { error } = await supabase.rpc("admin_update_operating_hours", {
      p_day_of_week: Number(dayIndex),
      p_open_time: hours.open,
      p_close_time: hours.close,
      p_is_closed: Boolean(hours.closed)
    });
    if (error) {
      state.notice = readableSupabaseError(error, `Could not save ${dayName(Number(dayIndex))} hours.`);
      render();
      return;
    }
  }

  await loadAdminDashboard();
  state.notice = "Facility settings saved.";
  render();
}

function updateBookingControl(control) {
  const key = control.dataset.control;
  if (key === "durationMinutes") {
    state.durationMinutes = Number(control.value);
    return;
  }
  state[key] = control.value;
  if (key === "bookingSubjectId") {
    state.bookingSeasonPriceId = latestSeasonPriceForSubject(state.bookingSubjectId)?.id ?? "";
    state.bookingSubjectTeamId = subjectTeamsForSubject(state.bookingSubjectId)[0]?.id ?? "";
  }
  if (key === "resourceType" && state.resourceType === "trainer") {
    state.selectedCourt = "";
  }
  if (key === "resourceType" && state.resourceType === "court" && !state.selectedCourt) {
    state.selectedCourt = "court-1";
  }
}

function updateConfigControl(control) {
  const value = control.type === "number" ? Number(control.value) : control.value;
  if (control.dataset.config === "courtHourlyRate") {
    state.settings.pricing.courtHourlyRate = value;
  }
  if (control.dataset.config === "gymHourlyRate") {
    state.settings.pricing.gymHourlyRate = value;
  }
  if (control.dataset.config === "courtCount") {
    state.settings.courtCount = value;
  }
  if (control.dataset.config === "trainerCapacity") {
    state.settings.trainerCapacity = value;
  }
  if (control.dataset.config === "messageDisplaySeconds") {
    state.settings.messageDisplaySeconds = Math.max(1, Math.min(60, Number(value) || DEFAULT_MESSAGE_DISPLAY_SECONDS));
  }
  if (control.dataset.config === "adminEmail") {
    state.settings.adminEmail = value;
  }
  if (control.dataset.config === "hours-open") {
    state.settings.operatingHours[control.dataset.day].open = value;
  }
  if (control.dataset.config === "hours-close") {
    state.settings.operatingHours[control.dataset.day].close = value;
  }
}

function updateAdminSubjectControl(control) {
  state.adminSubjectForm[control.dataset.adminSubject] = control.value;
}

function updateSignupControl(control) {
  state.signupForm[control.dataset.signup] = control.value;
}

function updateEditUserControl(control) {
  state.editUserForm[control.dataset.editUser] = control.value;
}

function updateAdminRightControl(control) {
  state.editUserRightsForm[control.dataset.adminRight] = control.checked;
}

function updateAdminRightsAllControl(control) {
  allActiveAdminMenuItems().forEach((item) => {
    state.editUserRightsForm[item.key] = control.checked;
  });
}

function updateEditSubjectControl(control) {
  state.editSubjectForm[control.dataset.editSubject] = control.value;
}

function updateClientTypeControl(control) {
  state.clientTypeForm[control.dataset.clientType] = control.type === "checkbox" ? control.checked : control.value;
}

function updateEditClientTypeControl(control) {
  state.editClientTypeForm[control.dataset.editClientType] = control.type === "checkbox" ? control.checked : control.value;
}

function updateSubjectTeamControl(control) {
  state.teamForm[control.dataset.subjectTeam] = control.type === "checkbox" ? control.checked : control.value;
}

function updateEditSubjectTeamControl(control) {
  state.editTeamForm[control.dataset.editSubjectTeam] = control.type === "checkbox" ? control.checked : control.value;
}

function updateClosureControl(control) {
  state.closureForm[control.dataset.closure] = control.value;
  if (control.dataset.closure === "resourceType" && control.value !== "court") {
    state.closureForm.courtId = "";
  }
  if (control.dataset.closure === "startDate" && state.closureForm.endDate < state.closureForm.startDate) {
    state.closureForm.endDate = state.closureForm.startDate;
  }
}

function updateSeasonControl(control) {
  state.seasonForm[control.dataset.seasonRecord] = control.type === "number" ? Number(control.value) : control.value;
}

function updateEditSeasonControl(control) {
  state.editSeasonForm[control.dataset.editSeasonRecord] = control.type === "number" ? Number(control.value) : control.value;
  if (control.dataset.editSeasonRecord === "startYear") {
    state.editSeasonForm.displayName = formatSeasonYear(control.value);
  }
}

function updateSeasonPriceControl(control) {
  state.seasonPriceForm[control.dataset.seasonPrice] = control.type === "checkbox" ? control.checked : control.type === "number" ? Number(control.value) : control.value;
}

function updateEditSeasonPriceControl(control) {
  state.editSeasonPriceForm[control.dataset.editSeasonPrice] = control.type === "checkbox" ? control.checked : control.type === "number" ? Number(control.value) : control.value;
}

function updateSeasonPriceFilter(control) {
  if (control.dataset.seasonPriceFilter === "year") {
    state.seasonPriceYearFilter = control.value;
  }
}

function updateEmailTemplateControl(control) {
  const templateKey = control.dataset.emailTemplate;
  const field = control.dataset.templateField;
  state.settings.emailTemplates[templateKey] = {
    ...(state.settings.emailTemplates[templateKey] ?? { subject: "", body: "" }),
    [field]: control.value
  };
}

function updateInvoiceFilter(control) {
  state.invoiceFilters[control.dataset.invoiceFilter] = control.value;
}

function updateReportFilter(control) {
  state.reportFilters[control.dataset.reportFilter] = control.value;
  state.report = null;
}

function updateAdminCalendarControl(control) {
  const key = control.dataset.calendar;
  if (key === "month") {
    state.adminCalendar.month = control.value || todayDateKey().slice(0, 7);
    if (!state.adminCalendar.date.startsWith(state.adminCalendar.month)) {
      state.adminCalendar.date = `${state.adminCalendar.month}-01`;
    }
    state.adminCalendar.mode = "month";
    state.adminCalendar.selectedBookingId = null;
    state.adminCalendar.selectedSlot = null;
    return;
  }
  if (key === "date") {
    state.adminCalendar.date = control.value || todayDateKey();
    state.adminCalendar.month = state.adminCalendar.date.slice(0, 7);
    state.adminCalendar.selectedBookingId = null;
    state.adminCalendar.selectedSlot = null;
  }
}

function updateBulkControl(control) {
  const key = control.dataset.bulk;
  if (key === "useSeasonPrice") {
    state.bulkForm.useSeasonPrice = control.checked;
    state.bulkForm.seasonPriceId = state.bulkForm.useSeasonPrice ? latestSeasonPriceForSelectedBulkSubject()?.id ?? "" : "";
    return;
  }
  if (key === "durationMinutes") {
    state.bulkForm.durationMinutes = Number(control.value);
    return;
  }
  if (key === "courtCountNeeded") {
    state.bulkForm.courtCountNeeded = Math.max(1, Math.min(Number(state.settings.courtCount), Number(control.value) || 1));
    return;
  }
  if (key === "hourlyRate") {
    state.bulkForm.hourlyRate = Math.max(0, Number(control.value) || 0);
    return;
  }
  state.bulkForm[key] = control.value;
  if (key === "subjectId") {
    state.bulkForm.seasonPriceId = latestSeasonPriceForSelectedBulkSubject()?.id ?? "";
    state.bulkForm.hourlyRate = Number(state.settings.pricing.courtHourlyRate ?? state.bulkForm.hourlyRate ?? 75);
    state.bulkForm.subjectTeamId = subjectTeamsForSubject(state.bulkForm.subjectId)[0]?.id ?? "";
  }
  if (key === "resourceType" && control.value === "trainer") {
    state.bulkForm.courtId = "";
  }
  if (key === "startDate" && state.bulkForm.endDate < state.bulkForm.startDate) {
    state.bulkForm.endDate = state.bulkForm.startDate;
  }
}

function updateBulkDayControl(control) {
  const day = Number(control.dataset.bulkDay);
  const selected = new Set(state.bulkForm.daysOfWeek);
  if (control.checked) {
    selected.add(day);
  } else {
    selected.delete(day);
  }
  state.bulkForm.daysOfWeek = [...selected].sort((left, right) => left - right);
}

function updateBulkDeleteControl(control) {
  state.bulkDeleteForm[control.dataset.bulkDelete] = control.value;
  state.bulkDeletePreview = [];
  state.bulkDeleteSkippedPaid = [];
}

function buildScheduler() {
  const courtCount = Math.max(1, Number(state.settings.courtCount));
  return new SchedulingService({
    nextId: nextBookingId(),
    courts: Array.from({ length: courtCount }, (_, index) => `court-${index + 1}`),
    trainerCapacity: Number(state.settings.trainerCapacity),
    slotIntervalMinutes: Number(state.settings.slotIntervalMinutes),
    minBookingMinutes: Number(state.settings.minBookingMinutes),
    operatingHours: state.settings.operatingHours,
    closures: state.settings.closures,
    fixedReservations: state.settings.fixedReservations,
    bookings: state.bookings,
    bulkOperations: state.bulkOperations,
    nextBulkOperationId: nextBulkOperationId()
  });
}

function buildBulkRequest() {
  const subject = subjectById(state.bulkForm.subjectId);
  const seasonPrice = selectedBulkSeasonPrice();
  const manualHourlyRate = Number(state.bulkForm.hourlyRate);
  const hourlyRate = seasonPrice?.hourlyRate ?? (Number.isFinite(manualHourlyRate) && manualHourlyRate >= 0 ? manualHourlyRate : null);
  assertBulkDatesAllowed();
  if (!state.bulkForm.subjectId || !subject) {
    throw new Error("Select a client before previewing bulk reservations.");
  }
  if (clientTypeHasTeams(subject) && !state.bulkForm.subjectTeamId) {
    throw new Error("Select a team for this client before previewing bulk reservations.");
  }
  if (shouldUseLiveAuth() && !isUuid(state.bulkForm.subjectId)) {
    throw new Error("This client is not loaded from Supabase yet. Refresh admin data and try again.");
  }
  return {
    label: `${subject?.displayName ?? "Temporary subject"} ${state.bulkForm.startDate}-${state.bulkForm.endDate}`,
    subjectId: state.bulkForm.subjectId,
    subjectTeamId: clientTypeHasTeams(subject) ? state.bulkForm.subjectTeamId : null,
    subjectName: subject?.displayName ?? state.bulkForm.subjectId,
    userId: state.bulkForm.subjectId,
    resourceType: state.bulkForm.resourceType,
    courtId: state.bulkForm.resourceType === "court" ? state.bulkForm.courtId : null,
    courtCountNeeded: state.bulkForm.resourceType === "court" ? Number(state.bulkForm.courtCountNeeded || 1) : 1,
    startDate: state.bulkForm.startDate,
    endDate: state.bulkForm.endDate,
    startTime: state.bulkForm.startTime,
    durationMinutes: state.bulkForm.durationMinutes,
    daysOfWeek: state.bulkForm.daysOfWeek,
    seasonPriceId: state.bulkForm.useSeasonPrice ? seasonPrice?.id ?? null : null,
    seasonLabel: seasonPrice ? seasonPriceLabel(seasonPrice) : null,
    hourlyRate,
    paymentStatus: "due",
    conflictResolution: "skip_conflicts",
    applyAfter: null
  };
}

function buildSingleReservationRequest(options = {}) {
  const subject = subjectById(state.bookingSubjectId);
  if (!state.bookingSubjectId || !subject) {
    throw new Error("Select a client before adding a reservation.");
  }
  if (clientTypeHasTeams(subject) && !state.bookingSubjectTeamId) {
    throw new Error("Select a team for this client before adding a reservation.");
  }
  if (shouldUseLiveAuth() && !isUuid(state.bookingSubjectId)) {
    throw new Error("This client is not loaded from Supabase yet. Refresh admin data and try again.");
  }
  return {
    label: `${subject?.displayName ?? "Team"} ${state.date}`,
    subjectId: state.bookingSubjectId,
    subjectTeamId: clientTypeHasTeams(subject) ? state.bookingSubjectTeamId : null,
    subjectName: subject?.displayName ?? state.bookingSubjectId,
    userId: state.bookingSubjectId,
    resourceType: state.resourceType,
    courtId: state.resourceType === "court" ? state.selectedCourt : null,
    courtCountNeeded: 1,
    startDate: state.date,
    endDate: state.date,
    startTime: state.time,
    durationMinutes: state.durationMinutes,
    daysOfWeek: [dayOfWeekFromDate(state.date)],
    conflictResolution: "fail_all",
    applyAfter: null,
    source: state.adminTab === "calendar" ? "calendar" : "booking",
    paymentStatus: "due",
    allowClosedDay: Boolean(options.allowClosedDay),
    ...selectedBookingPricePayload()
  };
}

function selectedBookingPricePayload() {
  const seasonPrice = selectedBookingSeasonPrice();
  return {
    seasonPriceId: seasonPrice?.id ?? null,
    seasonLabel: seasonPrice ? seasonPriceLabel(seasonPrice) : null,
    hourlyRate: seasonPrice?.hourlyRate ?? null,
    amount: seasonPrice ? seasonPrice.hourlyRate * (state.durationMinutes / 60) : null
  };
}

function buildBulkDeleteRequest() {
  const subject = subjectById(state.bulkDeleteForm.subjectId);
  return {
    subjectId: state.bulkDeleteForm.subjectId,
    subjectName: subject?.displayName,
    start: toIso(state.bulkDeleteForm.startDate, "00:00"),
    end: toIso(state.bulkDeleteForm.endDate, "23:30")
  };
}

function defaultBulkForm() {
  const firstSubject = activeClients()[0];
  const firstTeam = subjectTeamsForSubject(firstSubject?.id)[0];
  return {
    subjectId: firstSubject?.id ?? "",
    subjectTeamId: firstTeam?.id ?? "",
    resourceType: "court",
    courtId: "",
    courtCountNeeded: 1,
    startDate: todayDateKey(),
    endDate: addDateDays(todayDateKey(), 30),
    startTime: "18:00",
    durationMinutes: 120,
    hourlyRate: Number(state.settings.pricing.courtHourlyRate ?? 75),
    useSeasonPrice: true,
    daysOfWeek: [1, 2, 3, 4, 5],
    seasonPriceId: "",
    conflictResolution: "skip_conflicts",
    applyAfter: ""
  };
}

function resetBulkForm(options = {}) {
  const previous = state.bulkForm;
  state.bulkForm = defaultBulkForm();
  if (options.preserveDatesAndClient) {
    state.bulkForm.subjectId = previous.subjectId;
    state.bulkForm.subjectTeamId = previous.subjectTeamId;
    state.bulkForm.startDate = previous.startDate;
    state.bulkForm.endDate = previous.endDate;
  }
  ensureSelectedSubject();
  state.bulkPreview = null;
  state.bulkCalendarOpen = false;
}

function bulkStartTimeOptions() {
  const options = [];
  for (let minutes = 3 * 60; minutes <= 23 * 60; minutes += 30) {
    options.push(minutesToTime(minutes));
  }
  return options;
}

function bulkPreviewHasOutsideHours(preview) {
  return (preview?.items ?? []).some((item) => item.status === "conflict" && /outside operating hours/i.test(item.conflictReason ?? ""));
}

function applyBulkDeletePreviewResult(result) {
  if (Array.isArray(result)) {
    state.bulkDeletePreview = result;
    state.bulkDeleteSkippedPaid = [];
    return;
  }

  state.bulkDeletePreview = result?.deletable ?? result?.deleteable ?? result?.preview ?? [];
  state.bulkDeleteSkippedPaid = result?.skippedPaid ?? [];
}

function bulkDeleteNotice(base, deletableCount, skippedPaidCount) {
  if (!skippedPaidCount) {
    return base;
  }

  if (!deletableCount) {
    return `${base} No unpaid reservations can be deleted. ${skippedPaidCount} paid reservation${skippedPaidCount === 1 ? " was" : "s were"} protected and skipped.`;
  }

  return `${base} ${skippedPaidCount} paid reservation${skippedPaidCount === 1 ? " was" : "s were"} protected and skipped.`;
}

function bulkOperationDeleteNotice(deletedCount, skippedPaidCount) {
  const base = deletedCount
    ? `${deletedCount} reservation${deletedCount === 1 ? " was" : "s were"} deleted from the bulk reservation batch.`
    : "No unpaid reservations were deleted from the bulk reservation batch.";
  if (!skippedPaidCount) {
    return base;
  }
  return `${base} ${skippedPaidCount} paid reservation${skippedPaidCount === 1 ? " was" : "s were"} protected and skipped.`;
}

function getCurrentAvailability() {
  return getAvailabilityFor(state.time, state.durationMinutes);
}

function getAvailabilityFor(time, durationMinutes) {
  return buildScheduler().getAvailability({
    start: toIso(state.date, time),
    end: toIso(state.date, addMinutes(time, durationMinutes)),
    viewer: state.user
  });
}

function activeBookings() {
  return state.bookings.filter((booking) => !booking.deleted && booking.Deleted !== 1 && booking.status !== "cancelled");
}

function bookingPaymentStatus(booking) {
  return booking.paymentStatus ?? booking.payment_status ?? (booking.paid ? "paid" : "due");
}

function isBookingPaid(booking) {
  return bookingPaymentStatus(booking) === "paid";
}

function bookingAmount(booking) {
  return Number(booking.amount ?? booking.amountDue ?? booking.amount_due ?? 0);
}

function activeBulkOperations() {
  return state.bulkOperations.filter((operation) => !operation.deleted && operation.Deleted !== 1 && operation.status !== "deleted");
}

function activeBulkReservationOperations() {
  return activeBulkOperations().filter((operation) => operation.operationType === "reservation_create"
    && operation.status === "applied"
    && operation.requestedPayload?.source !== "calendar"
    && activeBulkOperationBookings(operation).length > 0);
}

function activeBulkOperationBookings(operation) {
  if (!operation?.id) {
    return [];
  }
  const appliedIds = new Set(operation.appliedReservationIds ?? operation.applied_reservation_ids ?? []);
  const groupId = operation.reservationGroupId ?? operation.reservation_group_id ?? operation.reservationGroup?.id ?? null;
  return activeBookings()
    .filter((booking) => booking.reservationSource !== "calendar")
    .filter((booking) => booking.bulkOperationId === operation.id
      || appliedIds.has(booking.id)
      || (groupId && booking.reservationGroupId === groupId))
    .sort((left, right) => new Date(left.start).getTime() - new Date(right.start).getTime());
}

function bulkCalendarItemFromBooking(booking) {
  return {
    id: booking.id,
    subjectId: booking.subjectId,
    subjectTeamId: booking.subjectTeamId,
    userId: booking.userId,
    resourceType: booking.resourceType,
    courtId: booking.courtId,
    courtIds: booking.courtId ? [booking.courtId] : [],
    start: booking.start,
    end: booking.end,
    status: "available",
    paymentStatus: bookingPaymentStatus(booking),
    seasonPriceId: booking.seasonPriceId,
    seasonLabel: booking.seasonLabel,
    hourlyRate: booking.hourlyRate,
    amount: bookingAmount(booking),
    conflictReason: null
  };
}

function activeSubjects() {
  return state.adminSubjects.filter((subject) => !subject.deleted && subject.Deleted !== 1);
}

function allClients() {
  return state.adminSubjects.filter((subject) => !subject.deleted && subject.Deleted !== 1);
}

function activeClients() {
  return allClients().filter((subject) => !subject.disabled && !subject.disabledAt);
}

function disabledClients() {
  return allClients().filter((subject) => subject.disabled || subject.disabledAt);
}

function sortedSubjectsForBulk() {
  return activeClients()
    .slice()
    .sort((left, right) => {
      if (left.subjectType !== right.subjectType) {
        return clientDisplayType(left).localeCompare(clientDisplayType(right));
      }
      return left.displayName.localeCompare(right.displayName);
    });
}

function activeTeamSubjects() {
  return activeClients().filter((subject) => clientTypeHasTeams(subject));
}

function activeClientTypes() {
  return state.clientTypes.filter((type) => !type.deleted && type.Deleted !== 1);
}

function clientTypeById(clientTypeId) {
  return activeClientTypes().find((type) => type.id === clientTypeId);
}

function resolveClientTypeId(clientTypeId) {
  if (clientTypeById(clientTypeId)) {
    return clientTypeId;
  }
  const demoName = String(clientTypeId ?? "").replace(/^client-type-/i, "").toLowerCase();
  return activeClientTypes().find((type) => String(type.name ?? "").toLowerCase() === demoName)?.id
    ?? activeClientTypes()[0]?.id
    ?? "";
}

function clientTypeForSubject(subject) {
  return clientTypeById(subject?.clientTypeId) ?? activeClientTypes().find((type) => type.name === subject?.clientTypeName || type.name === subject?.subjectType);
}

function clientTypeHasTeams(subject) {
  return Boolean(subject && (subject.clientTypeHaveTeams ?? clientTypeForSubject(subject)?.haveTeams));
}

function clientDisplayType(subject) {
  return subject?.clientTypeName ?? clientTypeForSubject(subject)?.name ?? subject?.subjectType ?? "Client";
}

function clientShortName(subject) {
  return subject?.shortName ?? subject?.short_name ?? subject?.displayName ?? "Client";
}

function mergeSubjectTeams(subjects, teams) {
  if (!teams.length) {
    return subjects;
  }

  const teamsBySubjectId = new Map();
  teams.forEach((team) => {
    const subjectTeams = teamsBySubjectId.get(team.subjectId) ?? [];
    subjectTeams.push(team);
    teamsBySubjectId.set(team.subjectId, subjectTeams);
  });

  return subjects.map((subject) => ({
    ...subject,
    teams: teamsBySubjectId.get(subject.id) ?? subject.teams ?? []
  }));
}

function subjectTeamsForSubject(subjectId) {
  return (subjectById(subjectId)?.teams ?? [])
    .filter((team) => !team.deleted && team.Deleted !== 1)
    .map(normalizeSubjectTeam);
}

function subjectTeamById(teamId) {
  for (const subject of allClients()) {
    const team = (subject.teams ?? []).map(normalizeSubjectTeam).find((candidate) => candidate.id === teamId);
    if (team) {
      return team;
    }
  }
  return null;
}

function activeSeasons() {
  return state.seasons
    .filter((season) => !season.deleted && season.Deleted !== 1)
    .slice()
    .sort((left, right) => Number(right.startYear) - Number(left.startYear));
}

function latestSeason() {
  return activeSeasons()[0] ?? null;
}

function seasonById(seasonId) {
  return activeSeasons().find((season) => season.id === seasonId);
}

function seasonByYear(startYear) {
  return activeSeasons().find((season) => season.startYear === Number(startYear));
}

function activeSeasonPrices() {
  return state.teamSeasonPrices
    .filter((price) => !price.deleted && price.Deleted !== 1)
    .slice()
    .sort((left, right) => Number(right.seasonYear) - Number(left.seasonYear) || String(right.season).localeCompare(String(left.season)));
}

function seasonPriceYearOptions() {
  const years = new Set(activeSeasonPrices().map((price) => String(price.seasonYear)).filter(Boolean));
  const latest = latestSeason()?.startYear;
  if (latest) {
    years.add(String(latest));
  }
  return [...years].sort((left, right) => Number(right) - Number(left));
}

function selectedSeasonPriceYearFilter() {
  const options = seasonPriceYearOptions();
  if (!options.length) {
    return "";
  }
  if (!state.seasonPriceYearFilter || !options.includes(String(state.seasonPriceYearFilter))) {
    state.seasonPriceYearFilter = options[0];
  }
  return String(state.seasonPriceYearFilter);
}

function filteredSeasonPrices() {
  const year = selectedSeasonPriceYearFilter();
  return activeSeasonPrices().filter((price) => !year || String(price.seasonYear) === year);
}

function seasonPricesForSubject(subjectId) {
  return activeSeasonPrices().filter((price) => price.subjectId === subjectId);
}

function latestSeasonPriceForSubject(subjectId) {
  return seasonPricesForSubject(subjectId)[0] ?? null;
}

function latestSeasonPriceForSelectedBulkSubject() {
  return seasonPriceForLatestSeason(state.bulkForm.subjectId);
}

function seasonPriceForLatestSeason(subjectId) {
  const latest = latestSeason();
  if (!latest) {
    return null;
  }
  return seasonPricesForSubject(subjectId).find((price) => price.seasonId === latest.id || Number(price.seasonYear) === Number(latest.startYear)) ?? null;
}

function isBulkTeamSubjectSelected() {
  return clientTypeHasTeams(subjectById(state.bulkForm.subjectId));
}

function selectedBulkSeasonPrice() {
  if (!state.bulkForm.useSeasonPrice) {
    return null;
  }
  const latest = latestSeasonPriceForSelectedBulkSubject();
  if (!latest) {
    return null;
  }
  return latest.id === state.bulkForm.seasonPriceId ? latest : latest;
}

function selectedBookingSeasonPrice() {
  const options = seasonPricesForSubject(state.bookingSubjectId);
  return options.find((price) => price.id === state.bookingSeasonPriceId) ?? options[0] ?? null;
}

function adminUsers() {
  const source = shouldUseLiveAuth() ? state.allUsers : state.allUsers.length ? state.allUsers : demoUsers;
  return source.map(normalizeAdminUser);
}

function normalizeAdminUser(user) {
  const approvalStatus = String(user.approvalStatus ?? user.approval_status ?? (user.approved ? "approved" : "pending")).toLowerCase();
  const role = String(user.role ?? user.accountRole ?? user.account_role ?? "user").toLowerCase();
  return {
    ...user,
    name: user.name ?? user.displayName ?? user.display_name ?? user.username ?? "Unnamed user",
    role,
    approvalStatus,
    approved: approvalStatus === "approved"
  };
}

function normalizeAdminMenuItem(item) {
  const key = item.key ?? item.menuKey ?? item.menu_key;
  return {
    ...item,
    key,
    name: item.name ?? item.label ?? item.menu_name ?? "Menu item",
    pageOrder: Number(item.pageOrder ?? item.page_order ?? 999),
    isActive: item.isActive ?? item.is_active ?? true,
    requiredRole: item.requiredRole ?? item.required_role ?? "admin",
    requiredPermission: item.requiredPermission ?? item.required_permission ?? "admin.full_access"
  };
}

function activeAdminMenuItems() {
  const source = state.adminMenuItems?.length ? state.adminMenuItems : defaultAdminMenuItems;
  const menuItems = source
    .map(normalizeAdminMenuItem)
    .filter((item) => item.key && item.isActive !== false)
    .sort((left, right) => left.pageOrder - right.pageOrder || left.name.localeCompare(right.name));
  return menuItems.length ? menuItems : defaultAdminMenuItems.map(normalizeAdminMenuItem);
}

function allActiveAdminMenuItems() {
  const source = state.adminAllMenuItems?.length ? state.adminAllMenuItems : activeAdminMenuItems();
  const menuItems = source
    .map(normalizeAdminMenuItem)
    .filter((item) => item.key && item.isActive !== false)
    .sort((left, right) => left.pageOrder - right.pageOrder || left.name.localeCompare(right.name));
  return menuItems.length ? menuItems : activeAdminMenuItems();
}

function syncAdminRightsSelectAllControl() {
  const control = document.querySelector("[data-admin-rights-all]");
  if (!control) {
    return;
  }

  const menuItems = allActiveAdminMenuItems();
  const selectedCount = menuItems.filter((item) => state.editUserRightsForm[item.key]).length;
  control.indeterminate = selectedCount > 0 && selectedCount < menuItems.length;
  control.checked = menuItems.length > 0 && selectedCount === menuItems.length;
}

function normalizeAdminMenuRight(right) {
  return {
    ...right,
    profileId: right.profileId ?? right.profile_id,
    menuItemId: right.menuItemId ?? right.menu_item_id,
    menuKey: right.menuKey ?? right.menu_key ?? right.key,
    hasAccess: right.hasAccess ?? right.has_access ?? true
  };
}

function adminRightsFormForUser(userId) {
  const existingRights = state.adminMenuRights
    .map(normalizeAdminMenuRight)
    .filter((right) => right.profileId === userId);
  const hasConfiguredRights = existingRights.length > 0;
  const rightsByKey = new Map(existingRights.map((right) => [right.menuKey, right.hasAccess !== false]));

  return Object.fromEntries(allActiveAdminMenuItems().map((item) => [
    item.key,
    hasConfiguredRights ? rightsByKey.get(item.key) === true : true
  ]));
}

function ensureAdminTabAvailable() {
  const menuItems = activeAdminMenuItems();
  if (!menuItems.some((item) => item.key === state.adminTab)) {
    state.adminTab = menuItems[0]?.key ?? "payments";
  }
}

function normalizeClientType(clientType) {
  return {
    ...clientType,
    name: clientType.name,
    haveTeams: Boolean(clientType.haveTeams ?? clientType.have_teams),
    deleted: Boolean(clientType.deleted ?? clientType.Deleted)
  };
}

function normalizeSubjectTeam(team) {
  return {
    ...team,
    subjectId: team.subjectId ?? team.subject_id,
    shortName: team.shortName ?? team.short_name ?? team.name,
    coachName: team.coachName ?? team.coach_name ?? "",
    coachEmail: team.coachEmail ?? team.coach_email ?? "",
    coachPhone: team.coachPhone ?? team.coach_phone ?? "",
    coachSafeSport: Boolean(team.coachSafeSport ?? team.coach_safe_sport),
    coachBackgroundCheck: Boolean(team.coachBackgroundCheck ?? team.coach_background_check),
    coachConcussion: Boolean(team.coachConcussion ?? team.coach_concussion),
    clubInsuranceReceived: Boolean(team.clubInsuranceReceived ?? team.club_insurance_received),
    deleted: Boolean(team.deleted ?? team.Deleted)
  };
}

function defaultTeamForm() {
  return {
    name: "",
    shortName: "",
    coachName: "",
    coachEmail: "",
    coachPhone: "",
    coachSafeSport: false,
    coachBackgroundCheck: false,
    coachConcussion: false,
    clubInsuranceReceived: false
  };
}

function teamFormFromTeam(team) {
  const normalized = normalizeSubjectTeam(team);
  return {
    name: normalized.name,
    shortName: normalized.shortName ?? "",
    coachName: normalized.coachName,
    coachEmail: normalized.coachEmail,
    coachPhone: normalized.coachPhone,
    coachSafeSport: normalized.coachSafeSport,
    coachBackgroundCheck: normalized.coachBackgroundCheck,
    coachConcussion: normalized.coachConcussion,
    clubInsuranceReceived: normalized.clubInsuranceReceived
  };
}

function buildSubjectTeamPayload(subjectId, form, name = form.name.trim()) {
  return {
    subjectId,
    name: name.trim(),
    shortName: String(form.shortName ?? "").trim() || name.trim().slice(0, 24),
    coachName: String(form.coachName ?? "").trim(),
    coachEmail: String(form.coachEmail ?? "").trim(),
    coachPhone: String(form.coachPhone ?? "").trim(),
    coachSafeSport: Boolean(form.coachSafeSport),
    coachBackgroundCheck: Boolean(form.coachBackgroundCheck),
    coachConcussion: Boolean(form.coachConcussion),
    clubInsuranceReceived: Boolean(form.clubInsuranceReceived)
  };
}

function teamComplianceComplete(team) {
  const normalized = normalizeSubjectTeam(team);
  return normalized.coachSafeSport
    && normalized.coachBackgroundCheck
    && normalized.coachConcussion
    && normalized.clubInsuranceReceived;
}

function teamLabelDetail(team) {
  const normalized = normalizeSubjectTeam(team);
  const coach = normalized.coachName ? `Coach: ${normalized.coachName}` : "Coach missing";
  const docs = [
    normalized.coachSafeSport ? "SafeSport" : "",
    normalized.coachBackgroundCheck ? "Background" : "",
    normalized.coachConcussion ? "Concussion" : "",
    normalized.clubInsuranceReceived ? "Insurance" : ""
  ].filter(Boolean).join(", ");
  return [normalized.shortName, coach, docs || "documents missing"].filter(Boolean).join(" · ");
}

function normalizeSubject(subject) {
  return {
    ...subject,
    subjectType: subject.subjectType ?? subject.subject_type ?? subject.clientTypeName ?? "Client",
    clientTypeId: subject.clientTypeId ?? subject.client_type_id ?? null,
    clientTypeName: subject.clientTypeName ?? subject.client_type_name ?? subject.subjectType ?? subject.subject_type ?? "Client",
    clientTypeHaveTeams: Boolean(subject.clientTypeHaveTeams ?? subject.client_type_have_teams),
    displayName: subject.displayName ?? subject.display_name,
    shortName: subject.shortName ?? subject.short_name ?? subject.displayName ?? subject.display_name,
    contactName: subject.contactName ?? subject.contact_name ?? "",
    contactEmail: subject.contactEmail ?? subject.contact_email ?? "",
    contactPhone: subject.contactPhone ?? subject.contact_phone ?? "",
    disabled: Boolean(subject.disabled || subject.disabledAt || subject.disabled_at),
    disabledAt: subject.disabledAt ?? subject.disabled_at ?? null,
    disabledReason: subject.disabledReason ?? subject.disabled_reason ?? "",
    teams: (subject.teams ?? []).map(normalizeSubjectTeam),
    deleted: Boolean(subject.deleted ?? subject.Deleted)
  };
}

function normalizeSeason(season) {
  const startYear = Number(season.startYear ?? season.start_year);
  return {
    ...season,
    startYear,
    displayName: season.displayName ?? season.display_name ?? formatSeasonYear(startYear),
    deleted: Boolean(season.deleted ?? season.Deleted)
  };
}

function normalizeSeasonPrice(price) {
  const startYear = Number(price.seasonYear ?? price.season_year);
  const displayName = price.seasonDisplayName ?? price.season_display_name ?? price.season ?? seasonByYear(startYear)?.displayName ?? formatSeasonYear(startYear);
  return {
    ...price,
    subjectId: price.subjectId ?? price.subject_id,
    teamName: price.teamName ?? price.team_name,
    seasonId: price.seasonId ?? price.season_id ?? seasonByYear(startYear)?.id,
    season: displayName,
    seasonYear: startYear,
    seasonDisplayName: displayName,
    hourlyRate: Number(price.hourlyRate ?? price.hourly_rate),
    documentsReceived: Boolean(price.documentsReceived ?? price.documents_received),
    deposit: Number(price.deposit ?? 0),
    deleted: Boolean(price.deleted ?? price.Deleted)
  };
}

function normalizeInvoice(invoice) {
  return {
    ...invoice,
    id: invoice.id,
    paymentId: invoice.paymentId ?? invoice.payment_id ?? null,
    paymentKey: invoice.paymentKey ?? invoice.payment_key ?? null,
    invoiceNumber: invoice.invoiceNumber ?? invoice.invoice_number,
    subjectId: invoice.subjectId ?? invoice.subject_id,
    subjectName: invoice.subjectName ?? invoice.subject_name ?? subjectById(invoice.subjectId ?? invoice.subject_id)?.displayName ?? userById(invoice.subjectId ?? invoice.subject_id)?.name ?? "Unknown",
    subjectType: invoice.subjectType ?? invoice.subject_type ?? subjectById(invoice.subjectId ?? invoice.subject_id)?.subjectType ?? "user",
    contactEmail: invoice.contactEmail ?? invoice.contact_email ?? userById(invoice.subjectId ?? invoice.subject_id)?.email ?? "",
    billingRule: invoice.billingRule ?? invoice.billing_rule ?? "",
    periodStart: invoice.periodStart ?? invoice.period_start,
    periodEnd: invoice.periodEnd ?? invoice.period_end,
    amount: Number(invoice.amount ?? invoice.amount_due ?? 0),
    minutes: Number(invoice.minutes ?? 0),
    reservationIds: invoice.reservationIds ?? invoice.reservation_ids ?? [],
    reservations: invoice.reservations ?? [],
    createdAt: invoice.createdAt ?? invoice.created_at ?? invoice.createdDT ?? new Date().toISOString(),
    status: invoice.status ?? "created"
  };
}

function normalizePaymentRecord(payment) {
  const reservations = payment.reservations ?? payment.bookings ?? [];
  const reservationIds = payment.reservationIds ?? payment.reservation_ids ?? reservations.map((booking) => booking.id);
  const normalized = {
    ...payment,
    id: payment.id ?? null,
    subjectId: payment.subjectId ?? payment.subject_id ?? null,
    name: payment.name ?? payment.subjectName ?? payment.subject_name ?? "Unknown",
    subjectType: payment.subjectType ?? payment.subject_type ?? "user",
    contactEmail: payment.contactEmail ?? payment.contact_email ?? "",
    billingRule: payment.billingRule ?? payment.billing_rule ?? "manual",
    periodStart: payment.periodStart ?? payment.period_start ?? "",
    periodEnd: payment.periodEnd ?? payment.period_end ?? "",
    amount: Number(payment.amount ?? payment.amount_due ?? 0),
    minutes: Number(payment.minutes ?? 0),
    reservationIds,
    bookings: reservations,
    status: payment.status ?? "due",
    invoiceId: payment.invoiceId ?? payment.invoice_id ?? null,
    paidAt: payment.paidAt ?? payment.paid_at ?? null
  };
  normalized.reservationCount = Number(payment.reservationCount ?? payment.reservation_count ?? reservationIds.length ?? reservations.length);
  normalized.key = payment.paymentKey ?? payment.payment_key ?? payment.key ?? paymentRecordKey(normalized);
  normalized.paymentKey = normalized.key;
  normalized.label = payment.label ?? `${normalized.periodStart ? formatShortDate(normalized.periodStart) : "Manual"}-${normalized.periodEnd ? formatShortDate(normalized.periodEnd) : "payment"}`;
  return normalized;
}

function subjectById(subjectId) {
  return activeClients().find((subject) => subject.id === subjectId);
}

function userById(userId) {
  return adminUsers().find((user) => user.id === userId);
}

function isCurrentAdminUser(userId) {
  return Boolean(userId && state.user?.id === userId);
}

function bookingDisplayName(booking) {
  return bookingCalendarLabel(booking);
}

function bookingClientTeamLabel(booking) {
  const subject = subjectById(booking.subjectId);
  const clientName = subject?.displayName
    ?? userById(booking.userId)?.name
    ?? booking.teamId
    ?? booking.subjectId
    ?? booking.userId
    ?? "Unassigned";
  const teamName = booking.teamShortName
    ?? subjectTeamById(booking.subjectTeamId)?.name
    ?? subjectTeamById(booking.subject_team_id)?.name
    ?? booking.teamName
    ?? booking.team_name
    ?? "";

  if (!teamName || teamName === clientName || subject?.subjectType === "coach") {
    return clientName;
  }
  return `${clientName} - ${teamName}`;
}

function reportClientLabel(booking) {
  return subjectById(booking.subjectId)?.displayName
    ?? userById(booking.userId)?.name
    ?? booking.teamId
    ?? booking.subjectId
    ?? booking.userId
    ?? "Unassigned";
}

function bookingCalendarLabel(booking) {
  return booking.teamShortName
    ?? subjectTeamById(booking.subjectTeamId)?.shortName
    ?? subjectTeamById(booking.subject_team_id)?.shortName
    ?? clientShortName(subjectById(booking.subjectId))
    ?? booking.teamId
    ?? userById(booking.userId)?.team
    ?? userById(booking.userId)?.name
    ?? booking.subjectId
    ?? booking.userId
    ?? "Unassigned";
}

function paymentDueLabel(booking) {
  return paymentAmountLabel(bookingAmount(booking));
}

function paymentAmountLabel(amount) {
  return `Amount: ${formatCurrency(Number(amount ?? 0))}`;
}

function paymentDueAccounts() {
  const previous = previousMonthRange(todayDateKey());
  const today = todayDateKey();
  const candidates = activeBookings().filter((booking) => !isBookingPaid(booking));
  const scoped = candidates.filter((booking) => {
    const subject = subjectById(booking.subjectId);
    const dateKey = isoDateKey(booking.start);
    if (clientTypeHasTeams(subject)) {
      return dateKey >= previous.start && dateKey <= previous.end;
    }
    if (subject?.subjectType === "coach") {
      return dateKey < today;
    }
    return dateKey < today;
  });
  return paymentDueSummaries(scoped);
}

function pastPaymentRecords() {
  const recorded = state.payments
    .map(normalizePaymentRecord)
    .filter((payment) => payment.status === "paid")
    .map((payment) => ({
      ...payment,
      bookings: payment.bookings.length ? payment.bookings : bookingsByIds(payment.reservationIds)
    }));
  const invoicePaid = state.invoices
    .map(normalizeInvoice)
    .filter((invoice) => invoice.status === "paid")
    .map((invoice) => paymentFromInvoice(invoice));
  const paidBookings = activeBookings().filter((booking) => isBookingPaid(booking));
  const derived = paymentDueSummaries(paidBookings).map((payment) => ({ ...payment, status: "paid" }));
  const seen = new Set();
  return [...recorded, ...invoicePaid, ...derived]
    .filter((payment) => {
      const key = payment.paymentKey ?? payment.key;
      if (seen.has(key)) {
        return false;
      }
      seen.add(key);
      return true;
    })
    .sort((left, right) => String(right.periodEnd ?? "").localeCompare(String(left.periodEnd ?? "")) || left.name.localeCompare(right.name));
}

function invoiceForPayment(payment) {
  const reservationIds = new Set(payment.bookings.map((booking) => booking.id));
  return state.invoices.map(normalizeInvoice).find((invoice) => {
    if (invoice.paymentKey === payment.key) {
      return true;
    }
    if (invoice.subjectId !== payment.subjectId || invoice.billingRule !== payment.billingRule) {
      return false;
    }
    if (invoice.periodStart !== payment.periodStart || invoice.periodEnd !== payment.periodEnd) {
      return false;
    }
    return (invoice.reservationIds ?? []).some((id) => reservationIds.has(id));
  });
}

function rememberPaymentRecord(payment) {
  const record = normalizePaymentRecord({
    ...payment,
    reservations: payment.bookings,
    reservationIds: payment.bookings.map((booking) => booking.id)
  });
  state.payments = [record, ...state.payments.filter((candidate) => normalizePaymentRecord(candidate).key !== record.key)];
}

function paymentDueSummaries(bookings) {
  const groups = new Map();
  for (const booking of bookings) {
    const baseKey = booking.subjectId ?? booking.userId ?? booking.teamId ?? bookingDisplayName(booking);
    const subject = subjectById(booking.subjectId);
    const existing = groups.get(baseKey) ?? {
      key: baseKey,
      paymentKey: baseKey,
      subjectId: booking.subjectId ?? null,
      name: bookingDisplayName(booking),
      subjectType: subject?.subjectType ?? "user",
      contactEmail: subject?.contactEmail ?? userById(booking.userId)?.email ?? "",
      amount: 0,
      minutes: 0,
      reservationCount: 0,
      periodStart: "",
      periodEnd: "",
      billingRule: "",
      bookings: []
    };
    existing.amount += Number(bookingAmount(booking) ?? 0);
    existing.minutes += reservationMinutes(booking);
    existing.reservationCount += 1;
    existing.bookings.push(booking);
    if (clientTypeHasTeams(subjectById(existing.subjectId))) {
      const previous = previousMonthRange(todayDateKey());
      existing.periodStart = previous.start;
      existing.periodEnd = previous.end;
      existing.billingRule = "previous_month_team";
      existing.label = `Previous month (${formatShortDate(previous.start)}-${formatShortDate(previous.end)})`;
    } else {
      existing.periodStart = existing.bookings.map((item) => isoDateKey(item.start)).sort()[0] ?? "";
      existing.periodEnd = todayDateKey();
      existing.billingRule = "unpaid_past_coach";
      existing.label = "Unpaid past reservations";
    }
    existing.key = paymentRecordKey(existing);
    existing.paymentKey = existing.key;
    groups.set(baseKey, existing);
  }
  return [...groups.values()].sort((left, right) => left.name.localeCompare(right.name));
}

function paymentRecordKey(payment) {
  return [
    payment.subjectId ?? payment.name,
    payment.billingRule ?? "manual",
    payment.periodStart ?? "",
    payment.periodEnd ?? "",
    (payment.bookings ?? []).map((booking) => booking.id).sort().join(",")
  ].join("|");
}

function paymentFromInvoice(invoice) {
  const bookings = invoice.reservations?.length ? invoice.reservations : bookingsByIds(invoice.reservationIds);
  return {
    key: invoice.paymentKey ?? paymentRecordKey({
      subjectId: invoice.subjectId,
      billingRule: invoice.billingRule,
      periodStart: invoice.periodStart,
      periodEnd: invoice.periodEnd,
      bookings
    }),
    paymentKey: invoice.paymentKey,
    subjectId: invoice.subjectId,
    name: invoice.subjectName,
    subjectType: invoice.subjectType,
    contactEmail: invoice.contactEmail,
    amount: invoice.amount,
    minutes: invoice.minutes,
    reservationCount: bookings.length || invoice.reservationIds.length,
    periodStart: invoice.periodStart,
    periodEnd: invoice.periodEnd,
    billingRule: invoice.billingRule,
    label: `Invoice ${invoice.invoiceNumber}`,
    status: invoice.status,
    bookings,
    invoiceId: invoice.id
  };
}

function bookingsByIds(ids = []) {
  const idsSet = new Set(ids);
  return activeBookings().filter((booking) => idsSet.has(booking.id));
}

function reservationMinutes(booking) {
  const start = new Date(booking.start);
  const end = new Date(booking.end);
  if (Number.isNaN(start.getTime()) || Number.isNaN(end.getTime())) {
    return 0;
  }
  return Math.max(0, (end.getTime() - start.getTime()) / 60000);
}

function filteredInvoices() {
  const filters = state.invoiceFilters;
  return state.invoices
    .map(normalizeInvoice)
    .filter((invoice) => !filters.subjectId || invoice.subjectId === filters.subjectId)
    .filter((invoice) => !filters.type || invoice.subjectType === filters.type)
    .filter((invoice) => !filters.year || isoDateKey(invoice.createdAt).slice(0, 4) === filters.year)
    .filter((invoice) => !filters.month || isoDateKey(invoice.createdAt).slice(5, 7) === filters.month)
    .sort((left, right) => {
      const direction = filters.sortDirection === "asc" ? 1 : -1;
      const leftValue = left[filters.sortBy] ?? "";
      const rightValue = right[filters.sortBy] ?? "";
      if (filters.sortBy === "amount") {
        return (Number(leftValue) - Number(rightValue)) * direction;
      }
      return String(leftValue).localeCompare(String(rightValue)) * direction;
    });
}

function invoiceYearOptions() {
  const current = todayDateKey().slice(0, 4);
  const years = new Set([current]);
  for (const invoice of state.invoices.map(normalizeInvoice)) {
    years.add(isoDateKey(invoice.createdAt).slice(0, 4));
  }
  return [...years].sort((left, right) => Number(right) - Number(left));
}

function invoiceMonthOptions() {
  return Array.from({ length: 12 }, (_, index) => {
    const value = String(index + 1).padStart(2, "0");
    const label = new Intl.DateTimeFormat("en-US", { month: "long", timeZone: "UTC" }).format(new Date(`2026-${value}-01T12:00:00Z`));
    return { value, label };
  });
}

function adminCalendarMonthOptions() {
  const options = [];
  const floor = "2026-06";
  const ceiling = addMonths(todayDateKey().slice(0, 7), 72);
  let cursor = floor;
  while (cursor <= ceiling) {
    options.push(cursor);
    cursor = addMonths(cursor, 1);
  }
  return options;
}

function normalizeClosure(closure) {
  return {
    ...closure,
    resourceType: closure.resourceType ?? closure.resource_type ?? "all",
    courtId: closure.courtId ?? (closure.court_number ? `court-${closure.court_number}` : null),
    start: closure.start ?? closure.start_at,
    end: closure.end ?? closure.end_at,
    reason: closure.reason ?? "Closed",
    deleted: Boolean(closure.deleted ?? closure.Deleted)
  };
}

function defaultClosureForm() {
  return {
    resourceType: "all",
    courtId: "",
    startDate: todayDateKey(),
    endDate: todayDateKey(),
    startTime: "00:00",
    endTime: "23:59",
    reason: ""
  };
}

function activeClosures() {
  return (state.settings.closures ?? []).map(normalizeClosure).filter((closure) => !closure.deleted && closure.Deleted !== 1);
}

function closureResourceLabel(closure) {
  const normalized = normalizeClosure(closure);
  if (normalized.resourceType === "court") {
    return normalized.courtId ? labelCourt(normalized.courtId) : "All courts";
  }
  if (normalized.resourceType === "trainer") {
    return "Trainer gym";
  }
  return "Facility";
}

function closureForDate(dateKey) {
  const dayStart = new Date(toIso(dateKey, "00:00"));
  const dayEnd = new Date(toIso(dateKey, "23:59"));
  return activeClosures().find((closure) => {
    const closureStart = new Date(closure.start);
    const closureEnd = new Date(closure.end);
    return closureStart < dayEnd && dayStart < closureEnd;
  }) ?? null;
}

function closureBlocksSlot(dateKey, startTime, endTime, resourceType = "court", courtId = null) {
  const slotStart = new Date(toIso(dateKey, startTime));
  const slotEnd = new Date(toIso(dateKey, endTime));
  return activeClosures().find((closure) => {
    if (closure.resourceType !== "all" && closure.resourceType !== resourceType) {
      return false;
    }
    if (resourceType === "court" && closure.courtId && closure.courtId !== courtId) {
      return false;
    }
    const closureStart = new Date(closure.start);
    const closureEnd = new Date(closure.end);
    return closureStart < slotEnd && slotStart < closureEnd;
  }) ?? null;
}

function closureForReservationForm() {
  return closureBlocksSlot(state.date, state.time, addMinutes(state.time, state.durationMinutes), state.resourceType, state.selectedCourt);
}

function invoiceById(invoiceId) {
  return state.invoices.map(normalizeInvoice).find((invoice) => invoice.id === invoiceId);
}

function nextInvoiceNumber() {
  return state.invoices.length + 1;
}

function invoiceHtml(invoice) {
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>${escapeHtml(invoice.invoiceNumber)}</title>
  <style>
    body { font-family: Arial, sans-serif; color: #1f2933; margin: 40px; }
    header { display: flex; justify-content: space-between; border-bottom: 2px solid #1f2933; padding-bottom: 18px; margin-bottom: 24px; }
    h1 { margin: 0; font-size: 28px; }
    table { width: 100%; border-collapse: collapse; margin-top: 24px; }
    th, td { border-bottom: 1px solid #d8dee4; padding: 10px; text-align: left; }
    th { background: #f4f7f7; }
    .amount { text-align: right; }
    .total { font-size: 20px; font-weight: 700; }
    @media print { button { display: none; } body { margin: 24px; } }
  </style>
</head>
<body>
  <button onclick="window.print()">Print</button>
  <header>
    <div>
      <h1>A to Z Volleyball Center</h1>
      <p>Invoice ${escapeHtml(invoice.invoiceNumber)}</p>
    </div>
    <div>
      <strong>${escapeHtml(invoice.subjectName)}</strong><br>
      ${escapeHtml(invoice.contactEmail ?? "")}<br>
      Created ${formatShortDate(invoice.createdAt)}
    </div>
  </header>
  <p><strong>Billing period:</strong> ${formatShortDate(invoice.periodStart)} to ${formatShortDate(invoice.periodEnd)}</p>
  <table>
    <thead><tr><th>Date</th><th>Resource</th><th>Time</th><th class="amount">Amount</th></tr></thead>
    <tbody>
      ${(invoice.reservations ?? []).map((booking) => `
        <tr>
          <td>${formatShortDate(booking.start)}</td>
          <td>${booking.resourceType === "court" ? labelCourt(booking.courtId) : "Trainer gym"}</td>
          <td>${formatShortTime(booking.start)}-${formatShortTime(booking.end)}</td>
          <td class="amount">${paymentDueLabel(booking)}</td>
        </tr>
      `).join("")}
      <tr><td colspan="3" class="total">Total due</td><td class="amount total">${formatCurrency(invoice.amount)}</td></tr>
    </tbody>
  </table>
</body>
</html>`;
}

function reservationReport() {
  const startDate = state.reportFilters.startDate || "1900-01-01";
  const endDate = state.reportFilters.endDate || "2999-12-31";
  const today = todayDateKey();
  const reservations = activeBookings()
    .filter((booking) => !state.reportFilters.subjectId || booking.subjectId === state.reportFilters.subjectId)
    .filter((booking) => {
      const dateKey = isoDateKey(booking.start);
      return dateKey >= startDate && dateKey <= endDate;
    })
    .sort((left, right) => new Date(left.start).getTime() - new Date(right.start).getTime());
  const currentPastReservations = reservations.filter((booking) => isoDateKey(booking.start) < today);
  const futureReservations = reservations.filter((booking) => isoDateKey(booking.start) >= today);
  const paymentTotals = reportPaymentTotals(startDate, endDate);
  return {
    reservations,
    detailRows: reportDetailRows(reservations),
    filters: { ...state.reportFilters },
    currentPast: {
      ...paymentTotals,
      reservations: currentPastReservations.length,
      minutes: currentPastReservations.reduce((sum, booking) => sum + reservationMinutes(booking), 0)
    },
    future: {
      amount: futureReservations.reduce((sum, booking) => sum + bookingAmount(booking), 0),
      reservations: futureReservations.length,
      minutes: futureReservations.reduce((sum, booking) => sum + reservationMinutes(booking), 0)
    }
  };
}

function reportDetailRows(reservations) {
  const grouped = new Map();

  for (const booking of reservations) {
    const client = reportClientLabel(booking);
    const date = isoDateKey(booking.start);
    const key = `${client}|${date}`;
    const existing = grouped.get(key) ?? {
      client,
      date,
      minutes: 0,
      courts: 0,
      amount: 0
    };

    existing.minutes += reservationMinutes(booking);
    existing.courts += booking.resourceType === "court" ? 1 : 0;
    existing.amount += bookingAmount(booking);
    grouped.set(key, existing);
  }

  return [...grouped.values()].sort((left, right) => {
    if (left.client !== right.client) {
      return left.client.localeCompare(right.client);
    }
    return left.date.localeCompare(right.date);
  });
}

function reportSubjectLabel(subjectId) {
  if (!subjectId) {
    return "All clients";
  }
  return subjectById(subjectId)?.displayName ?? "Selected client";
}

function reportPaymentTotals(startDate, endDate) {
  const paidPayments = state.payments
    .map(normalizePaymentRecord)
    .filter((payment) => !state.reportFilters.subjectId || payment.subjectId === state.reportFilters.subjectId)
    .filter((payment) => {
      const periodEnd = payment.periodEnd || payment.periodStart || "";
      return !periodEnd || (periodEnd >= startDate && periodEnd <= endDate);
    });
  const due = paymentDueAccounts()
    .filter((payment) => !state.reportFilters.subjectId || payment.subjectId === state.reportFilters.subjectId)
    .flatMap((payment) => payment.bookings)
    .filter((booking) => {
      const dateKey = isoDateKey(booking.start);
      return dateKey >= startDate && dateKey <= endDate;
    })
    .reduce((sum, booking) => sum + bookingAmount(booking), 0);
  const paid = paidPayments.filter((payment) => payment.status === "paid").reduce((sum, payment) => sum + payment.amount, 0);
  return {
    due,
    paid,
    total: due + paid
  };
}

function createReport() {
  state.report = reservationReport();
  state.notice = "Report created.";
  render();
}

function printReport() {
  const report = state.report;
  if (!report) {
    state.notice = "Create a report before printing.";
    render();
    return;
  }

  if (!printHtmlDocument(reportHtml(report, { summaryOnly: false }))) {
    state.notice = "Print preview could not be opened.";
    render();
    return;
  }

  state.notice = "Print dialog opened.";
  render();
}

function printReportSummary() {
  const report = state.report;
  if (!report) {
    state.notice = "Create a report before printing.";
    render();
    return;
  }

  if (!printHtmlDocument(reportHtml(report, { summaryOnly: true }))) {
    state.notice = "Print preview could not be opened.";
    render();
    return;
  }

  state.notice = "Summary print dialog opened.";
  render();
}

function printHtmlDocument(html) {
  const existingFrame = document.getElementById("a2z-print-frame");
  existingFrame?.remove();

  const frame = document.createElement("iframe");
  frame.id = "a2z-print-frame";
  frame.title = "Print preview";
  frame.setAttribute("aria-hidden", "true");
  frame.style.position = "fixed";
  frame.style.right = "0";
  frame.style.bottom = "0";
  frame.style.width = "0";
  frame.style.height = "0";
  frame.style.border = "0";
  frame.style.visibility = "hidden";
  document.body.appendChild(frame);

  const frameDocument = frame.contentDocument ?? frame.contentWindow?.document;
  if (!frameDocument || !frame.contentWindow) {
    frame.remove();
    return false;
  }

  frameDocument.open();
  frameDocument.write(html);
  frameDocument.close();
  const cleanup = () => frame.remove();
  frame.contentWindow.addEventListener("afterprint", cleanup, { once: true });
  window.setTimeout(cleanup, 30000);
  window.setTimeout(() => {
    frame.contentWindow.focus();
    frame.contentWindow.print();
  }, 100);
  return true;
}

function reportHtml(report, options = {}) {
  const summaryOnly = Boolean(options.summaryOnly);
  return `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>${summaryOnly ? "A2Z Reservation Summary" : "A2Z Reservation Report"}</title>
  <style>
    @page { size: auto; margin: 0.35in; }
    * { box-sizing: border-box; }
    body {
      font-family: Arial, sans-serif;
      color: #17202a;
      margin: 0;
      background: white;
      font-size: 10.5px;
      line-height: 1.35;
    }
    header {
      display: flex;
      justify-content: space-between;
      gap: 18px;
      border-bottom: 2px solid #17202a;
      margin-bottom: 14px;
      padding-bottom: 10px;
    }
    h1 { font-size: 20px; margin: 0 0 4px; }
    h2 { font-size: 13px; margin: 16px 0 8px; page-break-after: avoid; }
    p { margin: 0; }
    .meta { text-align: right; color: #52606d; }
    table {
      width: 100%;
      border-collapse: collapse;
      table-layout: fixed;
      margin-top: 8px;
      page-break-inside: auto;
    }
    thead { display: table-header-group; }
    tr { page-break-inside: avoid; break-inside: avoid; }
    th, td {
      border-bottom: 1px solid #d8dee4;
      padding: 6px 7px;
      text-align: left;
      vertical-align: top;
      overflow-wrap: anywhere;
    }
    th {
      background: #eef5f4;
      color: #1f2933;
      font-size: 9.5px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .summary-table {
      margin: 10px 0 18px;
      page-break-inside: avoid;
      break-inside: avoid;
      border: 1px solid #cbd5df;
    }
    .summary-table th,
    .summary-table td {
      padding: 8px 9px;
      border: 1px solid #d8dee4;
    }
    .summary-table tbody th {
      background: #f8fafc;
      color: #17202a;
      text-transform: none;
      letter-spacing: 0;
      font-size: 10.5px;
      width: 18%;
    }
    .summary-table strong {
      color: #0b5b54;
      white-space: nowrap;
    }
    .summary-table .money-stack {
      display: grid;
      grid-template-columns: repeat(3, minmax(0, 1fr));
      gap: 6px;
    }
    .summary-table .money-stack span {
      display: grid;
      gap: 2px;
    }
    .summary-table .money-stack small {
      color: #52606d;
      font-size: 8.5px;
      text-transform: uppercase;
      letter-spacing: 0.04em;
    }
    .summary-table td:nth-child(2),
    .summary-table th:nth-child(2) { text-align: left; }
    td:nth-child(3),
    td:nth-child(4),
    td:nth-child(5),
    th:nth-child(3),
    th:nth-child(4),
    th:nth-child(5) { text-align: right; }
    .empty-row { text-align: center; color: #52606d; }
    body.summary-only { font-size: 12px; }
    @media print {
      body { print-color-adjust: exact; -webkit-print-color-adjust: exact; }
    }
  </style>
</head>
<body class="${summaryOnly ? "summary-only" : "full-report"}">
  <header>
    <div>
      <h1>A to Z Volleyball Center</h1>
      <p>${summaryOnly ? "Reservation summary" : "Reservation financial report"}</p>
    </div>
    <div class="meta">
      <p>${formatShortDate(report.filters.startDate)} to ${formatShortDate(report.filters.endDate)}</p>
      <p>${escapeHtml(reportSubjectLabel(report.filters.subjectId))}</p>
    </div>
  </header>
  <h2>Summary</h2>
  <table class="summary-table">
    <thead>
      <tr><th>Period</th><th>Money</th><th>Reservations</th><th>Hours</th></tr>
    </thead>
    <tbody>
      <tr>
        <th>Current/Past</th>
        <td>
          <div class="money-stack">
            <span><strong>${formatCurrency(report.currentPast.due)}</strong><small>Due</small></span>
            <span><strong>${formatCurrency(report.currentPast.paid)}</strong><small>Paid</small></span>
            <span><strong>${formatCurrency(report.currentPast.total)}</strong><small>Total</small></span>
          </div>
        </td>
        <td>${report.currentPast.reservations}</td>
        <td>${formatDuration(report.currentPast.minutes)}</td>
      </tr>
      <tr>
        <th>Future</th>
        <td><strong>${formatCurrency(report.future.amount)}</strong> <small>Amount</small></td>
        <td>${report.future.reservations}</td>
        <td>${formatDuration(report.future.minutes)}</td>
      </tr>
    </tbody>
  </table>
  ${summaryOnly ? "" : `
  <h2>Detail List</h2>
  <table>
    <thead><tr><th>Client</th><th>Date</th><th>Total Hours</th><th>Total Courts</th><th>Total Amount</th></tr></thead>
    <tbody>
      ${report.detailRows.map((row) => `<tr>
        <td>${escapeHtml(row.client)}</td>
        <td>${formatReportDate(row.date)}</td>
        <td>${formatDuration(row.minutes)}</td>
        <td>${row.courts}</td>
        <td>${formatCurrency(row.amount)}</td>
      </tr>`).join("") || `<tr><td class="empty-row" colspan="5">No reservations match this report.</td></tr>`}
    </tbody>
  </table>
  `}
</body>
</html>`;
}

function plainInvoiceText(invoice) {
  return `Invoice ${invoice.invoiceNumber}
${invoice.subjectName}
Amount due: ${formatCurrency(invoice.amount)}
Billing period: ${invoice.periodStart} to ${invoice.periodEnd}`;
}

function invoiceTemplateTokens(invoice) {
  return {
    teamname: invoice.subjectName,
    subjectname: invoice.subjectName,
    invoicenumber: invoice.invoiceNumber,
    amountdue: formatCurrency(invoice.amount),
    periodstart: invoice.periodStart,
    periodend: invoice.periodEnd,
    adminemail: state.settings.adminEmail
  };
}

function applyTemplateTokens(template, tokens) {
  return String(template ?? "").replace(/<([a-z0-9_]+)>/gi, (_, token) => tokens[token.toLowerCase()] ?? `<${token}>`);
}

function signupUrl() {
  return `${window.location.origin}${window.location.pathname}#signup`;
}

function subjectOptions(selectedId) {
  return activeClients().map((subject) => `
    <option value="${subject.id}" ${selectedId === subject.id ? "selected" : ""}>${escapeHtml(subject.displayName)} (${escapeHtml(clientDisplayType(subject))})</option>
  `).join("");
}

function bulkSubjectOptions(selectedId) {
  return sortedSubjectsForBulk().map((subject) => `
    <option value="${subject.id}" ${selectedId === subject.id ? "selected" : ""}>${escapeHtml(subject.displayName)} (${escapeHtml(clientDisplayType(subject))})</option>
  `).join("");
}

function invoiceSubjectOptions(selectedId) {
  const subjects = sortedSubjectsForBulk().map((subject) => ({
    id: subject.id,
    label: `${subject.displayName} (${subject.subjectType})`
  }));
  const users = adminUsers()
    .filter((user) => user.approvalStatus !== "rejected")
    .map((user) => ({
      id: user.id,
      label: `${user.name} (user)`
    }));
  return [...subjects, ...users]
    .sort((left, right) => left.label.localeCompare(right.label))
    .map((option) => `<option value="${option.id}" ${selectedId === option.id ? "selected" : ""}>${escapeHtml(option.label)}</option>`)
    .join("");
}

function teamSubjectOptions(selectedId) {
  return activeTeamSubjects().map((subject) => `
    <option value="${subject.id}" ${selectedId === subject.id ? "selected" : ""}>${escapeHtml(subject.displayName)} (${subjectTeamsForSubject(subject.id).length} team${subjectTeamsForSubject(subject.id).length === 1 ? "" : "s"})</option>
  `).join("");
}

function clientTypeOptions(selectedId) {
  return activeClientTypes().map((clientType) => `
    <option value="${clientType.id}" ${selectedId === clientType.id ? "selected" : ""}>${escapeHtml(clientType.name)}</option>
  `).join("");
}

function subjectTeamOptions(subjectId, selectedId) {
  return subjectTeamsForSubject(subjectId).map((team) => `
    <option value="${team.id}" ${selectedId === team.id ? "selected" : ""}>${escapeHtml(team.shortName ?? team.name)}</option>
  `).join("");
}

function seasonOptions(selectedId) {
  return activeSeasons().map((season) => `
    <option value="${season.id}" ${selectedId === season.id ? "selected" : ""}>${escapeHtml(season.displayName)}</option>
  `).join("");
}

function seasonPriceLabel(price) {
  return price.seasonDisplayName ?? price.season ?? seasonById(price.seasonId)?.displayName ?? formatSeasonYear(price.seasonYear);
}

function validSeasonYear(startYear) {
  return Number.isInteger(Number(startYear)) && Number(startYear) >= 2020 && Number(startYear) <= 2100;
}

function bulkSeasonPriceOptions(subjectId) {
  return seasonPricesForSubject(subjectId);
}

function bulkNoCourtPreviewItems() {
  return (state.bulkPreview?.items ?? [])
    .filter((item) => item.status === "conflict" && isNoCourtConflict(item))
    .sort((left, right) => new Date(left.start).getTime() - new Date(right.start).getTime());
}

function bulkPreviewStatusByDate() {
  const statusByDate = new Map();
  for (const item of state.bulkPreview?.items ?? []) {
    const dateKey = isoDateKey(item.start);
    if (!dateKey) {
      continue;
    }
    statusByDate.set(dateKey, {
      status: isNoCourtConflict(item) ? "conflict" : "available",
      title: bulkCalendarTitle(item)
    });
  }
  return statusByDate;
}

function bulkPreviewMonths() {
  const months = new Set();
  for (const dateKey of datesBetweenKeys(state.bulkForm.startDate, state.bulkForm.endDate)) {
    months.add(dateKey.slice(0, 7));
  }
  return [...months];
}

function isNoCourtConflict(item) {
  return item.resourceType === "court" && /no court/i.test(item.conflictReason ?? "");
}

function bulkCalendarTitle(item) {
  if (isNoCourtConflict(item)) {
    return "No Court Available";
  }
  const courts = item.resourceType === "court"
    ? (item.courtIds?.length ? item.courtIds.map(labelCourt).join(", ") : labelCourt(item.courtId))
    : "Trainer gym";
  return `${courts}, ${formatShortTime(item.start)}-${formatShortTime(item.end)}, ${formatDuration(reservationMinutes(item))}`;
}

function calendarBookingsForDate(dateKey) {
  return activeBookings()
    .filter((booking) => booking.resourceType === "court" && isoDateKey(booking.start) === dateKey)
    .sort((left, right) => new Date(left.start).getTime() - new Date(right.start).getTime());
}

function calendarTimeSlots(dateKey) {
  const hours = hoursForDate(dateKey);
  if (!hours || hours.closed) {
    return [];
  }
  const slots = [];
  for (let minute = timeToMinutes(hours.open); minute < timeToMinutes(hours.close); minute += state.settings.slotIntervalMinutes) {
    slots.push(minutesToTime(minute));
  }
  return slots;
}

function calendarHourSlots(dateKey) {
  const hours = hoursForDate(dateKey);
  if (!hours || hours.closed) {
    return [];
  }
  const slots = [];
  const startMinute = Math.floor(timeToMinutes(hours.open) / 60) * 60;
  const endMinute = timeToMinutes(hours.close);
  for (let minute = startMinute; minute < endMinute; minute += 60) {
    slots.push(minutesToTime(minute));
  }
  return slots;
}

function calendarGridStartMinute(dateKey) {
  const hours = hoursForDate(dateKey);
  return Math.floor(timeToMinutes(hours?.open ?? "00:00") / 60) * 60;
}

function calendarGridEndMinute(dateKey) {
  const hours = hoursForDate(dateKey);
  return timeToMinutes(hours?.close ?? "00:00");
}

function calendarHalfHourSlotCount(dateKey) {
  return Math.max(1, Math.ceil((calendarGridEndMinute(dateKey) - calendarGridStartMinute(dateKey)) / 30));
}

function calendarHalfHourRowStart(dateKey, time) {
  const offset = timeToMinutes(time) - calendarGridStartMinute(dateKey);
  return Math.max(0, Math.floor(offset / 30)) + 2;
}

function calendarHourGridRowStyle(dateKey, time) {
  return `grid-row: ${calendarHalfHourRowStart(dateKey, time)} / span 2;`;
}

function calendarBookingGridRowStyle(dateKey, booking) {
  const startMinute = timeToMinutes(easternTimeKey(booking.start));
  const endMinute = timeToMinutes(easternTimeKey(booking.end));
  const gridStart = calendarGridStartMinute(dateKey);
  const gridEnd = calendarGridEndMinute(dateKey);
  const rowStart = Math.max(0, Math.floor((Math.max(startMinute, gridStart) - gridStart) / 30)) + 2;
  const span = Math.max(1, Math.ceil((Math.min(endMinute, gridEnd) - Math.max(startMinute, gridStart)) / 30));
  return `grid-row: ${rowStart} / span ${span};`;
}

function bookingForCourtSlot(dateKey, time, courtId) {
  const slotStart = new Date(toIso(dateKey, time));
  const slotEnd = new Date(toIso(dateKey, addMinutes(time, state.settings.slotIntervalMinutes)));
  return calendarBookingsForDate(dateKey).find((booking) => {
    if (booking.courtId !== courtId) {
      return false;
    }
    const bookingStart = new Date(booking.start);
    const bookingEnd = new Date(booking.end);
    return bookingStart < slotEnd && bookingEnd > slotStart;
  });
}

function bookingById(bookingId) {
  return activeBookings().find((booking) => booking.id === bookingId);
}

function calendarBookingTitle(booking) {
  return `${bookingDisplayName(booking)}, ${formatShortTime(booking.start)}-${formatShortTime(booking.end)}, ${paymentAmountLabel(bookingAmount(booking))}`;
}

function weekStartDateKey(dateKey) {
  const day = dayOfWeekFromDate(dateKey);
  return addDateDays(dateKey, -day);
}

function isFutureSlot(dateKey, time) {
  return new Date(toIso(dateKey, time)).getTime() >= Date.now();
}

function isBookingEditable(booking) {
  return !isBookingPaid(booking) && new Date(booking.end).getTime() >= Date.now();
}

function singleReservationConflictMessage(ignoreBookingId = "") {
  if (state.resourceType !== "court") {
    return "";
  }
  const start = new Date(toIso(state.date, state.time));
  const end = new Date(toIso(state.date, addMinutes(state.time, state.durationMinutes)));
  const conflict = activeBookings().find((booking) => {
    if (booking.id === ignoreBookingId || booking.resourceType !== "court" || booking.courtId !== state.selectedCourt) {
      return false;
    }
    const bookingStart = new Date(booking.start);
    const bookingEnd = new Date(booking.end);
    return bookingStart < end && start < bookingEnd;
  });
  if (conflict) {
    return `Conflict with ${bookingCalendarLabel(conflict)} on ${labelCourt(conflict.courtId)} from ${formatShortTime(conflict.start)} to ${formatShortTime(conflict.end)}.`;
  }
  const hours = hoursForDate(state.date);
  if (!hours || hours.closed || timeToMinutes(state.time) < timeToMinutes(hours.open) || timeToMinutes(addMinutes(state.time, state.durationMinutes)) > timeToMinutes(hours.close)) {
    return "Reservation is outside business hours.";
  }
  return "";
}

function bookingSeasonPriceOptions(subjectId) {
  return seasonPricesForSubject(subjectId);
}

function ensureSelectedSubject() {
  state.adminSubjectForm.clientTypeId = resolveClientTypeId(state.adminSubjectForm.clientTypeId);
  state.editSubjectForm.clientTypeId = resolveClientTypeId(state.editSubjectForm.clientTypeId);

  const [firstSubject] = activeClients();
  if (!firstSubject) {
    state.bulkForm.subjectId = "";
    state.bulkForm.subjectTeamId = "";
    state.bulkDeleteForm.subjectId = "";
    return;
  }

  if (!subjectById(state.bulkForm.subjectId)) {
    state.bulkForm.subjectId = firstSubject.id;
  }
  if (!subjectById(state.bulkDeleteForm.subjectId)) {
    state.bulkDeleteForm.subjectId = firstSubject.id;
  }
  if (!subjectById(state.bookingSubjectId)) {
    state.bookingSubjectId = "";
  }
  if (!clientTypeById(state.adminSubjectForm.clientTypeId)) {
    state.adminSubjectForm.clientTypeId = activeClientTypes()[0]?.id ?? "";
  }
  if (!clientTypeById(state.editSubjectForm.clientTypeId)) {
    state.editSubjectForm.clientTypeId = activeClientTypes()[0]?.id ?? "";
  }
  const bulkTeams = subjectTeamsForSubject(state.bulkForm.subjectId);
  if (clientTypeHasTeams(subjectById(state.bulkForm.subjectId)) && !bulkTeams.find((team) => team.id === state.bulkForm.subjectTeamId)) {
    state.bulkForm.subjectTeamId = bulkTeams[0]?.id ?? "";
  }
  const bookingTeams = subjectTeamsForSubject(state.bookingSubjectId);
  if (clientTypeHasTeams(subjectById(state.bookingSubjectId)) && !bookingTeams.find((team) => team.id === state.bookingSubjectTeamId)) {
    state.bookingSubjectTeamId = bookingTeams[0]?.id ?? "";
  }
  if (!activeTeamSubjects().find((subject) => subject.id === state.seasonPriceForm.subjectId)) {
    state.seasonPriceForm.subjectId = activeTeamSubjects()[0]?.id ?? "";
  }
  if (!seasonById(state.seasonPriceForm.seasonId)) {
    state.seasonPriceForm.seasonId = latestSeason()?.id ?? "";
  }
  if (!seasonById(state.editSeasonPriceForm.seasonId)) {
    state.editSeasonPriceForm.seasonId = latestSeason()?.id ?? "";
  }
  state.bulkForm.seasonPriceId = selectedBulkSeasonPrice()?.id ?? "";
  if (!state.bulkForm.hourlyRate) {
    state.bulkForm.hourlyRate = Number(state.settings.pricing.courtHourlyRate ?? 75);
  }
  state.bookingSeasonPriceId = selectedBookingSeasonPrice()?.id ?? "";
}

function normalizeLiveSettings(settings) {
  const fallback = structuredClone(defaultSettings);
  if (!settings) {
    return fallback;
  }

  return {
    courtCount: Number(settings.courtCount ?? fallback.courtCount),
    trainerCapacity: Number(settings.trainerCapacity ?? fallback.trainerCapacity),
    slotIntervalMinutes: Number(settings.slotIntervalMinutes ?? fallback.slotIntervalMinutes),
    minBookingMinutes: Number(settings.minBookingMinutes ?? fallback.minBookingMinutes),
    messageDisplaySeconds: Number(settings.messageDisplaySeconds ?? settings.message_display_seconds ?? fallback.messageDisplaySeconds),
    adminEmail: settings.adminEmail ?? settings.admin_email ?? fallback.adminEmail,
    emailTemplates: normalizeEmailTemplates(settings.emailTemplates ?? settings.email_templates, fallback.emailTemplates),
    pricing: {
      courtHourlyRate: Number(settings.pricing?.courtHourlyRate ?? fallback.pricing.courtHourlyRate),
      gymHourlyRate: Number(settings.pricing?.gymHourlyRate ?? fallback.pricing.gymHourlyRate)
    },
    operatingHours: normalizeOperatingHours(settings.operatingHours, fallback.operatingHours),
    closures: (settings.closures ?? []).map(normalizeClosure),
    fixedReservations: settings.fixedReservations ?? []
  };
}

function normalizeEmailTemplates(templates, fallback) {
  return {
    reservationReminder: {
      subject: templates?.reservationReminder?.subject ?? templates?.reservation_reminder?.subject ?? fallback.reservationReminder.subject,
      body: templates?.reservationReminder?.body ?? templates?.reservation_reminder?.body ?? fallback.reservationReminder.body
    },
    invoice: {
      subject: templates?.invoice?.subject ?? fallback.invoice.subject,
      body: templates?.invoice?.body ?? fallback.invoice.body
    }
  };
}

function normalizeOperatingHours(hours, fallback) {
  const normalized = structuredClone(fallback);
  for (const [dayIndex, dayHours] of Object.entries(hours ?? {})) {
    normalized[dayIndex] = {
      open: dayHours.open ?? fallback[dayIndex]?.open ?? "10:00",
      close: dayHours.close ?? fallback[dayIndex]?.close ?? "21:00",
      closed: Boolean(dayHours.closed)
    };
  }
  return normalized;
}

function readableSupabaseError(error, fallback) {
  if (!error) {
    return fallback;
  }
  if (/team_season_prices_unique_active_idx|duplicate key value/i.test(error.message ?? "")) {
    return "A season price already exists for this client and season. Edit the existing price instead of creating a duplicate.";
  }
  return error.message ? `${fallback} ${error.message}` : fallback;
}


// ---------------------------------------------------------------------------
// Member portal (live Supabase data for approved non-admin accounts)
// ---------------------------------------------------------------------------

async function loadPublicFacilityInfo() {
  if (!supabase) {
    return;
  }
  try {
    const { data } = await supabase.rpc("public_get_facility_info");
    if (data) {
      state.settings.courtCount = data.courtCount ?? state.settings.courtCount;
      state.settings.trainerCapacity = data.trainerCapacity ?? state.settings.trainerCapacity;
      state.settings.minBookingMinutes = data.minReservationMinutes ?? state.settings.minBookingMinutes;
      state.settings.slotIntervalMinutes = data.reservationStepMinutes ?? state.settings.slotIntervalMinutes;
      state.settings.pricing.courtHourlyRate = Number(data.courtHourlyRate ?? state.settings.pricing.courtHourlyRate);
      state.settings.pricing.gymHourlyRate = Number(data.gymHourlyRate ?? state.settings.pricing.gymHourlyRate);
      if (data.operatingHours && Object.keys(data.operatingHours).length) {
        state.settings.operatingHours = Object.fromEntries(Object.entries(data.operatingHours).map(([day, hours]) => [
          day, { open: hours.open, close: hours.close, closed: Boolean(hours.closed) }
        ]));
      }
    }
  } catch {
    // Public info is cosmetic; never block first paint on it.
  }
}

async function loadMemberPortal() {
  if (!shouldUseLiveAuth() || !supabase || !isApprovedMember()) {
    return;
  }
  const startDate = state.date && state.date >= todayDateKey() ? state.date : todayDateKey();
  const { data, error } = await supabase.rpc("member_get_portal", { p_start_date: startDate, p_days: 14 });
  if (error) {
    state.notice = readableSupabaseError(error, "Could not load the schedule.");
    render();
    return;
  }
  applyMemberPortal(data, startDate);
  render();
}

function applyMemberPortal(data, startDate) {
  const settings = data?.settings ?? {};
  state.settings.courtCount = settings.courtCount ?? state.settings.courtCount;
  state.settings.trainerCapacity = settings.trainerCapacity ?? state.settings.trainerCapacity;
  state.settings.minBookingMinutes = settings.minReservationMinutes ?? state.settings.minBookingMinutes;
  state.settings.slotIntervalMinutes = settings.reservationStepMinutes ?? state.settings.slotIntervalMinutes;
  state.settings.pricing.courtHourlyRate = Number(settings.courtHourlyRate ?? state.settings.pricing.courtHourlyRate);
  state.settings.pricing.gymHourlyRate = Number(settings.gymHourlyRate ?? state.settings.pricing.gymHourlyRate);

  if (data?.operatingHours && Object.keys(data.operatingHours).length) {
    state.settings.operatingHours = Object.fromEntries(Object.entries(data.operatingHours).map(([day, hours]) => [
      day, { open: hours.open, close: hours.close, closed: Boolean(hours.closed) }
    ]));
  }
  state.settings.closures = (data?.closures ?? []).map((closure, index) => ({
    id: `closure-${index}`,
    resourceType: closure.resourceType,
    courtId: closure.courtNumber ? `court-${closure.courtNumber}` : undefined,
    start: closure.start,
    end: closure.end,
    reason: closure.reason
  }));
  state.settings.fixedReservations = (data?.fixedReservations ?? []).map((fixed, index) => ({
    id: `fixed-${index}`,
    resourceType: fixed.resourceType,
    courtId: fixed.courtNumber ? `court-${fixed.courtNumber}` : undefined,
    daysOfWeek: fixed.daysOfWeek ?? [],
    startDate: fixed.startDate,
    endDate: fixed.endDate,
    startTime: fixed.startTime,
    endTime: fixed.endTime
  }));
  state.bookings = (data?.busy ?? []).map((block) => ({
    id: block.id,
    userId: block.mine ? state.user?.id : "other-member",
    teamId: block.label ?? null,
    resourceType: block.resourceType,
    courtId: block.courtNumber ? `court-${block.courtNumber}` : null,
    start: block.start,
    end: block.end,
    status: "confirmed",
    paymentStatus: "due",
    deleted: false
  }));

  state.memberContexts = [];
  (data?.contexts ?? []).forEach((context) => {
    if (context.isCoach) {
      state.memberContexts.push({
        key: `private:${context.subjectId}`,
        type: "private",
        subjectId: context.subjectId,
        teamId: null,
        label: `Private lesson (${context.displayName})`
      });
      return;
    }
    if (context.haveTeams) {
      (context.teams ?? []).forEach((team) => {
        state.memberContexts.push({
          key: `club:${context.subjectId}:${team.id}`,
          type: "club",
          subjectId: context.subjectId,
          teamId: team.id,
          label: `${context.displayName} — ${team.name}`
        });
      });
      return;
    }
    state.memberContexts.push({
      key: `club:${context.subjectId}:`,
      type: "club",
      subjectId: context.subjectId,
      teamId: null,
      label: context.displayName
    });
  });
  if (!state.memberContexts.find((context) => context.key === state.bookingContextKey)) {
    state.bookingContextKey = state.memberContexts[0]?.key ?? "";
  }
  state.myReservations = data?.myReservations ?? [];
  state.bracketPrices = data?.bracketPrices ?? [];
  state.memberPortalLoadedFrom = startDate;
  if (!state.date || state.date < startDate) {
    state.date = startDate;
  }
}

function memberContextByKey(key) {
  return state.memberContexts.find((context) => context.key === key) ?? null;
}

function renderMemberBookingContextFields() {
  if (!state.memberContexts.length) {
    return `<p class="small-copy">Your account is approved but not linked to a club or coach profile yet. Contact the front desk so reservations can be assigned correctly.</p>`;
  }
  const context = memberContextByKey(state.bookingContextKey);
  return `
    <label>
      Reserve for
      <select data-control="bookingContextKey">
        ${state.memberContexts.map((option) => `<option value="${option.key}" ${option.key === state.bookingContextKey ? "selected" : ""}>${escapeHtml(option.label)}</option>`).join("")}
      </select>
    </label>
    ${context?.type === "private" ? `
      <label>
        Players attending
        <select data-control="lessonBracket">
          ${["1-2", "3", "4", "5+"].map((bracket) => `<option value="${bracket}" ${state.lessonBracket === bracket ? "selected" : ""}>${bracket} players</option>`).join("")}
        </select>
      </label>
      ${renderPrivateBillingStatus(context)}
    ` : ""}
  `;
}

function privateBookingBlocked() {
  const context = memberContextByKey(state.bookingContextKey);
  return Boolean(context && context.type === "private" && context.billingTerms !== "monthly" && !context.cardOnFile);
}

function renderPrivateBillingStatus(context) {
  let billingLine;
  if (context.billingTerms === "monthly") {
    billingLine = `<p class="small-copy billing-ok">Monthly billing account — sessions and any fees are invoiced at the end of each month.</p>`;
  } else if (context.cardOnFile) {
    billingLine = `<p class="small-copy billing-ok">Card on file${context.cardLast4 ? ` ending in ${escapeHtml(context.cardLast4)}` : ""}. Sessions are invoiced after play; cancellation fees are charged to this card.</p>`;
  } else {
    billingLine = `<p class="small-copy billing-warning">A credit card on file is required for private lessons. Please contact the front desk to add one.</p>`;
  }
  return `
    ${billingLine}
    <p class="small-copy policy-line">Cancellation policy: free more than 36 hours before start · 50% between 36 and 24 hours · 100% within 24 hours.</p>
  `;
}

function isEditableWindow(startIso) {
  return new Date(startIso).getTime() - Date.now() > 36 * 60 * 60 * 1000;
}

function beginEditReservation(reservationId) {
  const reservation = state.myReservations.find((entry) => entry.id === reservationId);
  if (!reservation || !reservation.lessonPlayerBracket || !isEditableWindow(reservation.start)) {
    return;
  }
  const start = new Date(reservation.start);
  const pad = (value) => String(value).padStart(2, "0");
  state.date = `${start.getFullYear()}-${pad(start.getMonth() + 1)}-${pad(start.getDate())}`;
  state.time = `${pad(start.getHours())}:${pad(start.getMinutes())}`;
  state.durationMinutes = Math.round((new Date(reservation.end) - start) / 60000);
  state.resourceType = reservation.resourceType;
  state.selectedCourt = reservation.courtNumber ? `court-${reservation.courtNumber}` : "";
  state.lessonBracket = reservation.lessonPlayerBracket;
  const privateContext = state.memberContexts.find((context) => context.type === "private");
  if (privateContext) {
    state.bookingContextKey = privateContext.key;
  }
  state.editingReservationId = reservationId;
  setView("book");
}

function cancellationFeePercentFor(startIso) {
  const hoursOut = (new Date(startIso).getTime() - Date.now()) / 3600000;
  if (hoursOut > 36) return 0;
  if (hoursOut > 24) return 50;
  return 100;
}

async function cancelMyReservation(reservationId) {
  if (!shouldUseLiveAuth() || !supabase || !reservationId) {
    return;
  }
  const reservation = state.myReservations.find((entry) => entry.id === reservationId);
  if (reservation) {
    const feePercent = cancellationFeePercentFor(reservation.start);
    const feeAmount = ((Number(reservation.amount) || 0) * feePercent / 100).toFixed(2);
    const message = feePercent === 0
      ? "Cancel this lesson? You are more than 36 hours out, so there is no cancellation fee."
      : `Cancel this lesson? A ${feePercent}% cancellation fee ($${feeAmount}) applies and will be charged to the card on file (or added to your monthly invoice).`;
    if (!window.confirm(message)) {
      return;
    }
  }
  const { data, error } = await supabase.rpc("member_cancel_reservation", { p_reservation_id: reservationId });
  if (error) {
    state.notice = readableSupabaseError(error, "Could not cancel the reservation.");
    render();
    return;
  }
  const feePercent = Number(data?.cancellationFeePercent ?? 0);
  state.notice = feePercent > 0
    ? `Reservation cancelled. A ${feePercent}% fee ($${Number(data.cancellationFeeAmount).toFixed(2)}) ${data.cancellationFeeStatus === "invoiced" ? "will appear on your monthly invoice" : "will be charged to the card on file"}.`
    : "Reservation cancelled. No fee — more than 36 hours before start.";
  await loadMemberPortal();
}

// ---------------------------------------------------------------------------
// Facility map per Exhibit C — Court 1 vertical top-left; Weight Training &
// Stretching Room, lobby/office below it; courts 2-9 to the right in two
// columns of four (left column 2-5 top to bottom, right column 6-9).
// ---------------------------------------------------------------------------

function renderFacilityMap({ interactive = false } = {}) {
  const availability = interactive ? getCurrentAvailability() : null;
  const courtClass = (courtNumber) => {
    if (!availability) {
      return "";
    }
    const court = availability.courts.find((entry) => entry.courtId === `court-${courtNumber}`);
    return court?.available ? " open" : " busy";
  };
  const trainerOpenSlots = availability ? availability.trainer.availableSlots : null;

  const courtTile = (courtNumber, x, y, width, height) => `
    <g class="map-tile map-court${courtClass(courtNumber)}" ${interactive ? `data-court="court-${courtNumber}" role="button" tabindex="0" aria-label="Court ${courtNumber}"` : ""}>
      <rect x="${x}" y="${y}" width="${width}" height="${height}" rx="10"></rect>
      <line x1="${x + width / 2}" y1="${y + 8}" x2="${x + width / 2}" y2="${y + height - 8}" class="map-net"></line>
      <text x="${x + width / 2}" y="${y + height / 2}" class="map-label">Court ${courtNumber}</text>
      ${availability ? `<text x="${x + width / 2}" y="${y + height / 2 + 22}" class="map-status">${courtClass(courtNumber).includes("open") ? "Open" : "Reserved"}</text>` : ""}
    </g>
  `;
  const roomTile = (label, x, y, width, height, extra = "") => `
    <g class="map-tile map-room">
      <rect x="${x}" y="${y}" width="${width}" height="${height}" rx="10"></rect>
      <text x="${x + width / 2}" y="${y + height / 2}" class="map-label small">${label}</text>
      ${extra}
    </g>
  `;

  const leftColumn = [2, 3, 4, 5];
  const rightColumn = [6, 7, 8, 9];
  const courtWidth = 344;
  const courtHeight = 138;
  const columnGap = 24;
  const rowGap = 14;
  const rightStart = 224;

  return `
    <figure class="facility-map" aria-label="Facility map">
      <svg viewBox="0 0 960 640" xmlns="http://www.w3.org/2000/svg" role="img">
        <g class="map-tile map-court vertical${courtClass(1)}" ${interactive ? `data-court="court-1" role="button" tabindex="0" aria-label="Court 1"` : ""}>
          <rect x="16" y="16" width="188" height="300" rx="10"></rect>
          <line x1="24" y1="166" x2="196" y2="166" class="map-net"></line>
          <text x="110" y="155" class="map-label">Court 1</text>
          ${availability ? `<text x="110" y="181" class="map-status">${courtClass(1).includes("open") ? "Open" : "Reserved"}</text>` : ""}
        </g>
        ${roomTile(`Weight Training & Stretching${trainerOpenSlots !== null ? ` · ${trainerOpenSlots} open` : ""}`, 16, 330, 188, 100)}
        ${roomTile("Lobby · Coffee bar", 16, 442, 188, 56)}
        ${roomTile("Office", 16, 510, 188, 38)}
        ${roomTile("Meeting room", 16, 560, 188, 38)}
        ${leftColumn.map((courtNumber, index) => courtTile(courtNumber, rightStart, 16 + index * (courtHeight + rowGap), courtWidth, courtHeight)).join("")}
        ${rightColumn.map((courtNumber, index) => courtTile(courtNumber, rightStart + courtWidth + columnGap, 16 + index * (courtHeight + rowGap), courtWidth, courtHeight)).join("")}
      </svg>
      <figcaption class="small-copy">Court 1, eight match courts in two columns, the Weight Training &amp; Stretching Room, lobby and coffee bar. Layout follows the facility plan.</figcaption>
    </figure>
  `;
}


async function signInWithProvider(provider) {
  if (!shouldUseLiveAuth() || !supabase || !["google", "facebook", "apple"].includes(provider)) {
    return;
  }
  const { error } = await supabase.auth.signInWithOAuth({
    provider,
    options: { redirectTo: window.location.origin }
  });
  if (error) {
    const providerName = provider.charAt(0).toUpperCase() + provider.slice(1);
    state.notice = /not enabled|unsupported/i.test(error.message ?? "")
      ? `${providerName} sign-in is not enabled yet. Please use email and password.`
      : readableSupabaseError(error, `Could not start ${providerName} sign-in.`);
    render();
  }
  // On success the browser redirects to the provider; nothing further to do here.
}

async function sendPasswordReset() {
  if (!shouldUseLiveAuth() || !supabase) {
    return;
  }
  const email = state.loginId.trim() || document.querySelector('input[name="loginId"]')?.value?.trim() || "";
  if (!email.includes("@")) {
    state.notice = "Enter your account email above, then press Forgot password again.";
    render();
    return;
  }
  state.loginId = email;
  const { error } = await supabase.auth.resetPasswordForEmail(email, {
    redirectTo: window.location.origin
  });
  state.notice = error
    ? readableSupabaseError(error, "Could not send the reset email.")
    : "If that email has an account, a password reset link is on its way.";
  render();
}

function renderResetPasswordView() {
  return `
    <section class="workspace narrow-workspace">
      <div class="workspace-head">
        <div>
          <p class="eyebrow">Account</p>
          <h2>Choose a new password</h2>
        </div>
      </div>
      <form class="panel form-panel" aria-label="Reset password">
        <label>
          New password
          <input data-control="resetPasswordValue" name="newPassword" type="password" autocomplete="new-password" minlength="8" value="${escapeHtml(state.resetPasswordValue)}">
        </label>
        <button type="button" class="primary-action full" data-action="confirm-password-reset">Save new password</button>
        <p class="small-copy">At least 8 characters. You will stay signed in after saving.</p>
      </form>
    </section>
  `;
}

async function confirmPasswordReset() {
  if (!shouldUseLiveAuth() || !supabase) {
    return;
  }
  const password = state.resetPasswordValue ?? "";
  if (password.length < 8) {
    state.notice = "Passwords need at least 8 characters.";
    render();
    return;
  }
  const { error } = await supabase.auth.updateUser({ password });
  state.resetPasswordValue = "";
  if (error) {
    state.notice = readableSupabaseError(error, "Could not update the password.");
    render();
    return;
  }
  state.notice = "Password updated.";
  setView("home");
}

// ---------------------------------------------------------------------------
// Day grid: half-hour slots x (9 courts + trainer gym) for the selected date.
// ---------------------------------------------------------------------------

function dayGridSlots() {
  const dayIndex = new Date(`${state.date}T12:00:00`).getDay();
  const hours = state.settings.operatingHours[dayIndex];
  if (!hours || hours.closed) {
    return [];
  }
  const slots = [];
  let cursor = hours.open;
  while (cursor < hours.close) {
    slots.push(cursor);
    cursor = addMinutes(cursor, 30);
  }
  return slots;
}

function renderDayGrid() {
  const slots = dayGridSlots();
  if (!slots.length) {
    return `<p class="small-copy">The facility is closed on this date.</p>`;
  }
  const scheduler = buildScheduler();
  const courts = Array.from({ length: state.settings.courtCount }, (_, index) => `court-${index + 1}`);
  const myBookings = activeBookings().filter((booking) => booking.userId === state.user?.id);
  const isMine = (courtId, start, end) => myBookings.some((booking) =>
    (courtId === "trainer" ? booking.resourceType === "trainer" : booking.courtId === courtId)
    && new Date(booking.start) < end && start < new Date(booking.end));

  const rows = slots.map((slot) => {
    const start = toIso(state.date, slot);
    const end = toIso(state.date, addMinutes(slot, 30));
    let availability;
    try {
      availability = scheduler.getAvailability({ start, end, viewer: state.user });
    } catch {
      availability = null;
    }
    const startDate = new Date(start);
    const endDate = new Date(end);
    const courtCells = courts.map((courtId) => {
      const open = availability?.courts.find((court) => court.courtId === courtId)?.available ?? false;
      const mine = isMine(courtId, startDate, endDate);
      const cls = mine ? "mine" : open ? "open" : "busy";
      return `<td><button type="button" class="grid-cell ${cls}" ${open ? `data-grid-time="${slot}" data-grid-court="${courtId}"` : "disabled"} aria-label="${labelCourt(courtId)} at ${formatTime(slot)}: ${mine ? "yours" : open ? "open" : "reserved"}"></button></td>`;
    }).join("");
    const trainerOpen = (availability?.trainer.availableSlots ?? 0) > 0;
    const trainerMine = isMine("trainer", startDate, endDate);
    const trainerCls = trainerMine ? "mine" : trainerOpen ? "open" : "busy";
    return `<tr><th scope="row">${formatTime(slot)}</th>${courtCells}<td><button type="button" class="grid-cell ${trainerCls}" ${trainerOpen ? `data-grid-time="${slot}" data-grid-court="trainer"` : "disabled"} aria-label="Trainer gym at ${formatTime(slot)}: ${availability?.trainer.availableSlots ?? 0} open"></button></td></tr>`;
  }).join("");

  return `
    <div class="day-grid-wrap">
      <table class="day-grid" aria-label="Availability for ${formatDateLabel(state.date)}">
        <thead>
          <tr>
            <th scope="col">Time</th>
            ${courts.map((courtId) => `<th scope="col">${labelCourt(courtId).replace("Court ", "C")}</th>`).join("")}
            <th scope="col">Gym</th>
          </tr>
        </thead>
        <tbody>${rows}</tbody>
      </table>
      <p class="small-copy grid-legend"><span class="grid-cell open"></span> open · <span class="grid-cell busy"></span> reserved · <span class="grid-cell mine"></span> yours — tap an open slot to book it.</p>
    </div>
  `;
}

function currentView() {
  const view = window.location.hash.replace("#", "");
  return ["home", "login", "signup", "programs", "schedule", "book", "my-bookings", "admin", "reset-password"].includes(view) ? view : "home";
}

function setView(view) {
  state.view = view;
  ensureAllowedView();
  if (window.location.hash === `#${state.view}`) {
    render();
  } else {
    window.location.hash = state.view;
  }
}

function ensureAllowedView() {
  if (["schedule", "book", "my-bookings"].includes(state.view) && !isApprovedMember()) {
    state.view = state.user ? "home" : "login";
  }
  if (state.view === "admin" && !isAdminSession()) {
    state.view = state.user ? "home" : "login";
  }
  if (state.view === "reset-password" && !shouldUseLiveAuth()) {
    state.view = "home";
  }
}

function canViewScheduling() {
  return isApprovedMember();
}

function isApprovedMember() {
  return Boolean(state.user?.authenticated && state.user.approved && state.user.role === "user");
}

function isAdminSession() {
  return Boolean(state.user?.authenticated && state.user.approved && state.user.role === "admin");
}

function shouldUseLiveAuth() {
  return Boolean(supabase && (supabaseConfig.authMode === "supabase" || !isLocalPreview));
}

function isUuid(value) {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(String(value ?? ""));
}

function timeOptions() {
  const hours = hoursForDate(state.date);
  if (!hours || hours.closed) {
    return [];
  }
  const open = timeToMinutes(hours.open);
  const close = timeToMinutes(hours.close);
  const lastStart = close - state.settings.minBookingMinutes;
  const times = [];
  for (let minute = open; minute <= lastStart; minute += state.settings.slotIntervalMinutes) {
    times.push(minutesToTime(minute));
  }
  if (!times.includes(state.time)) {
    state.time = times[0] ?? "10:00";
  }
  return times;
}

function durationOptions(maxHours = 4, respectHours = true) {
  const hours = hoursForDate(state.date);
  if (!hours || hours.closed) {
    return [state.settings.minBookingMinutes];
  }
  const start = timeToMinutes(state.time);
  const close = timeToMinutes(hours.close);
  const maxMinutes = maxHours * 60;
  const options = [];
  for (let minutes = state.settings.minBookingMinutes; minutes <= maxMinutes && (!respectHours || start + minutes <= close); minutes += state.settings.slotIntervalMinutes) {
    options.push(minutes);
  }
  if (!options.includes(state.durationMinutes)) {
    state.durationMinutes = options[0] ?? state.settings.minBookingMinutes;
  }
  return options;
}

function hoursForDate(date) {
  return state.settings.operatingHours[dayOfWeekFromDate(date)];
}

function assertBulkDatesAllowed() {
  if (!state.bulkForm.startDate || !state.bulkForm.endDate) {
    throw new Error("Start and end dates are required.");
  }
  const today = todayDateKey();
  if (state.bulkForm.startDate < today || state.bulkForm.endDate < today) {
    throw new Error("Bulk reservations cannot use past dates.");
  }
  if (state.bulkForm.startDate > state.bulkForm.endDate) {
    throw new Error("Start date must be before end date.");
  }
  if (!state.bulkForm.daysOfWeek.length) {
    throw new Error("Select at least one day.");
  }
}

function toIso(date, time) {
  return `${date}T${time}:00${easternOffsetFor(date, time)}`;
}

function todayDateKey() {
  return easternDateKey(new Date());
}

function addDateDays(dateKey, daysToAdd) {
  const date = new Date(`${dateKey}T12:00:00Z`);
  date.setUTCDate(date.getUTCDate() + Number(daysToAdd));
  return date.toISOString().slice(0, 10);
}

function addMonths(monthKey, monthsToAdd) {
  const [year, month] = monthKey.split("-").map(Number);
  const date = new Date(Date.UTC(year, month - 1 + Number(monthsToAdd), 1, 12));
  return `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
}

function datesBetweenKeys(startDate, endDate) {
  if (!startDate || !endDate || startDate > endDate) {
    return [];
  }
  const dates = [];
  let cursor = startDate;
  while (cursor <= endDate) {
    dates.push(cursor);
    cursor = addDateDays(cursor, 1);
  }
  return dates;
}

function previousMonthRange(dateKey) {
  const [year, month] = dateKey.split("-").map(Number);
  const start = new Date(Date.UTC(year, month - 2, 1, 12));
  const end = new Date(Date.UTC(year, month - 1, 0, 12));
  return {
    start: start.toISOString().slice(0, 10),
    end: end.toISOString().slice(0, 10)
  };
}

function isoDateKey(value) {
  if (/^\d{4}-\d{2}-\d{2}$/.test(String(value))) {
    return String(value);
  }
  return easternDateKey(new Date(value));
}

function easternDateKey(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: FACILITY_TIMEZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit"
  }).formatToParts(date);
  const lookup = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${lookup.year}-${lookup.month}-${lookup.day}`;
}

function easternTimeKey(value) {
  const date = value instanceof Date ? value : new Date(value);
  if (Number.isNaN(date.getTime())) {
    return "";
  }
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: FACILITY_TIMEZONE,
    hour12: false,
    hour: "2-digit",
    minute: "2-digit"
  }).formatToParts(date);
  const lookup = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${lookup.hour}:${lookup.minute}`;
}

function easternOffsetFor(date, time) {
  const [year, month, day] = date.split("-").map(Number);
  const [hour, minute] = time.split(":").map(Number);
  const probe = new Date(Date.UTC(year, month - 1, day, hour, minute));
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: FACILITY_TIMEZONE,
    timeZoneName: "shortOffset"
  }).formatToParts(probe);
  const zoneName = parts.find((part) => part.type === "timeZoneName")?.value ?? "GMT-5";
  const match = /^GMT([+-]\d{1,2})(?::?(\d{2}))?$/.exec(zoneName);
  if (!match) {
    return "-05:00";
  }
  const rawHours = Number(match[1]);
  const minutes = Number(match[2] ?? 0);
  const sign = rawHours >= 0 ? "+" : "-";
  return `${sign}${String(Math.abs(rawHours)).padStart(2, "0")}:${String(minutes).padStart(2, "0")}`;
}

function addMinutes(time, minutesToAdd) {
  const [rawHour, rawMinute] = time.split(":").map(Number);
  return minutesToTime(rawHour * 60 + rawMinute + Number(minutesToAdd));
}

function timeToMinutes(time) {
  const [hours, minutes] = time.split(":").map(Number);
  return hours * 60 + minutes;
}

function minutesToTime(minutes) {
  const normalized = ((minutes % 1440) + 1440) % 1440;
  const hour = Math.floor(normalized / 60);
  const minute = normalized % 60;
  return `${String(hour).padStart(2, "0")}:${String(minute).padStart(2, "0")}`;
}

function dayOfWeekFromDate(date) {
  const [year, month, day] = date.split("-").map(Number);
  return new Date(Date.UTC(year, month - 1, day, 12)).getUTCDay();
}

function formatTime(time) {
  const [hour, minute] = time.split(":").map(Number);
  const suffix = hour >= 12 ? "PM" : "AM";
  const hour12 = hour % 12 || 12;
  return `${hour12}:${String(minute).padStart(2, "0")} ${suffix}`;
}

function formatDuration(minutes) {
  const hours = minutes / 60;
  return Number.isInteger(hours) ? `${hours} hr${hours === 1 ? "" : "s"}` : `${hours.toFixed(1)} hrs`;
}

function formatCurrency(value) {
  return new Intl.NumberFormat("en-US", { style: "currency", currency: "USD", maximumFractionDigits: 0 }).format(value);
}

function formatSeasonYear(startYear) {
  const year = Number(startYear);
  if (!Number.isFinite(year)) {
    return "";
  }
  return `${year}/${String((year + 1) % 100).padStart(2, "0")}`;
}

function formatDateLabel(date) {
  return new Intl.DateTimeFormat("en-US", { weekday: "long", month: "short", day: "numeric" }).format(new Date(`${date}T12:00:00`));
}

function formatMonthLabel(monthKey) {
  return new Intl.DateTimeFormat("en-US", { month: "long", year: "numeric", timeZone: "UTC" }).format(new Date(`${monthKey}-01T12:00:00Z`));
}

function formatShortDate(value) {
  if (/^\d{4}-\d{2}-\d{2}$/.test(String(value))) {
    return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", timeZone: "UTC" }).format(new Date(`${value}T12:00:00Z`));
  }
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", timeZone: FACILITY_TIMEZONE }).format(new Date(value));
}

function formatReportDate(value) {
  if (/^\d{4}-\d{2}-\d{2}$/.test(String(value))) {
    return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" }).format(new Date(`${value}T12:00:00Z`));
  }
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: FACILITY_TIMEZONE }).format(new Date(value));
}

function formatShortTime(value) {
  return new Intl.DateTimeFormat("en-US", { hour: "numeric", minute: "2-digit", timeZone: FACILITY_TIMEZONE }).format(new Date(value));
}

function formatCompactTime(value) {
  const parts = new Intl.DateTimeFormat("en-US", {
    hour: "numeric",
    minute: "2-digit",
    timeZone: FACILITY_TIMEZONE
  }).formatToParts(new Date(value));
  const hour = parts.find((part) => part.type === "hour")?.value ?? "";
  const minute = parts.find((part) => part.type === "minute")?.value ?? "00";
  const dayPeriod = (parts.find((part) => part.type === "dayPeriod")?.value ?? "").toLowerCase();
  return `${hour}${minute === "00" ? "" : `:${minute}`} ${dayPeriod}`.trim();
}

function formatReservationWindow(booking) {
  return `${formatShortDate(booking.start)}: ${formatCompactTime(booking.start)} to ${formatCompactTime(booking.end)}`;
}

function labelCourt(courtId) {
  return courtId ? `Court ${courtId.split("-")[1]}` : "Auto assign";
}

function labelCourtNumber(courtId) {
  return courtId ? courtId.split("-")[1] : "";
}

function formatBlocker(blocker) {
  if (blocker.type === "fixed-reservation") {
    return "Team block";
  }
  if (blocker.type === "closure") {
    return blocker.reason ?? "Closure";
  }
  return "Booking";
}

function dayName(dayIndex) {
  return ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][dayIndex];
}

function nextBookingId() {
  const max = state.bookings.reduce((highest, booking) => {
    const match = /^booking-(\d+)$/.exec(booking.id);
    return match ? Math.max(highest, Number(match[1])) : highest;
  }, 300);
  return max + 1;
}

function nextBulkOperationId() {
  const max = state.bulkOperations.reduce((highest, operation) => {
    const match = /^bulk-(\d+)$/.exec(operation.id);
    return match ? Math.max(highest, Number(match[1])) : highest;
  }, 0);
  return max + 1;
}

function nextSubjectId() {
  const base = clientTypeById(state.adminSubjectForm.clientTypeId)?.name?.toLowerCase() ?? "client";
  const next = activeClients().filter((subject) => String(clientDisplayType(subject)).toLowerCase() === base).length + 1;
  return `subject-${base}-${next}`;
}

function storeBooking(booking) {
  const paymentStatus = bookingPaymentStatus(booking);
  const amount = booking.amount == null && booking.amountDue == null && booking.amount_due == null ? null : bookingAmount(booking);
  return {
    ...booking,
    start: booking.start instanceof Date ? booking.start.toISOString() : booking.start,
    end: booking.end instanceof Date ? booking.end.toISOString() : booking.end,
    subjectId: booking.subjectId ?? booking.subject_id,
    subjectTeamId: booking.subjectTeamId ?? booking.subject_team_id ?? null,
    teamName: booking.teamName ?? booking.team_name ?? null,
    teamShortName: booking.teamShortName ?? booking.team_short_name ?? null,
    reservationSource: booking.reservationSource ?? booking.reservation_source ?? "bulk",
    bulkOperationId: booking.bulkOperationId ?? booking.bulk_operation_id ?? null,
    hourlyRate: booking.hourlyRate == null ? null : Number(booking.hourlyRate),
    amount,
    reservationGroupId: booking.reservationGroupId ?? booking.reservation_group_id ?? null,
    deleted: Boolean(booking.deleted ?? booking.Deleted),
    Deleted: booking.deleted || booking.Deleted ? 1 : 0,
    paymentStatus
  };
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}
