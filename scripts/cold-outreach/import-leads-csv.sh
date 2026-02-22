#!/usr/bin/env bash
# import-leads-csv.sh
# Import leads from a CSV file into the Supabase leads table.
#
# Usage:
#   bash import-leads-csv.sh /path/to/leads.csv
#   bash import-leads-csv.sh /path/to/leads.csv --source tiktok
#   bash import-leads-csv.sh /path/to/leads.csv --dry-run
#
# Accepted column names (case-insensitive, any order):
#   email, first_name / first / firstname, last_name / last / lastname,
#   company / business / org, website / url, notes, source, status
#
# Skips rows where email already exists (no duplicates).

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Load secrets from env file
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$(dirname "$0")/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

CSV_FILE="${1:-}"
EXTRA_SOURCE=""
DRY_RUN=false

# Parse flags
shift || true
while [[ $# -gt 0 ]]; do
  case "$1" in
    --source) EXTRA_SOURCE="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) shift ;;
  esac
done

if [[ -z "$CSV_FILE" || ! -f "$CSV_FILE" ]]; then
  echo "Usage: $0 <path-to-csv> [--source telegram|tiktok|referral|cold_list] [--dry-run]"
  exit 1
fi

export SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
export SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
export CSV_FILE DRY_RUN EXTRA_SOURCE

python3 - <<'PY'
import os, csv, json, re, requests, sys

URL      = os.environ['SUPABASE_URL']
KEY      = os.environ['SUPABASE_KEY']
CSV_FILE = os.environ['CSV_FILE']
DRY_RUN  = os.environ['DRY_RUN'] == 'true'
SOURCE   = os.environ.get('EXTRA_SOURCE', '') or 'cold_list'

def supa_post(body):
    r = requests.post(
        f"{URL}/rest/v1/leads",
        headers={
            'apikey': KEY,
            'Authorization': f'Bearer {KEY}',
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal',
        },
        json=body, timeout=20
    )
    return r.status_code, r.text

def normalise_col(name):
    """Map messy column names to canonical field names."""
    n = name.strip().lower().replace(' ', '_').replace('-', '_')
    if n in ('email', 'email_address', 'e_mail'):
        return 'email'
    if n in ('first_name', 'first', 'firstname', 'fname', 'given_name'):
        return 'first_name'
    if n in ('last_name', 'last', 'lastname', 'lname', 'surname', 'family_name'):
        return 'last_name'
    if n in ('company', 'business', 'organisation', 'organization', 'org', 'company_name'):
        return 'company'
    if n in ('website', 'url', 'web', 'site', 'domain'):
        return 'website'
    if n in ('notes', 'note', 'comment', 'comments', 'info'):
        return 'notes'
    if n in ('source', 'lead_source', 'origin'):
        return 'source'
    if n in ('status',):
        return 'status'
    if n in ('full_name', 'name', 'contact', 'contact_name'):
        return '_full_name'
    return None  # ignore

def split_full_name(name):
    parts = name.strip().split(None, 1)
    first = parts[0].capitalize() if parts else ''
    last  = parts[1].capitalize() if len(parts) > 1 else None
    return first, last

# Read CSV
with open(CSV_FILE, newline='', encoding='utf-8-sig') as f:
    reader = csv.DictReader(f)
    raw_rows = list(reader)

if not raw_rows:
    print("CSV is empty.")
    sys.exit(0)

print(f"Found {len(raw_rows)} rows. Columns: {list(raw_rows[0].keys())}")

# Map columns
col_map = {}
for col in raw_rows[0].keys():
    mapped = normalise_col(col)
    if mapped:
        col_map[col] = mapped

print(f"Column mapping: {col_map}")

# Fetch existing emails to skip dupes
existing_resp = requests.get(
    f"{URL}/rest/v1/leads?select=email",
    headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'},
    timeout=20
)
existing_emails = {r['email'].lower() for r in existing_resp.json()} if existing_resp.ok else set()
print(f"Existing leads in DB: {len(existing_emails)}")

inserted = skipped_dupe = skipped_invalid = 0
errors = []

for i, row in enumerate(raw_rows, 1):
    # Map fields
    mapped = {}
    for raw_col, canonical in col_map.items():
        val = row.get(raw_col, '').strip()
        if val:
            mapped[canonical] = val

    # Handle full_name → first_name + last_name
    if '_full_name' in mapped and 'first_name' not in mapped:
        first, last = split_full_name(mapped.pop('_full_name'))
        mapped['first_name'] = first
        if last:
            mapped['last_name'] = last
    else:
        mapped.pop('_full_name', None)

    # Validate email
    email = mapped.get('email', '').lower()
    if not email or not re.match(r'^[\w.+-]+@[\w-]+\.[a-z]{2,}$', email, re.I):
        print(f"  Row {i}: skipping — no valid email (got: {repr(mapped.get('email',''))})")
        skipped_invalid += 1
        continue

    # Skip duplicate
    if email in existing_emails:
        print(f"  Row {i}: skipping duplicate — {email}")
        skipped_dupe += 1
        continue

    # Build payload
    payload = {
        'email':      email,
        'first_name': mapped.get('first_name') or email.split('@')[0].capitalize(),
        'last_name':  mapped.get('last_name'),
        'company':    mapped.get('company'),
        'website':    mapped.get('website'),
        'notes':      mapped.get('notes'),
        'source':     mapped.get('source') or SOURCE,
        'status':     mapped.get('status') or 'new',
        'assigned_to': 'Josh',
    }
    # Remove None values
    payload = {k: v for k, v in payload.items() if v is not None}

    if DRY_RUN:
        print(f"  [DRY RUN] Would insert: {payload['email']} — {payload.get('first_name','')} {payload.get('last_name','')} @ {payload.get('company','')}")
        inserted += 1
        existing_emails.add(email)
        continue

    status_code, resp_text = supa_post(payload)
    if status_code in (200, 201, 204):
        print(f"  ✅ {email} ({payload.get('company','')})")
        inserted += 1
        existing_emails.add(email)
    elif status_code == 409 or 'unique' in resp_text.lower():
        print(f"  ⚠️  duplicate (race): {email}")
        skipped_dupe += 1
    else:
        print(f"  ❌ {email} — HTTP {status_code}: {resp_text[:100]}")
        errors.append(email)

print()
print("─" * 40)
if DRY_RUN:
    print(f"DRY RUN complete.")
    print(f"  Would insert:  {inserted}")
else:
    print(f"Import complete.")
    print(f"  Inserted:      {inserted}")
print(f"  Skipped dupes: {skipped_dupe}")
print(f"  Skipped invalid: {skipped_invalid}")
if errors:
    print(f"  Errors:        {len(errors)} — {errors}")
PY
