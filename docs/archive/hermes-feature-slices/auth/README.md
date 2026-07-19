# User Login and Registration UI

This workspace contains a self-contained static frontend for task `t_631f6076`.

## Files

- `index.html` defines the login, registration, and admin approval queue UI.
- `styles.css` provides the responsive application layout and form states.
- `app.js` owns state management, validation, mocked auth calls, and approval actions.

## Integration Points

Replace the methods in `authApi` inside `app.js` with real backend calls:

- `login(payload)` should call the sign-in endpoint and reject pending or rejected accounts.
- `register(payload)` should create a pending user request for admin review.
- `approveRegistration(request)` should approve a pending request.
- `rejectRegistration(request)` should reject or archive a pending request.

The seeded demo account is `admin@company.com` with password `AdminPass1`.
