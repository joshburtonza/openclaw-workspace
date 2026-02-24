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

# ── DEPENDENCY ESCALATION CHECK ──────────────────────────────────────────────
# Signals monitored:
#   1. Email frequency increasing week-over-week
#   2. Scope expansion language in recent emails
#   3. Ownership language — client referring to system as 'our' tool/system
# When 2+ signals present → flag for morning brief + Telegram alert.
# Motivation: SMBs move from curiosity to dependency fast — a client seeking
# formal integration is no longer evaluating AI; they're operationally reliant.

SCOPE_EXPANSION_KWS = [
    'can you also', "while you're at it", 'in addition to', 'on top of that',
    'could you add', 'can we add', 'also add', 'also include', 'also want',
    'extend the scope', 'expand the scope', 'broaden', 'additional feature',
    'new feature', 'new requirement', 'new task', 'beyond what', 'beyond the',
    'outside the scope', 'outside of scope', 'add to the retainer',
    'include in the retainer', 'cover this too', 'handle this too',
    'take care of this as well', 'one more thing', 'small thing as well',
]

OUR_TOOL_KWS = [
    'our tool', 'our system', 'our agent', 'our ai', 'our automation',
    'our platform', 'our assistant', 'our bot', 'our software',
    'our solution', 'our technology', 'part of our workflow',
    'part of our process', 'part of our operations', 'part of our stack',
    'into our workflow', 'into our operations', 'into our business',
    'we rely on', 'we depend on', 'we use it as', 'we now use',
    'integrated into our', 'embedded in our',
]

one_week_ago  = (now - datetime.timedelta(days=7)).astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
two_weeks_ago = (now - datetime.timedelta(days=14)).astimezone(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

DEP_FLAG_FILE = '/Users/henryburton/.openclaw/workspace-anthropic/tmp/dependency-escalation-flags.txt'

# Clear stale flags
try:
    open(DEP_FLAG_FILE, 'w').close()
except Exception:
    pass

dep_escalation_flags = []

for client in clients:
    name = client['name']
    slug = client['slug']
    signals = []

    # Fetch recent 30-day emails once (reused across signals 2 & 3)
    try:
        recent_30d = supa(
            f"email_queue?client=eq.{slug}"
            f"&created_at=gte.{thirty_days_ago}"
            f"&select=subject,body,created_at"
        ) or []
    except Exception as e:
        print(f"  [warn] dep-escalation email fetch failed for {name}: {e}")
        recent_30d = []

    # Signal 1: Email frequency increasing week-over-week
    try:
        this_week_emails = supa(
            f"email_queue?client=eq.{slug}&created_at=gte.{one_week_ago}&select=id"
        ) or []
        last_week_emails = supa(
            f"email_queue?client=eq.{slug}"
            f"&created_at=gte.{two_weeks_ago}"
            f"&created_at=lt.{one_week_ago}"
            f"&select=id"
        ) or []
        tw = len(this_week_emails)
        lw = len(last_week_emails)
        if (lw > 0 and tw > lw) or (lw == 0 and tw >= 3):
            signals.append(f"email frequency up {lw}→{tw} this week vs last week")
    except Exception as e:
        print(f"  [warn] WoW frequency check failed for {name}: {e}")

    # Signal 2: Scope expansion language in recent emails
    try:
        scope_hits = sum(
            1 for e in recent_30d
            if any(
                kw in ((e.get('subject') or '') + ' ' + (e.get('body') or '')).lower()
                for kw in SCOPE_EXPANSION_KWS
            )
        )
        if scope_hits:
            signals.append(f"scope expansion language in {scope_hits} email(s) (last 30d)")
    except Exception as e:
        print(f"  [warn] scope expansion check failed for {name}: {e}")

    # Signal 3: Ownership language — 'our' tool/system references
    try:
        our_hits = sum(
            1 for e in recent_30d
            if any(
                kw in ((e.get('subject') or '') + ' ' + (e.get('body') or '')).lower()
                for kw in OUR_TOOL_KWS
            )
        )
        if our_hits:
            signals.append(f"ownership language ('our tool/system') in {our_hits} email(s) (last 30d)")
    except Exception as e:
        print(f"  [warn] ownership language check failed for {name}: {e}")

    if len(signals) >= 2:
        flag_msg = (
            f"[{name}] showing dependency escalation — review engagement terms and "
            f"consider repricing or restructuring before next billing cycle."
        )
        dep_escalation_flags.append({
            'client': name,
            'flag':   flag_msg,
            'signals': signals,
        })

if dep_escalation_flags:
    try:
        with open(DEP_FLAG_FILE, 'w') as fh:
            for item in dep_escalation_flags:
                fh.write(item['flag'] + '\n')
    except Exception as e:
        print(f"  [warn] could not write dep-escalation flags file: {e}")

    for item in dep_escalation_flags:
        sig_text = '; '.join(item['signals'])
        print(f"  [DEPENDENCY ESCALATION] {item['client']}: {sig_text}")
        tg(
            f"🔴 <b>[DEPENDENCY ESCALATION] {item['client']}</b>\n"
            f"{item['flag']}\n\n"
            f"<b>Signals ({len(item['signals'])}/3):</b> {sig_text}"
        )
else:
    print("No dependency escalation flags raised.")

# ── CALIBRATION-DUE CHECK ─────────────────────────────────────────────────────
# Reads data/clients.json for last_calibration_review + calibration_interval_days.
# If overdue, fires a Telegram alert to surface the need for an optimisation session.
# Motivation: parameter refinement sessions = recurring revenue; system must
# proactively surface when they're due rather than waiting for client complaints.

import pathlib

CLIENTS_JSON = pathlib.Path('/Users/henryburton/.openclaw/workspace-anthropic/data/clients.json')

if CLIENTS_JSON.exists():
    with open(CLIENTS_JSON) as fh:
        meta = json.load(fh)

    cal_entries = meta.get('clients', [])
    print(f"\nCalibration check — {len(cal_entries)} client(s) in metadata file.")

    for entry in cal_entries:
        cname    = entry.get('name', entry.get('slug', 'unknown'))
        interval = int(entry.get('calibration_interval_days') or 30)
        last_raw = entry.get('last_calibration_review')  # ISO date string or null

        if last_raw:
            last_dt = datetime.datetime.fromisoformat(last_raw).replace(
                tzinfo=datetime.timezone.utc
            )
            days_ago = (now.astimezone(datetime.timezone.utc) - last_dt).days
        else:
            days_ago = None  # never reviewed

        overdue = (days_ago is None) or (days_ago > interval)

        if overdue:
            if days_ago is None:
                detail = "never reviewed"
                n_days_str = "no review on record"
            else:
                detail = f"last reviewed {days_ago} days ago"
                n_days_str = f"AI parameters last reviewed {days_ago} days ago"

            print(f"  CALIBRATION DUE: {cname} — {detail} (interval: {interval}d)")
            tg(
                f"🔧 <b>CALIBRATION DUE: {cname}</b>\n"
                f"{n_days_str} — schedule optimisation session.\n\n"
                f"<i>Update <code>last_calibration_review</code> in data/clients.json after the session.</i>"
            )
        else:
            print(f"  Calibration OK: {cname} — reviewed {days_ago}d ago (next due in {interval - days_ago}d)")
else:
    print(f"  [warn] {CLIENTS_JSON} not found — skipping calibration check.")

# ── SCOPE TIER GUARD ──────────────────────────────────────────────────────────
# Detects service-business clients (workshop/detailing) whose scope log contains
# more distinct workflow categories than the configured threshold.
# Research insight: "detailing has multi-category services — pricing automation
# by workflow tier rather than flat retainer protects margin."
# Configure per-client via data/clients.json: service_client, workflow_categories,
# scope_creep_threshold (default 4).
# Flags are written to tmp/scope-creep-flags.txt for nightly-state output.

SCOPE_CREEP_THRESHOLD = 4
SCOPE_FLAG_FILE = pathlib.Path('/Users/henryburton/.openclaw/workspace-anthropic/tmp/scope-creep-flags.txt')

scope_creep_flags = []

if CLIENTS_JSON.exists():
    print(f"\nScope tier guard — checking {len(cal_entries)} client(s)...")

    for entry in cal_entries:
        if not entry.get('service_client'):
            continue

        categories = entry.get('workflow_categories') or []
        distinct_count = len(set(categories))
        threshold = int(entry.get('scope_creep_threshold') or SCOPE_CREEP_THRESHOLD)
        cname = entry.get('name', entry.get('slug', 'unknown'))
        slug = entry.get('slug', cname.lower().replace(' ', '_'))

        status_tag = 'SCOPE_CREEP_RISK' if distinct_count > threshold else 'scope_ok'
        flag_line = (
            f"{slug}: {status_tag} "
            f"({distinct_count} workflow categories, threshold {threshold})"
        )
        print(f"  [SCOPE TIER GUARD] {cname}: {distinct_count} categories "
              f"(threshold: {threshold}) → {status_tag}")

        if distinct_count > threshold:
            scope_creep_flags.append({
                'client': cname,
                'slug': slug,
                'count': distinct_count,
                'threshold': threshold,
                'flag': flag_line,
                'categories': sorted(set(categories)),
            })
else:
    print(f"  [warn] {CLIENTS_JSON} not found — skipping scope tier guard.")

# Write flag file (consumed by write-current-state.sh)
try:
    SCOPE_FLAG_FILE.parent.mkdir(parents=True, exist_ok=True)
    with open(SCOPE_FLAG_FILE, 'w') as fh:
        for item in scope_creep_flags:
            fh.write(item['flag'] + '\n')
except Exception as e:
    print(f"  [warn] could not write scope-creep flags file: {e}")

if scope_creep_flags:
    for item in scope_creep_flags:
        cats_str = ', '.join(item['categories'])
        print(f"  [SCOPE_CREEP_RISK] {item['client']}: {item['count']} workflow "
              f"categories: {cats_str}")
        tg(
            f"🟡 <b>[SCOPE_CREEP_RISK] {item['client']}</b>\n"
            f"{item['count']} active workflow categories detected "
            f"(threshold: {item['threshold']}).\n\n"
            f"<b>Categories:</b> {cats_str}\n\n"
            f"Consider pricing by workflow tier rather than flat retainer "
            f"to protect margin."
        )
else:
    print("No scope creep risk flags raised.")

# ── VERTICAL EXPANSION PITCH TRIGGER (QMS clients at 60+ days) ───────────────
# For clients tagged with QMS in their notes, once they cross 60 days on
# retainer, fire a Telegram nudge to Josh with the three adjacent verticals
# identified in the Ascend LC / Amalfi AI meeting research.
# Source: Meeting: Ascend LC / Amalfi AI

VERTICALS = [
    ("logistics/supply chain",   "goods-in and delivery exception NCRs"),
    ("professional services",    "ISO-certified engineering/consulting firms"),
    ("property/construction",    "snag lists and defect sign-offs"),
]

EXPANSION_NUDGE_FILE = pathlib.Path(
    '/Users/henryburton/.openclaw/workspace-anthropic/tmp/vertical-expansion-nudge.json'
)

# Load previous nudge timestamps to avoid re-firing within 30 days
nudge_history = {}
if EXPANSION_NUDGE_FILE.exists():
    try:
        nudge_history = json.loads(EXPANSION_NUDGE_FILE.read_text())
    except Exception:
        nudge_history = {}

nudge_fired = False

for client in clients:
    name = client['name']
    slug = client['slug']
    notes = (client.get('notes') or '').lower()

    # Only process QMS-tagged clients
    if 'qms' not in notes:
        continue

    # Determine days on retainer from earliest paid/invoiced income entry
    try:
        all_entries_for_client = supa(f"income_entries?client=eq.{name}&select=month,status")
        paid_entries_for_client = [
            e for e in (all_entries_for_client or [])
            if e.get('status') in ('paid', 'invoiced')
        ]
    except Exception as e:
        print(f"  [warn] vertical expansion: income lookup failed for {name}: {e}")
        continue

    if not paid_entries_for_client:
        print(f"  [vertical expansion] {name}: no paid entries found — skipping.")
        continue

    earliest_month = min(e['month'] for e in paid_entries_for_client)
    ey, em = map(int, earliest_month.split('-'))
    retainer_start = datetime.datetime(ey, em, 1, tzinfo=datetime.timezone.utc)
    days_on_retainer = (now.astimezone(datetime.timezone.utc) - retainer_start).days

    print(f"  [vertical expansion] {name}: {days_on_retainer} days on retainer (QMS-tagged)")

    if days_on_retainer < 60:
        print(f"    Not yet at 60 days — skipping vertical expansion nudge.")
        continue

    # Check if nudge was already sent recently (within 30 days)
    last_sent_iso = nudge_history.get(slug)
    if last_sent_iso:
        last_sent_dt = datetime.datetime.fromisoformat(last_sent_iso).replace(
            tzinfo=datetime.timezone.utc
        )
        days_since_last = (now.astimezone(datetime.timezone.utc) - last_sent_dt).days
        if days_since_last < 30:
            print(f"    Nudge already sent {days_since_last}d ago — skipping.")
            continue

    # Build the nudge message with all three verticals
    verticals_lines = '\n'.join(
        f"  {i+1}. <b>{v}</b> — {desc}"
        for i, (v, desc) in enumerate(VERTICALS)
    )
    pitch_template = (
        f"The QR\u2192form\u2192agent\u2192approval pipeline we built for <b>{name}</b> is "
        f"near-transferable to [vertical] \u2014 want me to draft a 3-sentence cold pitch?"
    )

    tg(
        f"\U0001f4c8 <b>VERTICAL EXPANSION TRIGGER \u2014 {name}</b>\n"
        f"{days_on_retainer} days on QMS retainer. Adjacent verticals ready to pitch:\n\n"
        f"{verticals_lines}\n\n"
        f"<b>Pitch template:</b>\n<i>{pitch_template}</i>"
    )

    nudge_history[slug] = now.astimezone(datetime.timezone.utc).isoformat()
    nudge_fired = True
    print(f"  [VERTICAL EXPANSION] Nudge sent for {name} ({days_on_retainer}d on retainer).")

# Persist nudge history
try:
    EXPANSION_NUDGE_FILE.parent.mkdir(parents=True, exist_ok=True)
    EXPANSION_NUDGE_FILE.write_text(json.dumps(nudge_history, indent=2))
except Exception as e:
    print(f"  [warn] could not write vertical expansion nudge history: {e}")

if not nudge_fired:
    print("No vertical expansion nudges fired.")

PY
