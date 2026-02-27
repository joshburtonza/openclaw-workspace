# WhatsApp Business Cloud API Setup

## What's already built

- `supabase/functions/whatsapp-webhook/index.ts` — Edge Function: receives inbound messages
- `supabase/migrations/004_whatsapp_messages.sql` — DB table for inbound messages
- `scripts/whatsapp-inbound-notifier.sh` — polls Supabase, Telegrams Josh for new messages
- `scripts/whatsapp-capture.sh` — morning brief inbox summary (reads from Supabase)
- `launchagents/com.amalfiai.whatsapp-inbound-notifier.plist` — loaded, runs every 5 min
- `/reply wa [contact] [message]` in gateway — outbound send (already works once token set)

## Step 1 — Set credentials in .env.scheduler

Replace the placeholder values:
```
WHATSAPP_TOKEN=<your_permanent_system_user_token_from_meta>
WHATSAPP_PHONE_ID=<your_phone_number_id_from_meta_dashboard>
```

## Step 2 — Run the DB migration

In Supabase dashboard > SQL Editor:
- Run: `supabase/migrations/004_whatsapp_messages.sql`

## Step 3 — Deploy the Edge Function

```bash
cd /Users/henryburton/.openclaw/workspace-anthropic
supabase functions deploy whatsapp-webhook --no-verify-jwt
```

If supabase CLI not linked yet:
```bash
supabase login
supabase link --project-ref afmpbtynucpbglwtbfuz
supabase secrets set WHATSAPP_VERIFY_TOKEN=amalfiai_wa_verify
supabase functions deploy whatsapp-webhook --no-verify-jwt
```

## Step 4 — Register webhook in Meta App Dashboard

1. Go to Meta App Dashboard > WhatsApp > Configuration > Webhooks
2. Callback URL: `https://afmpbtynucpbglwtbfuz.supabase.co/functions/v1/whatsapp-webhook`
3. Verify Token: `amalfiai_wa_verify`
4. Subscribe to: `messages`

## Step 5 — Update contacts.json with real numbers

Edit `data/contacts.json` and replace placeholder numbers with real WhatsApp numbers:
```json
{
  "clients": [
    {"name": "Ascend LC",  "slug": "ascend_lc",  "number": "+27XXXXXXXXX"},
    {"name": "Race Technik", "slug": "race_technik", "number": "+27XXXXXXXXX"}
  ]
}
```

## How it works end-to-end

1. Client sends WhatsApp message to your WhatsApp Business number
2. Meta calls the Edge Function webhook
3. Edge Function writes to `whatsapp_messages` table in Supabase
4. `whatsapp-inbound-notifier.sh` (every 5 min) detects new row, Telegrams Josh:
   ```
   📱 Farhaan (Race Technik) (+27831234567)
   Hey Josh, the car is ready for collection
   ⏰ 14:32 SAST
   [↩️ Reply]  [✅ Dismiss]
   ```
5. Josh taps [Reply] or sends `/reply wa race_technik [message]` from Telegram
6. Morning brief at 07:30 SAST includes full WhatsApp inbox summary

## Get a permanent token (important)

Temporary tokens expire in 24h. For production, create a **System User** in Meta Business Manager:
1. Business Settings > Users > System Users > Add
2. Generate token with `whatsapp_business_messaging` + `whatsapp_business_management` permissions
3. That token never expires — put it in `.env.scheduler` as `WHATSAPP_TOKEN`
