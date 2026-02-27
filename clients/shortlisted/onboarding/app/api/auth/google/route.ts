import { NextRequest, NextResponse } from "next/server";

/**
 * GET /api/auth/google?state=<base64-json>
 *
 * Redirects the browser to Google's OAuth consent screen.
 * The `state` param carries the onboarding form data (company name,
 * vertical, contact info) encoded as base64 JSON so it survives the
 * round-trip through Google's servers.
 */
export async function GET(req: NextRequest) {
  const { searchParams } = new URL(req.url);
  const state = searchParams.get("state") ?? "";

  const clientId = process.env.NEXT_PUBLIC_GOOGLE_CLIENT_ID;
  const redirectUri = process.env.GOOGLE_REDIRECT_URI;

  if (!clientId || !redirectUri) {
    return NextResponse.json(
      { error: "Google OAuth is not configured" },
      { status: 500 },
    );
  }

  const scopes = [
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "openid",
  ];

  const params = new URLSearchParams({
    client_id: clientId,
    redirect_uri: redirectUri,
    response_type: "code",
    scope: scopes.join(" "),
    access_type: "offline",   // request refresh_token
    prompt: "consent",        // always show consent to ensure refresh_token is returned
    state,
  });

  const googleAuthUrl = `https://accounts.google.com/o/oauth2/v2/auth?${params.toString()}`;

  return NextResponse.redirect(googleAuthUrl);
}
