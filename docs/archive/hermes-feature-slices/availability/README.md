# A to Z Volleyball Center

Backend scheduling logic and a browser availability calendar for court and trainer bookings.

## Implemented rules

- 9 individually bookable volleyball courts.
- Court bookings can target a specific court or automatically choose the first available court.
- Gym/trainer bookings use pooled capacity and allow at most 2 concurrent trainer sessions.
- Users must be authenticated and admin-approved before booking. Admins can book and manage payment status.
- Default operating hours:
  - Weekdays: 10:00 to 23:00
  - Weekends: 08:00 to 21:00
- Booking duration must be 1 to 4 hours.
- Configurable closures and fixed reservations block availability before normal bookings.
- Regular-user availability hides reservation owner details.
- Users can list their own past and future bookings; admins can list any user bookings.

## Availability calendar

Open `index.html` from the project folder to view the lightweight frontend calendar. It shows:

- 9 court rows and 1 gym trainer row.
- Hourly slots based on configurable weekday/weekend operating hours.
- Privacy-safe open/busy court states.
- Gym trainer capacity as remaining openings out of 2.
- Duration controls for 1 to 4 hour booking windows.

## Verify

```bash
npm test
```
