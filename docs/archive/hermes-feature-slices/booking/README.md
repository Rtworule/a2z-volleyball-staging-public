# Authenticated Booking Flow

Frontend slice for authenticated A to Z Volleyball Center booking.

## Scope

- Select 1 to 4 hour reservations.
- Switch between court and trainer reservations.
- Auto-assign an available court or request a specific court.
- Submit reservation requests only for approved authenticated users.
- Display request status, conflicts, and the signed-in user's bookings.
- Uses the migrated `SchedulingService` logic from `/Users/rtworule/AI/Projects/A-to-Z-Volleyball-Center/src/scheduler.js`.

## Verify

```bash
npm test
npm start
```

Then open `http://localhost:4173`.
