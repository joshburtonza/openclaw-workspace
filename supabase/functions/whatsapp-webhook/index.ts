/**
 * whatsapp-webhook — Supabase Edge Function
 *
 * Receives WhatsApp Business Cloud API webhooks.
 *
 * GET  /whatsapp-webhook  — Facebook verification challenge
 * POST /whatsapp-webhook  — Incoming messages / status updates
 *
 * Required Supabase secrets (set via: supabase secrets set KEY=value):
 *   WHATSAPP_VERIFY_TOKEN   — any string you choose; set same in Meta App Dashboard
 *   SUPABASE_SERVICE_ROLE_KEY — auto-injected by Supabase
 *   SUPABASE_URL              — auto-injected by Supabase
 *
 * Deploy:
 *   supabase functions deploy whatsapp-webhook --no-verify-jwt
 *
 * Webhook URL to register in Meta App Dashboard:
 *   https://afmpbtynucpbglwtbfuz.supabase.co/functions/v1/whatsapp-webhook
 */

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY  = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const VERIFY_TOKEN = Deno.env.get("WHATSAPP_VERIFY_TOKEN") ?? "amalfiai_wa_verify";

const supabase = createClient(SUPABASE_URL, SERVICE_KEY);

// ── helpers ──────────────────────────────────────────────────────────────────

function ok(body: string | object = "ok", status = 200): Response {
  const b = typeof body === "string" ? body : JSON.stringify(body);
  return new Response(b, {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function err(msg: string, status = 400): Response {
  return new Response(JSON.stringify({ error: msg }), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function waTs(unixSeconds: number | string): string {
  const n = typeof unixSeconds === "string" ? parseInt(unixSeconds) : unixSeconds;
  return new Date(n * 1000).toISOString();
}

// ── GET — Facebook verification challenge ────────────────────────────────────

function handleVerification(url: URL): Response {
  const mode      = url.searchParams.get("hub.mode");
  const token     = url.searchParams.get("hub.verify_token");
  const challenge = url.searchParams.get("hub.challenge");

  if (mode === "subscribe" && token === VERIFY_TOKEN && challenge) {
    console.log("[whatsapp-webhook] Verification OK");
    return new Response(challenge, { status: 200 });
  }
  console.warn("[whatsapp-webhook] Verification FAILED", { mode, token });
  return err("Verification failed", 403);
}

// ── POST — inbound message processing ────────────────────────────────────────

interface WaMessage {
  id: string;
  from: string;
  timestamp: string;
  type: string;
  text?: { body: string };
  image?: { caption?: string; mime_type?: string; sha256?: string; id?: string };
  document?: { caption?: string; filename?: string; mime_type?: string; id?: string };
  audio?: { mime_type?: string; id?: string; voice?: boolean };
  video?: { caption?: string; mime_type?: string; id?: string };
  sticker?: { mime_type?: string; id?: string };
  location?: { latitude: number; longitude: number; name?: string; address?: string };
  reaction?: { message_id: string; emoji: string };
}

interface WaContact {
  profile: { name: string };
  wa_id: string;
}

async function handleMessages(payload: unknown, phoneNumberId: string): Promise<void> {
  const p = payload as Record<string, unknown>;
  const entry = (p.entry as unknown[])?.[0] as Record<string, unknown> | undefined;
  if (!entry) return;

  const changes = entry.changes as unknown[] | undefined;
  if (!changes?.length) return;

  for (const change of changes) {
    const ch = change as Record<string, unknown>;
    if (ch.field !== "messages") continue;

    const val = ch.value as Record<string, unknown>;
    const messages: WaMessage[] = (val.messages as WaMessage[]) ?? [];
    const contacts: WaContact[] = (val.contacts as WaContact[]) ?? [];
    const metaPhoneId = (val.metadata as Record<string, unknown>)?.phone_number_id as string ?? phoneNumberId;

    // Build contact map: wa_id → name
    const contactMap: Record<string, string> = {};
    for (const c of contacts) {
      contactMap[c.wa_id] = c.profile?.name ?? c.wa_id;
    }

    for (const msg of messages) {
      if (!msg.id || !msg.from) continue;

      const msgType = msg.type ?? "text";
      let body: string | null = null;
      let mediaUrl: string | null = null;
      let mediaMime: string | null = null;

      switch (msgType) {
        case "text":
          body = msg.text?.body ?? null;
          break;
        case "image":
          body = msg.image?.caption ?? null;
          mediaMime = msg.image?.mime_type ?? null;
          break;
        case "document":
          body = msg.document?.caption ?? msg.document?.filename ?? null;
          mediaMime = msg.document?.mime_type ?? null;
          break;
        case "audio":
          body = msg.audio?.voice ? "[Voice message]" : "[Audio file]";
          mediaMime = msg.audio?.mime_type ?? null;
          break;
        case "video":
          body = msg.video?.caption ?? "[Video]";
          mediaMime = msg.video?.mime_type ?? null;
          break;
        case "sticker":
          body = "[Sticker]";
          mediaMime = msg.sticker?.mime_type ?? null;
          break;
        case "location":
          const loc = msg.location;
          body = loc
            ? `[Location: ${loc.name ?? ""} ${loc.latitude},${loc.longitude}]`.trim()
            : "[Location]";
          break;
        case "reaction":
          body = `[Reaction: ${msg.reaction?.emoji ?? "?"} on ${msg.reaction?.message_id ?? ""}]`;
          break;
        default:
          body = `[${msgType}]`;
      }

      const fromNumber = msg.from.startsWith("+") ? msg.from : `+${msg.from}`;
      const fromName   = contactMap[msg.from] ?? null;

      const row = {
        message_id:     msg.id,
        from_number:    fromNumber,
        from_name:      fromName,
        message_type:   msgType,
        body:           body,
        media_url:      mediaUrl,
        media_mime_type: mediaMime,
        timestamp_wa:   waTs(msg.timestamp),
        phone_number_id: metaPhoneId,
        raw_payload:    payload,
        notified:       false,
        read_sent:      false,
      };

      const { error } = await supabase
        .from("whatsapp_messages")
        .upsert(row, { onConflict: "message_id", ignoreDuplicates: true });

      if (error) {
        console.error("[whatsapp-webhook] DB upsert error:", error.message, "msg_id:", msg.id);
      } else {
        console.log(`[whatsapp-webhook] Stored message ${msg.id} from ${fromNumber} type=${msgType}`);
      }
    }
  }
}

// ── Main handler ─────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  const url = new URL(req.url);

  // GET — Facebook hub verification
  if (req.method === "GET") {
    return handleVerification(url);
  }

  // POST — incoming webhooks
  if (req.method === "POST") {
    let payload: unknown;
    try {
      payload = await req.json();
    } catch {
      return err("Invalid JSON", 400);
    }

    // WhatsApp expects 200 quickly — process async
    const p = payload as Record<string, unknown>;
    const phoneNumberId = url.searchParams.get("phone_number_id") ?? "";

    // Only process message webhooks (ignore status updates)
    try {
      await handleMessages(p, phoneNumberId);
    } catch (e) {
      console.error("[whatsapp-webhook] Error processing webhook:", e);
      // Still return 200 — otherwise WhatsApp will retry indefinitely
    }

    return ok({ status: "received" });
  }

  return err("Method not allowed", 405);
});
