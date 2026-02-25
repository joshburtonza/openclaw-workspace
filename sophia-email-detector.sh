#!/bin/bash
# sophia-email-detector.sh (v2)
#
# DETERMINISTIC pre-flight for the Sophia CSM cron.
# Owns ALL email detection AND queue insertion.
# The LLM receives only email_queue UUIDs — cannot hallucinate emails.
#
# Steps:
#   1. Search for unread client emails via gog gmail
#   2. For each thread: read content, extract metadata
#   3. INSERT into email_queue with gmail_thread_id
#      → gmail_thread_id UNIQUE constraint = DB-level hard dedup
#      → ON CONFLICT DO NOTHING (skips already-inserted threads)
#   4. Mark email as READ in Gmail (prevents re-detection)
#   5. Output JSON array of {id, from_email, subject} for LLM to draft
#      → If empty array: cron replies NO_REPLY and stops
#
# Usage: bash sophia-email-detector.sh
# Output: prints a JSON array to stdout (may be [])

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ACCOUNT="sophia@amalfiai.com"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

# Load service role key for INSERT (bypasses RLS)
ENV_FILE="$(dirname "$0")/.env.scheduler"
SERVICE_KEY=""
if [[ -f "$ENV_FILE" ]]; then
  SERVICE_KEY=$(grep '^SUPABASE_SERVICE_ROLE_KEY=' "$ENV_FILE" | cut -d= -f2- | tr -d '"' | tr -d "'")
fi
# Fall back to anon key if service key unavailable
INSERT_KEY="${SERVICE_KEY:-$ANON_KEY}"

# Addresses to exclude — only block addresses that would cause loops or noise.
# DO NOT exclude the whole amalfiai.com domain — alex@ is used for internal testing.
EXCLUDE_FILTER="-from:sophia@amalfiai.com -from:noreply -from:no-reply -from:mailer-daemon -from:postmaster"

# ── Step 1: search for emails ─────────────────────────────────────────────────
# PRIMARY: all unread emails in Sophia's inbox (any sender, external or internal test)
# Excludes internal Amalfi AI addresses and automated mailers.
RAW=$(gog gmail search "is:unread in:inbox $EXCLUDE_FILTER" --account "$ACCOUNT" --max 20 2>/dev/null || true)

# FALLBACK: last 2 days in inbox regardless of read status
# Catches emails opened on phone before cron ran.
# gmail_thread_id UNIQUE constraint + ON CONFLICT DO NOTHING prevents double-insertion.
RAW_RECENT=$(gog gmail search "in:inbox newer_than:2d $EXCLUDE_FILTER" --account "$ACCOUNT" --max 20 2>/dev/null || true)

# Merge: combine both results (dedup happens at DB level via gmail_thread_id)
if [[ -n "$RAW_RECENT" ]] && ! echo "$RAW_RECENT" | grep -qi "no results\|no messages\|0 results"; then
  RAW=$(printf '%s\n%s' "$RAW" "$RAW_RECENT")
fi

# No results at all
if [[ -z "$RAW" ]] || echo "$RAW" | grep -qi "no results\|no messages\|0 results"; then
  echo "[]"
  exit 0
fi

# ── Steps 2–5: process threads, insert into DB, mark as read ──────────────────
export RAW SUPABASE_URL INSERT_KEY ACCOUNT
python3 - <<'PY'
import json, os, subprocess, re, sys

RAW          = os.environ["RAW"]
SUPABASE_URL = os.environ["SUPABASE_URL"]
INSERT_KEY   = os.environ["INSERT_KEY"]
ACCOUNT      = os.environ["ACCOUNT"]

# Static fallback client map — keyed on sender address
STATIC_CLIENT_MAP = {
    "riaan@ascendlc.co.za":     "ascend_lc",
    "andre@ascendlc.co.za":     "ascend_lc",
    "rapizo92@gmail.com":        "favorite_logistics",
    # Internal test account — maps to ascend_lc for realistic AUTO-tier testing
    "alex@amalfiai.com":        "ascend_lc",
}

def build_client_map():
    """
    Build client map from Supabase leads table + static fallback.
    Maps email → client_slug (derived from company name if available).
    Any new lead added via /newlead will automatically be recognised.
    """
    import requests as _req, re as _re
    client_map = dict(STATIC_CLIENT_MAP)
    try:
        r = _req.get(
            "%s/rest/v1/leads?select=email,company,status&limit=200" % SUPABASE_URL,
            headers={'apikey': INSERT_KEY, 'Authorization': 'Bearer %s' % INSERT_KEY},
            timeout=10
        )
        if r.status_code == 200:
            for lead in r.json():
                email = (lead.get('email') or '').lower().strip()
                company = (lead.get('company') or '').strip()
                if not email:
                    continue
                # Derive a slug from company name, or use email domain
                if company:
                    slug = _re.sub(r'[^a-z0-9]+', '_', company.lower()).strip('_')
                else:
                    slug = email.split('@')[0]
                if email not in client_map:
                    client_map[email] = slug
    except Exception:
        pass  # fall back to static map on error
    return client_map

CLIENT_MAP = build_client_map()

def get_client_slug(raw_from):
    """Extract email address and map to client slug."""
    email = raw_from.lower().strip()
    m = re.search(r'<(.+?)>', email)
    if m:
        email = m.group(1).strip()
    for addr, slug in CLIENT_MAP.items():
        if addr in email:
            return slug
    return "new_contact"  # unknown = treat as new contact, not silently ignored

# ── Parse thread IDs ──────────────────────────────────────────────────────────
thread_ids = re.findall(r'thread_id:\s*(\S+)', RAW, re.IGNORECASE)
if not thread_ids:
    thread_ids = re.findall(r'\b([0-9a-f]{16,})\b', RAW)
thread_ids = list(dict.fromkeys(thread_ids))

if not thread_ids:
    print("[]")
    sys.exit(0)

def mark_read(thread_id):
    """Remove UNREAD label from Gmail thread."""
    subprocess.run([
        "gog", "gmail", "thread", "modify", thread_id,
        "--account", ACCOUNT,
        "--remove", "UNREAD",
        "--force",
    ], capture_output=True, text=True)

def supa_insert(payload):
    """
    Insert a row into email_queue.
    Uses resolution=ignore-duplicates so gmail_thread_id conflicts are silently skipped.
    Returns the inserted row dict, or None on conflict/error.
    """
    r = subprocess.run([
        "curl", "-s", "-X", "POST",
        "%s/rest/v1/email_queue" % SUPABASE_URL,
        "-H", "apikey: %s" % INSERT_KEY,
        "-H", "Authorization: Bearer %s" % INSERT_KEY,
        "-H", "Content-Type: application/json",
        "-H", "Prefer: return=representation,resolution=ignore-duplicates",
        "-d", json.dumps(payload, ensure_ascii=False),
    ], capture_output=True, text=True)
    try:
        data = json.loads(r.stdout)
        if isinstance(data, list) and data:
            return data[0]
    except Exception:
        pass
    return None

results = []
for tid in thread_ids:
    # Read full thread content
    read_out = subprocess.run([
        "gog", "gmail", "thread", "get", tid,
        "--account", ACCOUNT, "--plain",
    ], capture_output=True, text=True)
    thread_text = read_out.stdout.strip()

    if not thread_text:
        continue

    # Extract from_email and subject
    from_match    = re.search(r'^From:\s*(.+)',    thread_text, re.MULTILINE | re.IGNORECASE)
    subject_match = re.search(r'^Subject:\s*(.+)', thread_text, re.MULTILINE | re.IGNORECASE)
    from_email = from_match.group(1).strip()    if from_match    else ""
    subject    = subject_match.group(1).strip() if subject_match else ""

    if not from_email:
        continue

    # Strip quoted history to get latest reply only
    body = thread_text
    for sep in [r'\n_{5,}\n', r'\nOn .*wrote:\n', r'\n-----Original Message-----\n']:
        body = re.split(sep, body, maxsplit=1)[0]
    body = body.strip()

    client = get_client_slug(from_email)

    # ── Repricing / formalization signal detection ────────────────────────────
    # Catches clients probing for employment/absorption of Josh out of the agency model.
    # When a client tries to hire you, you've accidentally undersold yourself —
    # use it as a repricing event, not a career decision.
    REPRICING_KEYWORDS = [
        'full-time', 'full time', 'in-house', 'in house', 'employee',
        'integrate your team', 'bring you on board', 'bring you on',
        'hire you', 'hire', 'join us', 'exclusivity', 'salary', 'employment',
    ]
    search_text = (subject + ' ' + body).lower()
    repricing_signal = any(kw in search_text for kw in REPRICING_KEYWORDS)

    initial_analysis = {
        "formalization_signal": True,
        "repricing_trigger": True,
    } if repricing_signal else {}

    # INSERT — gmail_thread_id UNIQUE prevents double-insertion at the DB level.
    # If the thread was already inserted (e.g. from a previous run that crashed
    # before mark_read), supa_insert returns None and we still mark as read.
    insert_payload = {
        "gmail_thread_id": tid,
        "from_email":       from_email,
        "to_email":         "sophia@amalfiai.com",
        "subject":          subject,
        "body":             body,
        "client":           client,
        "status":           "pending",
    }
    if initial_analysis:
        insert_payload["analysis"] = initial_analysis
    row = supa_insert(insert_payload)

    # Always mark as read regardless of insert outcome
    mark_read(tid)

    if row is None:
        # Already in DB — skip from LLM queue (don't re-draft)
        continue

    results.append({
        "id":         row["id"],
        "from_email": from_email,
        "subject":    subject,
    })

# ── Step 6: also surface any existing pending rows in the DB ─────────────────
# Catches rows inserted via webhook, direct API, or tests that bypassed Gmail.
# Excludes loop addresses (sophia@ sending to herself etc).
LOOP_ADDRESSES = {'sophia@amalfiai.com', 'postmaster@amalfiai.com'}
import requests as _req
try:
    _r = _req.get(
        "%s/rest/v1/email_queue?status=eq.pending&select=id,from_email,subject&order=created_at.asc&limit=20" % SUPABASE_URL,
        headers={'apikey': INSERT_KEY, 'Authorization': 'Bearer %s' % INSERT_KEY},
        timeout=10
    )
    db_pending = _r.json() if _r.status_code == 200 else []
    # Filter out loop/internal-send addresses
    db_pending = [r for r in db_pending if r.get('from_email','').lower() not in LOOP_ADDRESSES]
except Exception:
    db_pending = []

seen_ids = {r['id'] for r in results}
for row in db_pending:
    if row.get('id') and row['id'] not in seen_ids:
        results.append({
            'id':         row['id'],
            'from_email': row.get('from_email', ''),
            'subject':    row.get('subject', ''),
        })
        seen_ids.add(row['id'])

print(json.dumps(results, ensure_ascii=False))
PY
