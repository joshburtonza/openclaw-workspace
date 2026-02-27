#!/usr/bin/env bash
# verify-leads.sh
# Bulk email verification for all leads.
#
# Mode 1 — MX only (free, no API key needed):
#   Checks if the domain has mail server records. Kills dead domains.
#   Marks: invalid (no MX) | unverified (MX exists, not deeply checked)
#
# Mode 2 — MX + ZeroBounce (accurate, ~$9 for 1,815 leads):
#   Add ZEROBOUNCE_API_KEY to .env.scheduler to enable.
#   Marks: valid | invalid | catch_all | risky | unverified
#
# Safe to re-run — skips leads already verified.
# Run time: ~5-10 min MX-only, ~15-20 min with ZeroBounce.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
ZB_KEY="${ZEROBOUNCE_API_KEY:-}"
LOG="$WS/out/verify-leads.log"

mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== Email verification run ==="
[[ -n "$ZB_KEY" ]] && log "Mode: MX + ZeroBounce" || log "Mode: MX only (add ZEROBOUNCE_API_KEY to .env.scheduler for full verification)"

export SUPABASE_URL SUPABASE_KEY ZB_KEY

python3 - <<'PY'
import os, sys, json, time, subprocess, urllib.request, urllib.error, urllib.parse

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['SUPABASE_KEY']
ZB_KEY       = os.environ.get('ZB_KEY', '')

# ── Supabase helpers ────────────────────────────────────────────────────────────

def supa_get(path):
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())

def supa_get_all(base_path):
    """Fetch all rows by paginating in chunks of 1000."""
    all_rows = []
    offset = 0
    chunk = 1000
    sep = '&' if '?' in base_path else '?'
    while True:
        rows = supa_get(f"{base_path}{sep}limit={chunk}&offset={offset}")
        all_rows.extend(rows)
        if len(rows) < chunk:
            break
        offset += chunk
    return all_rows

def supa_patch(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        method="PATCH",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read()

# ── MX check ───────────────────────────────────────────────────────────────────

mx_cache = {}  # domain → True/False/None

def has_mx(domain):
    """Check if domain has MX records using dig. Cached per domain."""
    if domain in mx_cache:
        return mx_cache[domain]
    try:
        result = subprocess.run(
            ['dig', '+short', '+time=3', '+tries=1', 'MX', domain],
            capture_output=True, text=True, timeout=5
        )
        has = bool(result.stdout.strip())
        mx_cache[domain] = has
        return has
    except Exception:
        mx_cache[domain] = None
        return None  # Unknown — don't mark invalid

# ── ZeroBounce API ─────────────────────────────────────────────────────────────

zb_cache = {}  # email → status

def zerobounce_verify(email):
    """
    Returns: valid | invalid | catch_all | risky | unverified
    ZeroBounce statuses: valid, invalid, catch-all, unknown, spamtrap, abuse, do_not_mail
    """
    if email in zb_cache:
        return zb_cache[email]
    try:
        url = (
            f"https://api.zerobounce.net/v2/validate"
            f"?api_key={ZB_KEY}&email={urllib.parse.quote(email)}&ip_address="
        )
        req = urllib.request.Request(url)
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.loads(r.read())

        status     = data.get('status', 'unknown').lower()
        sub_status = data.get('sub_status', '').lower()

        if status == 'valid':
            result = 'valid'
        elif status in ('invalid', 'spamtrap'):
            result = 'invalid'
        elif status == 'catch-all':
            result = 'catch_all'
        elif status in ('do_not_mail', 'abuse'):
            result = 'risky'
        elif sub_status in ('mailbox_not_found', 'no_dns_entries', 'failed_smtp_connection'):
            result = 'invalid'
        else:
            result = 'unverified'

        zb_cache[email] = result
        return result
    except Exception as e:
        print(f"    ZeroBounce error for {email}: {e}")
        zb_cache[email] = 'unverified'
        return 'unverified'

# ── Check ZeroBounce credits ───────────────────────────────────────────────────

if ZB_KEY:
    try:
        req = urllib.request.Request(
            f"https://api.zerobounce.net/v2/getcredits?api_key={ZB_KEY}"
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            credits_data = json.loads(r.read())
        credits = int(credits_data.get('Credits', 0))
        print(f"[zb] Credits available: {credits}")
        if credits <= 0:
            print("[zb] No credits — falling back to MX-only mode.")
            ZB_KEY = ''
    except Exception as e:
        print(f"[zb] Could not check credits: {e} — falling back to MX-only mode.")
        ZB_KEY = ''

# ── Fetch unverified leads ─────────────────────────────────────────────────────

print("[verify] Fetching leads with no email_status...")
leads = supa_get_all("leads?select=id,email&email_status=is.null&order=created_at.asc")
print(f"[verify] {len(leads)} leads to check")

if not leads:
    print("[verify] Nothing to do.")
    sys.exit(0)

# ── Verify ─────────────────────────────────────────────────────────────────────

results = {
    'valid':       [],
    'invalid':     [],
    'catch_all':   [],
    'risky':       [],
    'unverified':  [],
}

for i, lead in enumerate(leads):
    lid   = lead['id']
    email = (lead.get('email') or '').lower().strip()

    if not email or '@' not in email:
        results['invalid'].append(lid)
        continue

    domain = email.split('@')[1]

    # Step 1: MX check
    mx = has_mx(domain)
    if mx is False:
        # Definitely no mail server on this domain — dead
        results['invalid'].append(lid)
        if (i + 1) % 50 == 0 or mx is False:
            pass  # batch update happens below
        continue

    # Step 2: ZeroBounce (if key available and MX is ok/unknown)
    if ZB_KEY:
        status = zerobounce_verify(email)
        results[status].append(lid)
        time.sleep(0.05)  # ~20 req/sec, well within ZeroBounce limits
    else:
        # MX exists (or unknown) — mark unverified
        results['unverified'].append(lid)

    # Progress
    if (i + 1) % 100 == 0:
        total_done = sum(len(v) for v in results.values())
        print(f"[verify] {total_done}/{len(leads)} checked...")

# ── Batch update Supabase ──────────────────────────────────────────────────────

print("\n[verify] Updating Supabase...")
for status, ids in results.items():
    if not ids:
        continue
    # Update in chunks of 200 using `in` filter
    chunk_size = 200
    for j in range(0, len(ids), chunk_size):
        chunk = ids[j:j + chunk_size]
        id_list = '(' + ','.join(chunk) + ')'
        try:
            supa_patch(f"leads?id=in.{id_list}", {"email_status": status})
        except Exception as e:
            print(f"  [!] Patch failed for {status} chunk: {e}")
    print(f"  {status}: {len(ids)}")

# ── Summary ────────────────────────────────────────────────────────────────────

total = sum(len(v) for v in results.values())
print(f"\n[verify] Done. {total} leads verified.")
print(f"  valid:      {len(results['valid'])}")
print(f"  unverified: {len(results['unverified'])}")
print(f"  catch_all:  {len(results['catch_all'])}")
print(f"  risky:      {len(results['risky'])}")
print(f"  invalid:    {len(results['invalid'])}  ← will be skipped by Alex")

if results['invalid']:
    pct = round(len(results['invalid']) / total * 100)
    print(f"\n  {pct}% of leads had dead email addresses.")
PY
