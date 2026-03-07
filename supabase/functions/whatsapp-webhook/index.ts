/**
 * whatsapp-webhook — Supabase Edge Function (Twilio)
 *
 * Receives inbound WhatsApp messages via Twilio's webhook.
 * Twilio POSTs form-encoded data; we store to whatsapp_messages table.
 * Returns TwiML <Response/> (required by Twilio — empty means no auto-reply).
 *
 * Required Supabase secrets (set via: supabase secrets set KEY=value):
 *   TWILIO_ACCOUNT_SID      — from Twilio console
 *   SUPABASE_SERVICE_ROLE_KEY — auto-injected by Supabase
 *   SUPABASE_URL              — auto-injected by Supabase
 *
 * In Twilio Console → Messaging → WhatsApp Sandbox (or your number):
 *   "When a message comes in" webhook URL:
 *   https://afmpbtynucpbglwtbfuz.supabase.co/functions/v1/whatsapp-webhook
 *   Method: HTTP POST
 *
 * Deploy:
 *   supabase functions deploy whatsapp-webhook --no-verify-jwt
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL  = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY   = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TWILIO_SID    = Deno.env.get("TWILIO_ACCOUNT_SID") ?? "";

const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

// TwiML empty response — tells Twilio we received it, send no auto-reply
const TWIML_OK = `<?xml version="1.0" encoding="UTF-8"?><Response/>`;

function twimlResponse(status = 200): Response {
  return new Response(TWIML_OK, {
    status,
    headers: { "Content-Type": "text/xml" },
  });
}

function errResponse(msg: string, status = 400): Response {
  return new Response(JSON.stringify({ error: msg }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// Strip "whatsapp:" prefix that Twilio adds to all numbers
function stripWaPrefix(num: string): string {
  return num.startsWith("whatsapp:") ? num.slice(9) : num;
}

// Normalise to E.164 with leading +
function normaliseNumber(num: string): string {
  const stripped = stripWaPrefix(num);
  return stripped.startsWith("+") ? stripped : `+${stripped}`;
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") {
    return errResponse("Method not allowed", 405);
  }

  // ── Parse Twilio's form-encoded body ────────────────────────────────────────
  let formText: string;
  try {
    formText = await req.text();
  } catch {
    return errResponse("Could not read body", 400);
  }

  const params = new URLSearchParams(formText);

  const messageSid        = params.get("MessageSid") ?? "";
  const accountSid        = params.get("AccountSid") ?? "";
  const fromRaw           = params.get("From") ?? "";
  const toRaw             = params.get("To") ?? "";
  const body              = params.get("Body") ?? null;
  const numMedia          = parseInt(params.get("NumMedia") ?? "0", 10);
  const mediaUrl          = params.get("MediaUrl0") ?? null;
  const mediaMime         = params.get("MediaContentType0") ?? null;
  const profileName       = params.get("ProfileName") ?? null;  // sender's WA display name

  // ── Basic validation ─────────────────────────────────────────────────────────
  if (!messageSid || !fromRaw) {
    console.warn("[whatsapp-webhook] Missing MessageSid or From — ignoring");
    return twimlResponse();
  }

  // Optional: verify AccountSid matches our Twilio account
  if (TWILIO_SID && accountSid && accountSid !== TWILIO_SID) {
    console.warn("[whatsapp-webhook] AccountSid mismatch — ignoring");
    return twimlResponse();
  }

  // ── Determine message type ────────────────────────────────────────────────
  let msgType = "text";
  if (numMedia > 0 && mediaMime) {
    if (mediaMime.startsWith("audio/"))  msgType = "audio";
    else if (mediaMime.startsWith("image/")) msgType = "image";
    else if (mediaMime.startsWith("video/")) msgType = "video";
    else msgType = "document";
  }

  const fromNumber = normaliseNumber(fromRaw);
  const toNumber   = normaliseNumber(toRaw);

  const row = {
    message_id:      messageSid,
    from_number:     fromNumber,
    from_name:       profileName,
    contact_slug:    null,
    contact_name:    profileName,
    message_type:    msgType,
    body:            body,
    media_url:       mediaUrl,
    media_mime_type: mediaMime,
    timestamp_wa:    new Date().toISOString(),
    phone_number_id: toNumber,
    raw_payload:     Object.fromEntries(params.entries()),
    notified:        false,
    read_sent:       false,
  };

  const { error } = await supabase
    .from("whatsapp_messages")
    .upsert(row, { onConflict: "message_id", ignoreDuplicates: true });

  if (error) {
    console.error("[whatsapp-webhook] DB upsert error:", error.message, "msg:", messageSid);
  } else {
    console.log(`[whatsapp-webhook] Stored ${messageSid} from ${fromNumber} type=${msgType}`);
  }

  // Twilio requires this response within 15s
  return twimlResponse();
});
