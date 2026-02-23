#!/usr/bin/env bash
# retainer-tracker.sh
# Runs on the 5th of each month.
# Checks income_entries for the current month — if an active client has no
# payment logged yet, queues a Sophia email draft + Telegram alert to Josh.

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Load secrets from env file
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$(dirname "$0")/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
_CHAT_ID_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/josh_private_chat_id"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-$(cat "$_CHAT_ID_FILE" 2>/dev/null || echo "1140320036")}"
SOPHIA_EMAIL="sophia@amalfiai.com"

export SUPABASE_URL SUPABASE_KEY BOT_TOKEN CHAT_ID SOPHIA_EMAIL

python3 - <<'PY'
import os, json, requests, datetime, sys

URL = os.environ['SUPABASE_URL']
KEY = os.environ['SUPABASE_KEY']
BOT = os.environ['BOT_TOKEN']
CHAT = os.environ['CHAT_ID']

def supa(path, method='GET', body=None, prefer=None):
    headers = {
        'apikey': KEY,
        'Authorization': f'Bearer {KEY}',
        'Content-Type': 'application/json',
    }
    if prefer:
        headers['Prefer'] = prefer
    base = f"{URL}/rest/v1/{path}"
    if method == 'GET':
        r = requests.get(base, headers=headers, timeout=20)
    elif method == 'POST':
        r = requests.post(base, headers=headers, json=body, timeout=20)
    r.raise_for_status()
    if method == 'GET':
        return r.json()
    return None

def tg(text):
    requests.post(
        f"https://api.telegram.org/bot{BOT}/sendMessage",
        json={'chat_id': CHAT, 'text': text, 'parse_mode': 'HTML'},
        timeout=10
    )

SAST = datetime.timezone(datetime.timedelta(hours=2))
now  = datetime.datetime.now(SAST)
month_key = now.strftime('%Y-%m')  # e.g. "2026-03"

print(f"Checking retainer payments for {month_key}...")

# Get active clients
clients = supa("clients?status=eq.active&select=id,name,slug,email_addresses,notes")
if not clients:
    print("No active clients found.")
    sys.exit(0)

# Get income entries for this month
entries = supa(f"income_entries?month=eq.{month_key}&select=client,amount,status")
paid_clients = {e['client'] for e in entries if e.get('status') in ('paid', 'invoiced')}

print(f"Active clients: {[c['name'] for c in clients]}")
print(f"Paid/invoiced this month: {paid_clients}")

missing = [c for c in clients if c['name'] not in paid_clients]

if not missing:
    print("All clients have payments logged. Nothing to chase.")
    sys.exit(0)

for client in missing:
    name = client['name']
    slug = client['slug']
    emails = client.get('email_addresses') or []
    to_email = emails[0] if emails else None

    print(f"  Missing payment: {name}")

    if not to_email:
        print(f"    No email on file for {name} — skipping email draft")
        tg(f"⚠️ <b>Retainer: {name}</b> has no payment logged for {month_key} and no email on file. Check manually.")
        continue

    # Build email draft
    subject = f"Quick note re: {month_key} invoice"
    body = (
        f"Hi there,\n\n"
        f"Just a friendly heads up that we have not yet received the retainer payment for {month_key}.\n\n"
        f"If you have already processed it, please ignore this. If not, whenever you get a chance would be great.\n\n"
        f"Let me know if you have any questions.\n\n"
        f"Warm regards,\nSophia\nAmalfi AI"
    )

    # Insert into email_queue as awaiting_approval
    row = {
        'from_email': os.environ['SOPHIA_EMAIL'],
        'to_email':   to_email,
        'subject':    subject,
        'body':       body,
        'client':     slug,
        'status':     'awaiting_approval',
        'requires_approval': True,
        'priority':   5,
        'analysis':   json.dumps({
            'intent': 'retainer_chase',
            'month':  month_key,
            'auto_generated': True,
        }),
    }
    supa('email_queue', 'POST', row, prefer='return=representation')

    # Send Telegram card for Josh to approve
    tg(
        f"💰 <b>Retainer chase: {name}</b>\n"
        f"No payment logged for {month_key}.\n\n"
        f"Draft email queued in Mission Control → Approvals.\n"
        f"Approve it to send the chase to <code>{to_email}</code>."
    )

print(f"Done. Missing payments: {[c['name'] for c in missing]}")

# ── INTERNALISATION RISK CHECK ──────────────────────────────────────────────

INTEGRATION_KEYWORDS = [
    'in-house', 'in house', 'bring it in', 'internal team', 'hire someone',
    'build internally', 'own the system', 'take over', 'our own developer',
    'train our', 'training our', 'documentation so we', 'handover',
    'hand over', 'self-sufficient', 'independent', 'build ourselves',
    'our developer', 'our team can', 'we can handle', 'no longer need',
    'manage it ourselves', 'keep it internal', 'reduce dependency',
]

thirty_days_ago = (now - datetime.timedelta(days=30)).astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
sixty_days_ago  = (now - datetime.timedelta(days=60)).astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

FLAG_MSG = (
    "[INTERNALISATION RISK] Client may be building internal dependency — "
    "review scope boundaries and consider proposing a structured retainer renewal "
    "that reinforces consultant positioning."
)

internalisation_flags = []

for client in clients:
    name = client['name']
    slug = client['slug']
    reasons = []

    # ── Trigger 1: 2+ emails with integration-pressure keywords in last 30 days
    try:
        recent_emails = supa(
            f"email_queue?client=eq.{slug}"
            f"&created_at=gte.{thirty_days_ago}"
            f"&select=subject,body,created_at"
        )
        keyword_hits = []
        for email in (recent_emails or []):
            text = ((email.get('subject') or '') + ' ' + (email.get('body') or '')).lower()
            if any(kw in text for kw in INTEGRATION_KEYWORDS):
                keyword_hits.append(email)
        if len(keyword_hits) >= 2:
            reasons.append(f"{len(keyword_hits)} emails with integration-pressure keywords in last 30 days")
    except Exception as e:
        print(f"  [warn] keyword check failed for {name}: {e}")

    # ── Trigger 2: month 4+ of retainer AND escalating request volume
    try:
        all_entries = supa(f"income_entries?client=eq.{name}&select=month,status")
        paid_entries = [e for e in (all_entries or []) if e.get('status') in ('paid', 'invoiced')]
        if paid_entries:
            earliest = min(e['month'] for e in paid_entries)
            ey, em = map(int, earliest.split('-'))
            ny, nm = now.year, now.month
            months_on_retainer = (ny - ey) * 12 + (nm - em)
            if months_on_retainer >= 4:
                recent_count = len(supa(
                    f"email_queue?client=eq.{slug}"
                    f"&created_at=gte.{thirty_days_ago}"
                    f"&select=id"
                ) or [])
                prior_count = len(supa(
                    f"email_queue?client=eq.{slug}"
                    f"&created_at=gte.{sixty_days_ago}"
                    f"&created_at=lt.{thirty_days_ago}"
                    f"&select=id"
                ) or [])
                if prior_count > 0 and recent_count > prior_count:
                    reasons.append(
                        f"month {months_on_retainer} of retainer with escalating volume "
                        f"({prior_count} → {recent_count} emails)"
                    )
    except Exception as e:
        print(f"  [warn] tenure/volume check failed for {name}: {e}")

    if reasons:
        internalisation_flags.append({'client': client, 'reasons': reasons})

# Emit internalisation risk flags
if internalisation_flags:
    for flag in internalisation_flags:
        fname = flag['client']['name']
        rsns  = '; '.join(flag['reasons'])
        print(f"  [INTERNALISATION RISK] {fname}: {rsns}")
        tg(
            f"🔶 <b>[INTERNALISATION RISK] {fname}</b>\n"
            f"{FLAG_MSG}\n\n"
            f"<b>Signals:</b> {rsns}"
        )
else:
    print("No internalisation risk flags raised.")

# ── CONCENTRATION RISK CHECK ─────────────────────────────────────────────────
# If any single client exceeds 50% of total retainer revenue, emit a warning.
# Signal designed to fire before a client drifts into dependency territory.

client_totals = {}
for e in entries:
    if e.get('status') in ('paid', 'invoiced'):
        client_name = e.get('client', '')
        amount = float(e.get('amount') or 0)
        if client_name:
            client_totals[client_name] = client_totals.get(client_name, 0) + amount

total_revenue = sum(client_totals.values())

if total_revenue > 0:
    concentration_flags = []
    for client_name, amount in client_totals.items():
        pct = amount / total_revenue * 100
        if pct > 50:
            slug = next(
                (c['slug'] for c in clients if c['name'] == client_name),
                client_name.lower().replace(' ', '_')
            )
            concentration_flags.append((slug, client_name, pct))

    if concentration_flags:
        for slug, client_name, pct in concentration_flags:
            warning = (
                f"⚠️ CONCENTRATION RISK: {slug} = {pct:.0f}% of retainer revenue "
                f"— portfolio resilience flag"
            )
            print(warning)
            tg(
                f"⚠️ <b>CONCENTRATION RISK</b>\n"
                f"<b>{client_name}</b> is <b>{pct:.0f}%</b> of tracked retainer revenue for {month_key}.\n\n"
                f"Portfolio resilience flag — revenue diversification over depth-of-engagement. "
                f"Consider whether this client is drifting into dependency territory."
            )
    else:
        print("Concentration check passed — no single client exceeds 50% of retainer revenue.")
else:
    print("No retainer revenue recorded this month — skipping concentration check.")
PY
