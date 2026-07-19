const mockUsers = new Map([
  [
    "admin@company.com",
    {
      email: "admin@company.com",
      password: "AdminPass1",
      firstName: "Admin",
      lastName: "User",
      role: "admin",
      team: "Operations",
      approvalStatus: "approved",
    },
  ],
]);

const initialState = {
  mode: "login",
  session: null,
  isSubmitting: false,
  alert: {
    type: "default",
    message: "Use admin@company.com and AdminPass1 for the seeded account.",
  },
  errors: {},
  pendingApprovals: [],
  loginPasswordVisible: false,
  registerPasswordVisible: false,
};

let state = { ...initialState };

const elements = {
  loginTab: document.querySelector("#loginTab"),
  registerTab: document.querySelector("#registerTab"),
  loginForm: document.querySelector("#loginForm"),
  registerForm: document.querySelector("#registerForm"),
  formAlert: document.querySelector("#formAlert"),
  sessionState: document.querySelector("#sessionState"),
  loginSubmit: document.querySelector("#loginSubmit"),
  registerSubmit: document.querySelector("#registerSubmit"),
  approvalList: document.querySelector("#approvalList"),
  queueCount: document.querySelector("#queueCount"),
  loginPassword: document.querySelector("#loginPassword"),
  registerPassword: document.querySelector("#registerPassword"),
  toggleLoginPassword: document.querySelector("#toggleLoginPassword"),
  toggleRegisterPassword: document.querySelector("#toggleRegisterPassword"),
  passwordStrength: document.querySelector("#passwordStrength"),
};

function dispatch(action) {
  state = reducer(state, action);
  render();
}

function reducer(currentState, action) {
  switch (action.type) {
    case "SET_MODE":
      return {
        ...currentState,
        mode: action.mode,
        errors: {},
        alert:
          action.mode === "login"
            ? initialState.alert
            : { type: "default", message: "New accounts require admin approval before first sign-in." },
      };
    case "SUBMIT_START":
      return { ...currentState, isSubmitting: true, errors: {}, alert: { type: "default", message: "" } };
    case "SUBMIT_ERROR":
      return {
        ...currentState,
        isSubmitting: false,
        errors: action.errors || {},
        alert: { type: "error", message: action.message },
      };
    case "LOGIN_SUCCESS":
      return {
        ...currentState,
        isSubmitting: false,
        session: action.user,
        alert: { type: "success", message: `Signed in as ${action.user.firstName} ${action.user.lastName}.` },
      };
    case "REGISTER_PENDING":
      return {
        ...currentState,
        isSubmitting: false,
        mode: "login",
        pendingApprovals: [...currentState.pendingApprovals, action.request],
        alert: {
          type: "warning",
          message: "Access request submitted. An admin must approve the account before sign-in.",
        },
      };
    case "APPROVE_USER":
      mockUsers.set(action.request.email, { ...action.request, approvalStatus: "approved" });
      return {
        ...currentState,
        pendingApprovals: currentState.pendingApprovals.filter((request) => request.id !== action.request.id),
        alert: { type: "success", message: `${action.request.email} is approved for sign-in.` },
      };
    case "REJECT_USER":
      return {
        ...currentState,
        pendingApprovals: currentState.pendingApprovals.filter((request) => request.id !== action.request.id),
        alert: { type: "warning", message: `${action.request.email} was removed from the approval queue.` },
      };
    case "TOGGLE_PASSWORD":
      return { ...currentState, [action.key]: !currentState[action.key] };
    default:
      return currentState;
  }
}

const authApi = {
  async login(payload) {
    await simulateLatency();
    const pendingRequest = state.pendingApprovals.find((request) => request.email === payload.email.toLowerCase());

    if (pendingRequest) {
      throw new AuthError("This account is pending admin approval.");
    }

    const user = mockUsers.get(payload.email.toLowerCase());

    if (!user || user.password !== payload.password) {
      throw new AuthError("The email or password does not match an approved account.");
    }

    if (user.approvalStatus !== "approved") {
      throw new AuthError("This account is pending admin approval.");
    }

    return {
      email: user.email,
      firstName: user.firstName,
      lastName: user.lastName,
      role: user.role,
      team: user.team,
    };
  },

  async register(payload) {
    await simulateLatency();
    const hasPendingRequest = state.pendingApprovals.some((request) => request.email === payload.email.toLowerCase());

    if (mockUsers.has(payload.email.toLowerCase()) || hasPendingRequest) {
      throw new AuthError("An account request already exists for this email.");
    }

    return {
      ...payload,
      id: crypto.randomUUID(),
      approvalStatus: "pending",
      submittedAt: new Date().toISOString(),
    };
  },

  async approveRegistration(request) {
    await simulateLatency(180);
    return { ...request, approvalStatus: "approved" };
  },

  async rejectRegistration(request) {
    await simulateLatency(180);
    return { ...request, approvalStatus: "rejected" };
  },
};

class AuthError extends Error {}

function simulateLatency(duration = 420) {
  return new Promise((resolve) => window.setTimeout(resolve, duration));
}

function render() {
  const isLogin = state.mode === "login";
  elements.loginTab.classList.toggle("is-active", isLogin);
  elements.registerTab.classList.toggle("is-active", !isLogin);
  elements.loginTab.setAttribute("aria-selected", String(isLogin));
  elements.registerTab.setAttribute("aria-selected", String(!isLogin));
  elements.loginForm.classList.toggle("is-hidden", !isLogin);
  elements.registerForm.classList.toggle("is-hidden", isLogin);

  elements.loginSubmit.disabled = state.isSubmitting;
  elements.registerSubmit.disabled = state.isSubmitting;
  elements.loginSubmit.textContent = state.isSubmitting && isLogin ? "Signing in..." : "Sign in";
  elements.registerSubmit.textContent = state.isSubmitting && !isLogin ? "Submitting..." : "Request access";

  elements.loginPassword.type = state.loginPasswordVisible ? "text" : "password";
  elements.registerPassword.type = state.registerPasswordVisible ? "text" : "password";
  elements.toggleLoginPassword.textContent = state.loginPasswordVisible ? "Hide" : "Show";
  elements.toggleRegisterPassword.textContent = state.registerPasswordVisible ? "Hide" : "Show";
  elements.toggleLoginPassword.setAttribute("aria-label", state.loginPasswordVisible ? "Hide password" : "Show password");
  elements.toggleRegisterPassword.setAttribute("aria-label", state.registerPasswordVisible ? "Hide password" : "Show password");

  elements.sessionState.textContent = state.session ? `${state.session.role} signed in` : "Signed out";
  elements.sessionState.classList.toggle("is-signed-in", Boolean(state.session));

  renderErrors();
  renderAlert();
  renderApprovals();
}

function renderErrors() {
  const errorIds = [
    "loginEmail",
    "loginPassword",
    "firstName",
    "lastName",
    "registerEmail",
    "team",
    "registerPassword",
    "termsAccepted",
  ];

  for (const id of errorIds) {
    const errorElement = document.querySelector(`#${id}Error`);
    if (errorElement) {
      errorElement.textContent = state.errors[id] || "";
    }
  }
}

function renderAlert() {
  elements.formAlert.textContent = state.alert.message;
  elements.formAlert.className = "form-alert";

  if (state.alert.type !== "default") {
    elements.formAlert.classList.add(`is-${state.alert.type}`);
  }
}

function renderApprovals() {
  elements.queueCount.textContent = String(state.pendingApprovals.length);

  if (state.pendingApprovals.length === 0) {
    elements.approvalList.innerHTML = '<div class="empty-state">No accounts awaiting review.</div>';
    return;
  }

  elements.approvalList.replaceChildren(
    ...state.pendingApprovals.map((request) => {
      const card = document.createElement("article");
      card.className = "approval-card";

      const title = document.createElement("h3");
      title.textContent = `${request.firstName} ${request.lastName}`;

      const email = document.createElement("p");
      email.textContent = request.email;

      const meta = document.createElement("div");
      meta.className = "request-meta";
      meta.append(createMetaTag(request.role), createMetaTag(request.team));

      const actions = document.createElement("div");
      actions.className = "approval-actions";

      const approveButton = document.createElement("button");
      approveButton.className = "secondary-button";
      approveButton.type = "button";
      approveButton.textContent = "Approve";
      approveButton.addEventListener("click", async () => {
        const approved = await authApi.approveRegistration(request);
        dispatch({ type: "APPROVE_USER", request: approved });
      });

      const rejectButton = document.createElement("button");
      rejectButton.className = "danger-button";
      rejectButton.type = "button";
      rejectButton.textContent = "Reject";
      rejectButton.addEventListener("click", async () => {
        const rejected = await authApi.rejectRegistration(request);
        dispatch({ type: "REJECT_USER", request: rejected });
      });

      actions.append(approveButton, rejectButton);
      card.append(title, email, meta, actions);
      return card;
    }),
  );
}

function createMetaTag(value) {
  const tag = document.createElement("span");
  tag.textContent = value;
  return tag;
}

function getFormData(form) {
  return Object.fromEntries(new FormData(form).entries());
}

function normalizeEmail(email) {
  return String(email || "").trim().toLowerCase();
}

function validateLogin(payload) {
  const errors = {};

  if (!isEmail(payload.email)) {
    errors.loginEmail = "Enter a valid email address.";
  }

  if (!payload.password) {
    errors.loginPassword = "Enter your password.";
  }

  return errors;
}

function validateRegistration(payload) {
  const errors = {};

  if (!payload.firstName.trim()) errors.firstName = "First name is required.";
  if (!payload.lastName.trim()) errors.lastName = "Last name is required.";
  if (!isEmail(payload.email)) errors.registerEmail = "Enter a valid work email.";
  if (!payload.team.trim()) errors.team = "Team is required.";
  if (scorePassword(payload.password) < 3) {
    errors.registerPassword = "Use 8+ characters with upper, lower, and a number.";
  }
  if (!payload.termsAccepted) errors.termsAccepted = "Accept the account policy to continue.";

  return errors;
}

function isEmail(value) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(value || "").trim());
}

function scorePassword(password) {
  const value = String(password || "");
  let score = 0;

  if (value.length >= 8) score += 1;
  if (/[a-z]/.test(value)) score += 1;
  if (/[A-Z]/.test(value)) score += 1;
  if (/\d/.test(value)) score += 1;
  if (/[^a-zA-Z\d]/.test(value)) score += 1;

  return score;
}

function updatePasswordStrength() {
  const score = scorePassword(elements.registerPassword.value);
  const width = Math.min(score * 20, 100);
  const bar = elements.passwordStrength.querySelector("span");

  bar.style.width = `${width}%`;
  elements.passwordStrength.classList.toggle("is-medium", score >= 3 && score < 5);
  elements.passwordStrength.classList.toggle("is-strong", score >= 5);
}

elements.loginTab.addEventListener("click", () => dispatch({ type: "SET_MODE", mode: "login" }));
elements.registerTab.addEventListener("click", () => dispatch({ type: "SET_MODE", mode: "register" }));
elements.toggleLoginPassword.addEventListener("click", () => dispatch({ type: "TOGGLE_PASSWORD", key: "loginPasswordVisible" }));
elements.toggleRegisterPassword.addEventListener("click", () => dispatch({ type: "TOGGLE_PASSWORD", key: "registerPasswordVisible" }));
elements.registerPassword.addEventListener("input", updatePasswordStrength);

elements.loginForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const formData = getFormData(elements.loginForm);
  const payload = {
    email: normalizeEmail(formData.email),
    password: formData.password || "",
    rememberMe: Boolean(formData.rememberMe),
  };
  const errors = validateLogin(payload);

  if (Object.keys(errors).length > 0) {
    dispatch({ type: "SUBMIT_ERROR", errors, message: "Review the highlighted fields." });
    return;
  }

  dispatch({ type: "SUBMIT_START" });

  try {
    const user = await authApi.login(payload);
    dispatch({ type: "LOGIN_SUCCESS", user });
  } catch (error) {
    dispatch({ type: "SUBMIT_ERROR", message: error.message });
  }
});

elements.registerForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const formData = getFormData(elements.registerForm);
  const payload = {
    firstName: String(formData.firstName || "").trim(),
    lastName: String(formData.lastName || "").trim(),
    email: normalizeEmail(formData.email),
    role: formData.role || "member",
    team: String(formData.team || "").trim(),
    password: formData.password || "",
    termsAccepted: Boolean(formData.termsAccepted),
  };
  const errors = validateRegistration(payload);

  if (Object.keys(errors).length > 0) {
    dispatch({ type: "SUBMIT_ERROR", errors, message: "Review the highlighted fields." });
    return;
  }

  dispatch({ type: "SUBMIT_START" });

  try {
    const request = await authApi.register(payload);
    elements.registerForm.reset();
    updatePasswordStrength();
    dispatch({ type: "REGISTER_PENDING", request });
  } catch (error) {
    dispatch({ type: "SUBMIT_ERROR", message: error.message });
  }
});

render();
