import { NextRequest, NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

/**
 * GET /api/auth/callback?code=...&state=<base64-json>
 *
 * Called by Google after the user grants consent.
 * Steps:
 *   1. Exchange authorization code for {access_token, refresh_token}
 *   2. Fetch the user's Gmail address from Google userinfo
 *   3. Decode form data from the state parameter
 *   4. Look up vertical_id from vertical_templates
 *   5. Create organizations row
 *   6. Create org_gmail_tokens row
 *   7. Create inbound_email_routes row
 *   8. Redirect to /success?org=<slug>
 */

interface TokenResponse {
  access_token: string;
  refresh_token?: string;
  expires_in: number;
  scope: string;
  token_type: string;
}

interface GoogleUserInfo {
  email: string;
  name?: string;
  picture?: string;
}

interface StatePayload {
  companyName: string;
  vertical: string;
  contactName: string;
  contactEmail: string;
}

function slugify(text: string): string {
  return text
    .toLowerCase()
    .replace(/[^a-z0-9\s-]/g, "")
    .replace(/\s+/g, "-")
    .replace(/-+/g, "-")
    .replace(/^-|-$/g, "")
    .substring(0, 63); // Supabase slug length limit
}

function baseUrl(req: NextRequest): string {
  const proto = req.headers.get("x-forwarded-proto") ?? "https";
  const host = req.headers.get("host") ?? "localhost:3000";
  return `${proto}://${host}`;
}

export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const code = searchParams.get("code");
  const stateParam = searchParams.get("state");
  const errorParam = searchParams.get("error");

  const base = baseUrl(req);

  // User denied access or Google returned an error
  if (errorParam) {
    return NextResponse.redirect(
      `${base}/onboard?error=${encodeURIComponent(errorParam)}`,
    );
  }

  if (!code || !stateParam) {
    return NextResponse.redirect(`${base}/onboard?error=missing_params`);
  }

  // ---- 1. Exchange code for tokens ----
  const clientId = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID;
  const clientSecret = process.env.GOOGLE_CLIENT_SECRET;
  const redirectUri = process.env.GOOGLE_REDIRECT_URI;

  if (!clientId || !clientSecret || !redirectUri) {
    return NextResponse.json({ error: "Server misconfiguration" }, { status: 500 });
  }

  let tokenData: TokenResponse;
  try {
    const tokenRes = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectUri,
        grant_type: "authorization_code",
      }),
    });
    if (!tokenRes.ok) {
      const errText = await tokenRes.text();
      console.error("Token exchange failed:", errText);
      return NextResponse.redirect(`${base}/onboard?error=token_exchange_failed`);
    }
    tokenData = (await tokenRes.json()) as TokenResponse;
  } catch (err) {
    console.error("Token exchange exception:", err);
    return NextResponse.redirect(`${base}/onboard?error=token_exchange_failed`);
  }

  if (!tokenData.refresh_token) {
    // This happens if the user already granted access without re-consenting.
    // The prompt=consent param should prevent this, but guard just in case.
    return NextResponse.redirect(`${base}/onboard?error=no_refresh_token`);
  }

  // ---- 2. Fetch Gmail email address from userinfo ----
  let userInfo: GoogleUserInfo;
  try {
    const userRes = await fetch("https://www.googleapis.com/oauth2/v2/userinfo", {
      headers: { Authorization: `Bearer ${tokenData.access_token}` },
    });
    if (!userRes.ok) {
      const errText = await userRes.text();
      console.error("Userinfo fetch failed:", errText);
      return NextResponse.redirect(`${base}/onboard?error=userinfo_failed`);
    }
    userInfo = (await userRes.json()) as GoogleUserInfo;
  } catch (err) {
    console.error("Userinfo exception:", err);
    return NextResponse.redirect(`${base}/onboard?error=userinfo_failed`);
  }

  const gmailEmail = userInfo.email;
  if (!gmailEmail) {
    return NextResponse.redirect(`${base}/onboard?error=no_email`);
  }

  // ---- 3. Decode state payload ----
  let statePayload: StatePayload;
  try {
    const decoded = Buffer.from(stateParam, "base64").toString("utf-8");
    statePayload = JSON.parse(decoded) as StatePayload;
  } catch {
    return NextResponse.redirect(`${base}/onboard?error=invalid_state`);
  }

  const { companyName, vertical, contactName, contactEmail } = statePayload;
  if (!companyName || !vertical) {
    return NextResponse.redirect(`${base}/onboard?error=missing_form_data`);
  }

  // ---- 4. Supabase service-role client ----
  const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!supabaseUrl || !serviceRoleKey) {
    return NextResponse.json({ error: "Supabase not configured" }, { status: 500 });
  }

  const supabase = createClient(supabaseUrl, serviceRoleKey);

  // ---- 5. Look up vertical_id ----
  const { data: verticalTemplate, error: vtError } = await supabase
    .from("vertical_templates")
    .select("id")
    .eq("name", vertical)
    .single();

  if (vtError || !verticalTemplate) {
    console.error("Vertical lookup failed:", vtError);
    return NextResponse.redirect(`${base}/onboard?error=vertical_not_found`);
  }

  const verticalId: string = verticalTemplate.id as string;

  // ---- 6. Create organization ----
  const slug = slugify(companyName);
  const { data: org, error: orgError } = await supabase
    .from("organizations")
    .insert({
      name: companyName,
      slug,
      vertical_id: verticalId,
      contact_name: contactName,
      contact_email: contactEmail,
      onboarding_status: "active",
    })
    .select("id")
    .single();

  if (orgError || !org) {
    console.error("Organization insert failed:", orgError);
    // Slug collision? Try with a suffix
    if (orgError?.code === "23505") {
      return NextResponse.redirect(`${base}/onboard?error=company_already_exists`);
    }
    return NextResponse.redirect(`${base}/onboard?error=org_create_failed`);
  }

  const organizationId: string = org.id as string;

  // ---- 7. Create org_gmail_tokens row ----
  const tokenExpiresAt = new Date(Date.now() + tokenData.expires_in * 1000).toISOString();
  const scopes = tokenData.scope ? tokenData.scope.split(" ") : [];

  const { data: gmailToken, error: tokenError } = await supabase
    .from("org_gmail_tokens")
    .insert({
      organization_id: organizationId,
      gmail_email: gmailEmail,
      refresh_token: tokenData.refresh_token,
      access_token: tokenData.access_token,
      token_expires_at: tokenExpiresAt,
      scopes,
    })
    .select("id")
    .single();

  if (tokenError || !gmailToken) {
    console.error("Gmail token insert failed:", tokenError);
    return NextResponse.redirect(`${base}/onboard?error=token_save_failed`);
  }

  const gmailTokenId: string = gmailToken.id as string;

  // ---- 8. Create inbound_email_routes row ----
  // user_id defaults to organization_id (no auth user in this flow)
  const { error: routeError } = await supabase
    .from("inbound_email_routes")
    .insert({
      source_email: gmailEmail,
      organization_id: organizationId,
      user_id: organizationId,         // placeholder — org acts as the "user"
      gmail_token_id: gmailTokenId,
      inbox_tz_id: "Africa/Johannesburg",
      is_active: true,
    });

  if (routeError) {
    console.error("Route insert failed:", routeError);
    return NextResponse.redirect(`${base}/onboard?error=route_create_failed`);
  }

  // ---- 9. Redirect to success ----
  return NextResponse.redirect(`${base}/success?org=${encodeURIComponent(slug)}`);
}
