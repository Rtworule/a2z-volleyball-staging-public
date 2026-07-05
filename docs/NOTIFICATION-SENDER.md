# Wiring the notification-outbox sender

Bookings and cancellations queue rows in `notification_outbox`. Nothing sends
them until you deploy this small Edge Function and schedule it. Works the same
for staging and production — repeat per project.

## 1. Pick an email provider
Easiest is Resend (https://resend.com): free tier, one API key, verify your
sending domain (atozvolleyball.com) under Domains. Any SMTP/SendGrid/Postmark
works too; only the `send` block below changes.

## 2. Create the Edge Function
In your repo:

    supabase functions new send-notifications

`supabase/functions/send-notifications/index.ts`:

```ts
import { createClient } from "npm:@supabase/supabase-js@2";

Deno.serve(async () => {
  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!   // injected automatically
  );

  const { data, error } = await supabase.rpc("system_notification_outbox_job", { p_limit: 25 });
  if (error) return new Response(error.message, { status: 500 });

  for (const item of data.pending ?? []) {
    const p = item.payload;
    const when = new Date(p.start).toLocaleString("en-US", { timeZone: "America/New_York" });
    const where = p.resourceType === "trainer" ? "Trainer gym" : `Court ${p.courtNumber}`;
    const subject = item.notificationType === "reservation_cancelled"
      ? `Reservation cancelled — ${where}, ${when}`
      : item.notificationType === "reservation_updated"
        ? `Reservation updated — ${where}, ${when}`
        : `Reservation confirmed — ${where}, ${when}`;
    const body = `${p.teamName}\n${where}\n${when}` +
      (p.lessonPlayerBracket ? `\nPlayers: ${p.lessonPlayerBracket}` : "") +
      (p.amount ? `\nAmount: $${p.amount} (invoiced)` : "");

    const send = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${Deno.env.get("RESEND_API_KEY")}`,
        "Content-Type": "application/json"
      },
      body: JSON.stringify({
        from: "A to Z Volleyball <noreply@atozvolleyball.com>",
        to: item.recipientEmail,
        subject,
        text: body
      })
    });

    await supabase.rpc("admin_mark_notification", {
      p_notification_id: item.id,
      p_success: send.ok
    });
  }
  return new Response("ok");
});
```

Note: `admin_mark_notification` checks for an approved admin. The service role
bypasses RLS but not that check — so either create a dedicated "system" admin
profile, or (simpler) run this SQL once per project to let the service role
mark rows directly:

    GRANT UPDATE ON public.notification_outbox TO service_role;

and replace the `admin_mark_notification` rpc call with a direct update:

```ts
await supabase.from("notification_outbox")
  .update({ status: send.ok ? "sent" : "failed", sent_at: new Date().toISOString() })
  .eq("id", item.id);
```

## 3. Deploy + secrets (per environment)

    supabase link --project-ref <staging-ref>
    supabase secrets set RESEND_API_KEY=re_xxx
    supabase functions deploy send-notifications

Repeat with the production project ref and its own key when you go live.

## 4. Schedule it
Dashboard -> Integrations -> Cron (pg_cron) -> New job, every minute or five:

    select net.http_post(
      url := 'https://<project-ref>.supabase.co/functions/v1/send-notifications',
      headers := jsonb_build_object('Authorization', 'Bearer ' || '<anon-key>')
    );

(Enable the `pg_net` extension if prompted. Alternatively use any external
cron/uptime pinger hitting the function URL.)

## 5. Verify
Book a test reservation -> row appears in notification_outbox as `pending` ->
within a schedule tick it flips to `sent` and the email arrives. Failures show
`failed` with `attempts` incremented; they are retried on later runs only if
you remove the status filter or reset rows to pending.
