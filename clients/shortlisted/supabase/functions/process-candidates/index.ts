import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.93.3";

// ============================================================
// Types
// ============================================================

interface GateRule {
  field: string;
  op: "eq" | "lt" | "gt" | "lte" | "gte" | "ne";
  value: unknown;
  reason: string;
}

interface GateRules {
  hard?: GateRule[];
  soft?: GateRule[];
}

interface GateResult {
  pass: boolean;
  action: "pass" | "flag" | "reject";
  reason: string;
  flags: string[];
}

// Universal extraction interface — all verticals must return these fields.
// Vertical-specific fields are captured by the index signature.
interface CandidateExtraction {
  candidate_name: string;
  email_address?: string;
  contact_number?: string;
  current_location_raw?: string;
  countries_raw?: string[];
  has_required_qualification: boolean;
  years_experience: number;
  raw_ai_score: number;
  ai_notes?: string;
  // Teaching-specific (present for teaching vertical, absent for others)
  years_teaching_experience?: number;
  qualification_type?: string;
  subject_specialisation?: string;
  university_attended?: string;
  has_sace_registration?: boolean;
  has_education_degree?: boolean;
  // Index signature for any vertical-specific fields not listed above
  [key: string]: unknown;
}

interface OrgGmailToken {
  refresh_token: string;
  access_token: string | null;
  token_expires_at: string | null;
}

// Flattened route object (after joining organizations + vertical_templates)
interface Route {
  id: string;
  source_email: string;
  user_id: string;
  organization_id: string;
  inbox_tz_id: string;
  gmail_token_id?: string | null;
  // From vertical_templates (via organizations join)
  vertical_name?: string;
  ai_system_prompt?: string;
  ai_extraction_schema?: string;
  gate_rules?: GateRules;
  // Org-level overrides
  ai_prompt_override?: string;
  gate_rules_override?: GateRules;
}

// Raw Supabase join shape (before flattening)
interface RawRoute {
  id: string;
  source_email: string;
  user_id: string;
  organization_id: string;
  inbox_tz_id: string;
  gmail_token_id?: string | null;
  organizations?: {
    ai_prompt_override?: string | null;
    gate_rules_override?: GateRules | null;
    vertical_id?: string | null;
    vertical_templates?: {
      name: string;
      ai_system_prompt: string;
      ai_extraction_schema: string;
      gate_rules: GateRules;
    } | null;
  } | null;
}

// ============================================================
// Gmail helpers
// ============================================================

async function refreshGmailToken(
  refreshToken: string,
  clientId: string,
  clientSecret: string,
): Promise<string> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "refresh_token",
      refresh_token: refreshToken,
      client_id: clientId,
      client_secret: clientSecret,
    }),
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Failed to refresh Gmail token: ${errText}`);
  }
  const data = await res.json();
  return data.access_token as string;
}

async function refreshIfNeeded(
  token: OrgGmailToken,
  tokenId: string,
  supabase: SupabaseClient,
): Promise<string> {
  // Check whether the stored access_token is still valid (with a 5-minute buffer)
  const fiveMinutesMs = 5 * 60 * 1000;
  const isExpired =
    !token.access_token ||
    !token.token_expires_at ||
    new Date(token.token_expires_at).getTime() - Date.now() < fiveMinutesMs;

  if (!isExpired) {
    return token.access_token!;
  }

  // Refresh using Google OAuth
  const newAccessToken = await refreshGmailToken(
    token.refresh_token,
    Deno.env.get("GMAIL_CLIENT_ID")!,
    Deno.env.get("GMAIL_CLIENT_SECRET")!,
  );

  // Persist the new token back to Supabase
  const expiresAt = new Date(Date.now() + 3600 * 1000).toISOString(); // 1 hour
  await supabase
    .from("org_gmail_tokens")
    .update({
      access_token: newAccessToken,
      token_expires_at: expiresAt,
      updated_at: new Date().toISOString(),
    })
    .eq("id", tokenId);

  return newAccessToken;
}

async function getGmailToken(route: Route, supabase: SupabaseClient): Promise<string> {
  if (route.gmail_token_id) {
    const { data, error } = await supabase
      .from("org_gmail_tokens")
      .select("refresh_token, access_token, token_expires_at")
      .eq("id", route.gmail_token_id)
      .single();

    if (error || !data) {
      console.error(`Failed to fetch org_gmail_token for route ${route.id}:`, error);
      throw new Error("Could not load per-org Gmail token");
    }

    return await refreshIfNeeded(
      data as OrgGmailToken,
      route.gmail_token_id,
      supabase,
    );
  }

  // Fallback: shared env secret — this is Nicole's existing setup
  return await refreshGmailToken(
    Deno.env.get("GMAIL_REFRESH_TOKEN")!,
    Deno.env.get("GMAIL_CLIENT_ID")!,
    Deno.env.get("GMAIL_CLIENT_SECRET")!,
  );
}

// ============================================================
// Gmail API helpers
// ============================================================

interface GmailMessage {
  id: string;
  threadId: string;
  payload?: {
    headers?: Array<{ name: string; value: string }>;
    parts?: Array<{ mimeType: string; body?: { data?: string } }>;
    body?: { data?: string };
  };
}

async function listUnreadMessages(
  accessToken: string,
  emailAddress: string,
): Promise<Array<{ id: string; threadId: string }>> {
  const query = encodeURIComponent(`to:${emailAddress} is:unread`);
  const url = `https://gmail.googleapis.com/gmail/v1/users/me/messages?q=${query}&maxResults=50`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Gmail list error: ${errText}`);
  }
  const data = await res.json();
  return data.messages ?? [];
}

async function fetchMessage(accessToken: string, messageId: string): Promise<GmailMessage> {
  const url = `https://gmail.googleapis.com/gmail/v1/users/me/messages/${messageId}?format=full`;
  const res = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });
  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Gmail fetch message error: ${errText}`);
  }
  return await res.json() as GmailMessage;
}

async function markAsRead(accessToken: string, messageId: string): Promise<void> {
  const url = `https://gmail.googleapis.com/gmail/v1/users/me/messages/${messageId}/modify`;
  await fetch(url, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ removeLabelIds: ["UNREAD"] }),
  });
}

function extractEmailBody(message: GmailMessage): string {
  // Try multipart first
  if (message.payload?.parts) {
    for (const part of message.payload.parts) {
      if (part.mimeType === "text/plain" && part.body?.data) {
        return atob(part.body.data.replace(/-/g, "+").replace(/_/g, "/"));
      }
    }
    // Fall back to text/html part if no plain text
    for (const part of message.payload.parts) {
      if (part.mimeType === "text/html" && part.body?.data) {
        const html = atob(part.body.data.replace(/-/g, "+").replace(/_/g, "/"));
        // Strip tags for a rough plain-text approximation
        return html.replace(/<[^>]+>/g, " ").replace(/\s+/g, " ").trim();
      }
    }
  }
  // Single-part body
  if (message.payload?.body?.data) {
    return atob(message.payload.body.data.replace(/-/g, "+").replace(/_/g, "/"));
  }
  return "";
}

function extractHeader(message: GmailMessage, name: string): string {
  return (
    message.payload?.headers?.find(
      (h) => h.name.toLowerCase() === name.toLowerCase(),
    )?.value ?? ""
  );
}

// ============================================================
// Canonical day helper (for the existing date bucketing pattern)
// ============================================================

function getCanonicalDay(tzId: string): string {
  try {
    const now = new Date();
    const dateStr = new Intl.DateTimeFormat("en-ZA", {
      timeZone: tzId || "Africa/Johannesburg",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(now);
    // en-ZA returns DD/MM/YYYY — parse it
    const [day, month, year] = dateStr.split("/");
    return `${year}-${month}-${day}`;
  } catch {
    return new Date().toISOString().split("T")[0];
  }
}

// ============================================================
// AI extraction
// ============================================================

async function extractCandidateWithAI(
  emailBody: string,
  systemPrompt: string,
  extractionSchema: string,
): Promise<CandidateExtraction> {
  const anthropicKey = Deno.env.get("ANTHROPIC_API_KEY");
  if (!anthropicKey) throw new Error("ANTHROPIC_API_KEY not configured");

  const userMessage = `Here is the candidate email / CV content to analyse:

---
${emailBody.substring(0, 15000)}
---

Extract the candidate information and return valid JSON matching this schema:
${extractionSchema}

Return ONLY a valid JSON object. Do not include any prose, markdown, or code fences.`;

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "x-api-key": anthropicKey,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "claude-opus-4-6",
      max_tokens: 1024,
      system: systemPrompt,
      messages: [{ role: "user", content: userMessage }],
    }),
  });

  if (!res.ok) {
    const errText = await res.text();
    throw new Error(`Anthropic API error: ${errText}`);
  }

  const aiResponse = await res.json();
  const rawText: string = aiResponse.content?.[0]?.text ?? "";

  // Strip any accidental markdown fences
  const cleaned = rawText
    .replace(/^```json\s*/i, "")
    .replace(/^```\s*/i, "")
    .replace(/\s*```$/i, "")
    .trim();

  try {
    return JSON.parse(cleaned) as CandidateExtraction;
  } catch (parseErr) {
    throw new Error(`Failed to parse AI extraction JSON: ${parseErr}\nRaw: ${rawText.substring(0, 500)}`);
  }
}

// ============================================================
// Gate evaluation
// ============================================================

function evaluateRule(candidate: CandidateExtraction, rule: GateRule): boolean {
  const fieldValue = candidate[rule.field] as number | string | boolean | null | undefined;
  const ruleValue = rule.value;

  switch (rule.op) {
    case "eq":  return fieldValue === ruleValue;
    case "ne":  return fieldValue !== ruleValue;
    case "lt":  return typeof fieldValue === "number" && typeof ruleValue === "number" && fieldValue < ruleValue;
    case "lte": return typeof fieldValue === "number" && typeof ruleValue === "number" && fieldValue <= ruleValue;
    case "gt":  return typeof fieldValue === "number" && typeof ruleValue === "number" && fieldValue > ruleValue;
    case "gte": return typeof fieldValue === "number" && typeof ruleValue === "number" && fieldValue >= ruleValue;
    default:    return false;
  }
}

function applyQualificationGate(
  candidate: CandidateExtraction,
  gateRules: GateRules,
): GateResult {
  // Universal hard gate: has_required_qualification must be true.
  // The "intelligence" of what counts as qualified lives in the AI prompt —
  // we just enforce the boolean here.
  if (!candidate.has_required_qualification) {
    return {
      pass: false,
      action: "reject",
      reason: "Does not meet vertical qualification requirement",
      flags: [],
    };
  }

  // Evaluate additional hard rules from gate_rules jsonb (if any).
  // Gate rule semantics: the rule describes the REQUIRED condition.
  // Reject if the condition is NOT met (i.e. evaluateRule returns false).
  for (const hardRule of gateRules.hard ?? []) {
    // Skip the has_required_qualification rule — already handled above
    if (hardRule.field === "has_required_qualification") continue;
    if (!evaluateRule(candidate, hardRule)) {
      return {
        pass: false,
        action: "reject",
        reason: hardRule.reason,
        flags: [],
      };
    }
  }

  // Evaluate soft rules — these produce flags but do not reject
  const flags: string[] = [];
  for (const softRule of gateRules.soft ?? []) {
    if (evaluateRule(candidate, softRule)) {
      flags.push(softRule.reason);
    }
  }

  return {
    pass: true,
    action: flags.length > 0 ? "flag" : "pass",
    reason: flags.length > 0 ? `Flagged: ${flags.join("; ")}` : "Passed all gates",
    flags,
  };
}

// ============================================================
// Teaching-specific column mapping (backward compatibility for Nicole)
// ============================================================

function mapTeachingFields(candidate: CandidateExtraction): Record<string, unknown> {
  return {
    // teaching vertical uses years_teaching_experience in the schema,
    // but the candidates table column is years_teaching_experience.
    // Also handle if the AI returned years_experience instead.
    years_teaching_experience: candidate.years_teaching_experience ?? candidate.years_experience ?? null,
    qualification_type: candidate.qualification_type ?? null,
    subject_specialisation: candidate.subject_specialisation ?? null,
    university_attended: candidate.university_attended ?? null,
    has_sace_registration: candidate.has_sace_registration ?? false,
    has_education_degree: candidate.has_education_degree ?? false,
    has_required_qualification: candidate.has_required_qualification ?? false,
  };
}

// ============================================================
// Route flattening helper
// ============================================================

function flattenRoute(raw: RawRoute): Route {
  const org = raw.organizations ?? null;
  const vt = org?.vertical_templates ?? null;

  return {
    id: raw.id,
    source_email: raw.source_email,
    user_id: raw.user_id,
    organization_id: raw.organization_id,
    inbox_tz_id: raw.inbox_tz_id,
    gmail_token_id: raw.gmail_token_id ?? null,
    vertical_name: vt?.name ?? undefined,
    ai_system_prompt: org?.ai_prompt_override ?? vt?.ai_system_prompt ?? undefined,
    ai_extraction_schema: vt?.ai_extraction_schema ?? undefined,
    gate_rules: (org?.gate_rules_override ?? vt?.gate_rules) ?? undefined,
    ai_prompt_override: org?.ai_prompt_override ?? undefined,
    gate_rules_override: org?.gate_rules_override ?? undefined,
  };
}

// ============================================================
// Default teaching prompt (fallback when vertical not configured)
// ============================================================

const DEFAULT_TEACHING_SYSTEM_PROMPT = `You are an expert SA educator recruiter. Extract candidate details from this CV/email. The candidate has_required_qualification if they have a relevant teaching degree (BEd, PGCE, or equivalent) and are registered or eligible for SACE registration. Return valid JSON only.`;

const DEFAULT_TEACHING_SCHEMA = `{
  "candidate_name": "string",
  "email_address": "string",
  "contact_number": "string",
  "current_location_raw": "string",
  "countries_raw": ["array of strings"],
  "has_required_qualification": "boolean",
  "years_teaching_experience": "integer",
  "qualification_type": "string",
  "subject_specialisation": "string",
  "university_attended": "string",
  "has_sace_registration": "boolean",
  "has_education_degree": "boolean",
  "raw_ai_score": "integer 0-100",
  "ai_notes": "string"
}`;

const DEFAULT_GATE_RULES: GateRules = {
  hard: [{ field: "has_required_qualification", op: "eq", value: true, reason: "Must have teaching qualification" }],
  soft: [{ field: "years_experience", op: "lt", value: 2, reason: "Less than 2 years experience" }],
};

// ============================================================
// Main handler
// ============================================================

serve(async (_req) => {
  const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
  const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
    console.error("Missing Supabase credentials");
    return new Response(JSON.stringify({ error: "Server misconfiguration" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  try {
    // ----------------------------------------------------------
    // 1. Load all active inbound routes, joining org + vertical config
    // ----------------------------------------------------------
    const { data: rawRoutes, error: routesError } = await supabase
      .from("inbound_email_routes")
      .select(`
        id,
        source_email,
        user_id,
        organization_id,
        inbox_tz_id,
        gmail_token_id,
        organizations (
          ai_prompt_override,
          gate_rules_override,
          vertical_id,
          vertical_templates (
            name,
            ai_system_prompt,
            ai_extraction_schema,
            gate_rules
          )
        )
      `)
      .eq("is_active", true);

    if (routesError) {
      throw new Error(`Failed to load routes: ${routesError.message}`);
    }

    if (!rawRoutes || rawRoutes.length === 0) {
      console.log("No active routes found");
      return new Response(JSON.stringify({ processed: 0 }), {
        headers: { "Content-Type": "application/json" },
      });
    }

    const routes: Route[] = (rawRoutes as unknown as RawRoute[]).map(flattenRoute);
    let totalProcessed = 0;

    // ----------------------------------------------------------
    // 2. Process each route
    // ----------------------------------------------------------
    for (const route of routes) {
      try {
        console.log(`Processing route ${route.id} (${route.source_email}) vertical=${route.vertical_name ?? "unset"}`);

        // Resolve Gmail access token (per-org or shared fallback)
        const accessToken = await getGmailToken(route, supabase);

        // Fetch unread messages for this inbox
        const messages = await listUnreadMessages(accessToken, route.source_email);
        console.log(`  ${messages.length} unread message(s)`);

        for (const msgRef of messages) {
          try {
            const message = await fetchMessage(accessToken, msgRef.id);
            const subject = extractHeader(message, "subject");
            const fromHeader = extractHeader(message, "from");
            const emailBody = extractEmailBody(message);

            if (!emailBody.trim()) {
              console.log(`  Skipping empty message ${msgRef.id}`);
              await markAsRead(accessToken, msgRef.id);
              continue;
            }

            // Check for duplicate (already processed this message)
            const { data: existing } = await supabase
              .from("candidates")
              .select("id")
              .eq("gmail_message_id", msgRef.id)
              .single();

            if (existing) {
              console.log(`  Already processed message ${msgRef.id}, skipping`);
              await markAsRead(accessToken, msgRef.id);
              continue;
            }

            // --------------------------------------------------
            // 3. AI extraction using vertical-specific prompt
            // --------------------------------------------------
            const systemPrompt = route.ai_system_prompt ?? DEFAULT_TEACHING_SYSTEM_PROMPT;
            const schema = route.ai_extraction_schema ?? DEFAULT_TEACHING_SCHEMA;
            const gateRules = route.gate_rules ?? DEFAULT_GATE_RULES;
            const verticalName = route.vertical_name ?? "teaching";

            let candidate: CandidateExtraction;
            try {
              candidate = await extractCandidateWithAI(emailBody, systemPrompt, schema);
            } catch (aiErr) {
              console.error(`  AI extraction failed for ${msgRef.id}:`, aiErr);
              await markAsRead(accessToken, msgRef.id);
              continue;
            }

            // --------------------------------------------------
            // 4. Apply qualification gate
            // --------------------------------------------------
            const gateResult = applyQualificationGate(candidate, gateRules);
            console.log(`  Gate result: ${gateResult.action} — ${gateResult.reason}`);

            // --------------------------------------------------
            // 5. Build the candidate DB row
            // --------------------------------------------------
            const canonicalDay = getCanonicalDay(route.inbox_tz_id);

            const candidateRow: Record<string, unknown> = {
              // Universal fields — every candidate gets these
              candidate_name: candidate.candidate_name ?? "Unknown",
              email_address: candidate.email_address ?? null,
              contact_number: candidate.contact_number ?? null,
              current_location_raw: candidate.current_location_raw ?? null,
              countries_raw: candidate.countries_raw ?? null,
              raw_ai_score: candidate.raw_ai_score ?? 0,
              ai_notes: candidate.ai_notes ?? null,

              // Multi-tenant fields
              raw_extraction: candidate,       // full extraction stored as jsonb
              vertical: verticalName,          // which vertical processed this

              // Gate outcome
              qualification_gate_pass: gateResult.pass,
              qualification_gate_action: gateResult.action,
              qualification_gate_reason: gateResult.reason,
              qualification_gate_flags: gateResult.flags,

              // Metadata
              organization_id: route.organization_id,
              user_id: route.user_id,
              source_email: route.source_email,
              canonical_day: canonicalDay,
              date_received: new Date().toISOString(),
              gmail_message_id: msgRef.id,
              gmail_thread_id: msgRef.threadId,
              email_subject: subject,
              email_from: fromHeader,
            };

            // Teaching-specific columns — populated for Nicole's dashboard (backward compat)
            if (verticalName === "teaching") {
              Object.assign(candidateRow, mapTeachingFields(candidate));
            }

            // --------------------------------------------------
            // 6. Insert candidate row
            // --------------------------------------------------
            const { error: insertError } = await supabase
              .from("candidates")
              .insert(candidateRow);

            if (insertError) {
              console.error(`  Failed to insert candidate from ${msgRef.id}:`, insertError);
            } else {
              console.log(`  Inserted candidate: ${candidate.candidate_name} (${gateResult.action})`);
              totalProcessed++;
            }

            // Mark message as read regardless of insert outcome
            await markAsRead(accessToken, msgRef.id);
          } catch (msgErr) {
            console.error(`  Error processing message ${msgRef.id}:`, msgErr);
          }
        }
      } catch (routeErr) {
        console.error(`Error processing route ${route.id}:`, routeErr);
      }
    }

    return new Response(
      JSON.stringify({ processed: totalProcessed, routes: routes.length }),
      { headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("Fatal error in process-candidates:", err);
    return new Response(
      JSON.stringify({ error: err instanceof Error ? err.message : "Unknown error" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
