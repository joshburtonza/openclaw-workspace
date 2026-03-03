#!/usr/bin/env bash
# fnb-email-poller.sh
# Polls josh@amalfiai.com for FNB transaction notification emails.
# Handles:
#   - Forwarded emails from joshuaburton096@icloud.com (personal account)
#   - Direct emails from inContact@fnb.co.za (once set up on business account)
# Parses the "• FNB:-)" line from the email body, categorises each transaction,
# upserts into finance_transactions, and fires Telegram alerts.
# Runs every 10 minutes via LaunchAgent.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
SEEN_FILE="$WORKSPACE/tmp/fnb-emails-seen.txt"
LOG_TAG="[fnb-email-poller]"

[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
JOSH_CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
SALAH_CHAT_ID="${TELEGRAM_SALAH_CHAT_ID:-8597169445}"
LOW_BAL_THRESHOLD="${FNB_LOW_BALANCE_THRESHOLD:-5000}"

mkdir -p "$WORKSPACE/tmp"
touch "$SEEN_FILE"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $LOG_TAG Starting poll..."

# ── Fetch unread FNB emails (forwarded from iCloud + direct from FNB) ──────────
# GOG output is space-padded columns: ID  DATE  FROM  SUBJECT  LABELS  THREAD
# Use awk to extract the ID (col 1) and build a JSON array for Python

RAW_IDS_FILE=$(mktemp /tmp/fnb-ids-XXXXXX)

# Search forwarded from iCloud
gog gmail search --account josh@amalfiai.com "from:joshuaburton096@icloud.com FNB" 2>/dev/null \
  | awk 'NR>1 && $1 ~ /^[0-9a-f]{16}$/ {print $1}' >> "$RAW_IDS_FILE" || true

# Search direct from FNB (future)
gog gmail search --account josh@amalfiai.com "from:inContact@fnb.co.za" 2>/dev/null \
  | awk 'NR>1 && $1 ~ /^[0-9a-f]{16}$/ {print $1}' >> "$RAW_IDS_FILE" || true

# Deduplicate
UNIQUE_IDS=$(sort -u "$RAW_IDS_FILE")
rm -f "$RAW_IDS_FILE"

TOTAL=$(echo "$UNIQUE_IDS" | grep -c '[0-9a-f]' || echo 0)
echo "$LOG_TAG Found $TOTAL FNB email(s)"

if [[ "$TOTAL" -eq 0 ]]; then
  echo "$LOG_TAG Nothing to process."
  exit 0
fi

# Build JSON array of IDs for Python
EMAILS_JSON=$(echo "$UNIQUE_IDS" | python3 -c "
import json, sys
ids = [l.strip() for l in sys.stdin if l.strip()]
print(json.dumps([{'id': i, 'subject': ''} for i in ids]))
")

# ── Process each email ─────────────────────────────────────────────────────────
export EMAILS_JSON SEEN_FILE SUPABASE_URL SUPABASE_KEY BOT_TOKEN JOSH_CHAT_ID SALAH_CHAT_ID LOW_BAL_THRESHOLD WORKSPACE

python3 - <<'PY'
import os, json, re, subprocess, requests, datetime, sys, hashlib

ACCOUNT         = "josh@amalfiai.com"
EMAILS_JSON     = os.environ['EMAILS_JSON']
SEEN_FILE       = os.environ['SEEN_FILE']
SUPABASE_URL    = os.environ['SUPABASE_URL']
SUPABASE_KEY    = os.environ['SUPABASE_KEY']
BOT_TOKEN       = os.environ['BOT_TOKEN']
JOSH            = os.environ['JOSH_CHAT_ID']
SALAH           = os.environ['SALAH_CHAT_ID']
LOW_BAL         = float(os.environ.get('LOW_BAL_THRESHOLD', '5000'))

# Load seen IDs
with open(SEEN_FILE) as f:
    seen = set(l.strip() for l in f if l.strip())

emails = json.loads(EMAILS_JSON)

# ── Categorisation rules ───────────────────────────────────────────────────────
CLIENT_RULES = [
    (re.compile(r'ascend|ascend.?lc|riaan|andr[eé]', re.I), 'Ascend LC'),
    (re.compile(r'race.?teknik|race.?technik|farhaan', re.I), 'Race Technik'),
    (re.compile(r'favlog|supply.?chain', re.I), 'Favlog'),
    (re.compile(r'vanta', re.I), 'Vanta Studios'),
    (re.compile(r'invoice|retainer|amalfi', re.I), None),
]
SUB_RULES = [
    (re.compile(r'anthropic|claude', re.I), 'Claude Pro'),
    (re.compile(r'google|workspace', re.I), 'Google Workspace'),
    (re.compile(r'chatgpt|openai', re.I), 'ChatGPT Plus'),
    (re.compile(r'perplexity', re.I), 'Perplexity Pro'),
    (re.compile(r'supabase', re.I), 'Supabase'),
    (re.compile(r'lovable', re.I), 'Lovable'),
    (re.compile(r'hugging.?face', re.I), 'HuggingFace'),
    (re.compile(r'github', re.I), 'GitHub'),
    (re.compile(r'apple\.com|itunes|app.?store', re.I), 'Apple'),
    (re.compile(r'amazon|aws', re.I), 'AWS'),
    (re.compile(r'smartapp', re.I), 'Smartapp'),
    (re.compile(r'manus', re.I), 'Manus AI'),
    (re.compile(r'mentor', re.I), 'Mentor AI'),
    (re.compile(r'vercel|netlify', re.I), 'Vercel/Netlify'),
    (re.compile(r'digital.?ocean', re.I), 'DigitalOcean'),
    (re.compile(r'minimax', re.I), 'MiniMax'),
    (re.compile(r'notion', re.I), 'Notion'),
    (re.compile(r'adobe', re.I), 'Adobe'),
    (re.compile(r'metrofibre|metro.?fibre', re.I), 'MetroFibre'),
    (re.compile(r'dstv|multichoice', re.I), 'DStv'),
    (re.compile(r'netflix', re.I), 'Netflix'),
    (re.compile(r'spotify', re.I), 'Spotify'),
]
BANK_PAT     = re.compile(r'fnb fee|service fee|monthly fee|bank charge|ledger|sms fee|card fee', re.I)
DRAWING_PAT  = re.compile(r'henry.?burton|henryburton|sajonix|josh|atm|cash withdrawal', re.I)
DEBT_PAT     = re.compile(r'wesbank|wes.?bank|motus|bayport|absa.?home|standard.?bank.?home|nedbank.?home|rent|rates', re.I)
HARDWARE_PAT = re.compile(r'takealot|incredible|istore|apple store', re.I)
TAX_PAT      = re.compile(r'\bsars\b|revenue.?service', re.I)

def categorise(merchant, tx_type):
    if tx_type == 'income':
        for pat, client in CLIENT_RULES:
            if pat.search(merchant):
                return 'Income', client, None
        return 'Income', None, None
    # expense
    if DRAWING_PAT.search(merchant):  return 'Drawings',     None, None
    if DEBT_PAT.search(merchant):     return 'Debt Payment', None, None
    if TAX_PAT.search(merchant):      return 'Tax',          None, None
    if BANK_PAT.search(merchant):     return 'Bank Fees',    None, None
    if HARDWARE_PAT.search(merchant): return 'Hardware',     None, None
    for pat, sub in SUB_RULES:
        if pat.search(merchant):
            return 'Subscription', None, sub
    return 'Other', None, None

# ── Supabase helpers ───────────────────────────────────────────────────────────
SUPA_HEADERS = {
    'apikey': SUPABASE_KEY,
    'Authorization': f'Bearer {SUPABASE_KEY}',
    'Content-Type': 'application/json',
    'Prefer': 'resolution=merge-duplicates',
}

def upsert_tx(row):
    r = requests.post(
        f"{SUPABASE_URL}/rest/v1/finance_transactions",
        headers=SUPA_HEADERS,
        json=row, timeout=15
    )
    if r.status_code not in (200, 201):
        print(f"  Supabase error {r.status_code}: {r.text[:200]}", file=sys.stderr)
        return False
    return True

def tg(text, chat_ids):
    for cid in chat_ids:
        try:
            requests.post(
                f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
                json={'chat_id': cid, 'text': text, 'parse_mode': 'HTML'},
                timeout=10
            )
        except Exception as e:
            print(f"  TG error: {e}", file=sys.stderr)

def fmt(n): return f"R{abs(n):,.2f}"

def mark_read(msg_id):
    try:
        subprocess.run(
            ["gog", "gmail", "thread", "modify", msg_id,
             "--account", ACCOUNT, "--remove=UNREAD", "--force"],
            timeout=15, check=False, capture_output=True
        )
    except Exception as e:
        print(f"  mark-read error: {e}", file=sys.stderr)

# ── Parse FNB body line ────────────────────────────────────────────────────────
# Patterns:
#   • FNB:-) R783.40 reserved for purchase @ Manus Ai +65 from Premier a/c..597631 using card..5021. Avail R8575. 3Mar 14:17
#   • FNB:-) R902.00 paid from Premier a/c..597631 @ Smartapp. Avail R9358. Ref.Service. 3Mar 14:11
#   • FNB:-) R1234.56 received into Premier a/c..597631. Avail R9999. Ref.Payment. 3Mar 10:00
FNB_LINE = re.compile(r'FNB:-\)\s+R([\d,]+(?:\.\d+)?)\s+(.+?)(?:\.\s*(?:Avail|$)|$)')

def parse_fnb_line(line):
    # Extract amount
    amt_m = re.search(r'R([\d,]+(?:\.\d+)?)', line)
    if not amt_m: return None
    amount = float(amt_m.group(1).replace(',', ''))

    # Determine tx type and merchant
    tx_type = 'expense'
    merchant = ''
    reference = None

    if 'reserved for purchase' in line:
        # R{amt} reserved for purchase @ {merchant} from Premier a/c..{acct}
        m = re.search(r'reserved for purchase @ (.+?) from Premier', line)
        merchant = m.group(1).strip() if m else ''
    elif re.search(r'paid from Premier', line):
        # R{amt} paid from Premier a/c..{acct} @ {merchant}. Avail...
        m = re.search(r'paid from Premier a/c\.\.\d+ @ (.+?)(?:\. Avail|\. Ref|$)', line)
        merchant = m.group(1).strip() if m else ''
    elif re.search(r'received into Premier|credit', line, re.I):
        tx_type = 'income'
        m = re.search(r'(?:from|Ref\.)\s*([A-Za-z0-9 &\-]+?)(?:\.|Avail|$)', line)
        merchant = m.group(1).strip() if m else 'Unknown credit'
    else:
        # Fallback: anything after the amount
        rest = line[amt_m.end():].strip()
        merchant = rest.split('.')[0].strip()

    # Available balance
    bal_m = re.search(r'Avail R([\d,]+(?:\.\d+)?)', line)
    balance_after = float(bal_m.group(1).replace(',', '')) if bal_m else None

    # Reference
    ref_m = re.search(r'Ref\.(.+?)(?:\.|$)', line)
    reference = ref_m.group(1).strip() if ref_m else None

    # Account number
    acct_m = re.search(r'a/c\.\.(\d+)', line)
    account_suffix = acct_m.group(1) if acct_m else None

    return {
        'amount': amount,
        'type': tx_type,
        'merchant': merchant,
        'balance_after': balance_after,
        'reference': reference,
        'account_suffix': account_suffix,
    }

# ── Main processing loop ───────────────────────────────────────────────────────
SAST = datetime.timezone(datetime.timedelta(hours=2))
today = datetime.datetime.now(SAST).strftime('%Y-%m-%d')

new_seen = set()
client_payments = []
unknown_charges = []
low_bal_alert = None
processed = 0

for email in emails:
    msg_id = email['id']
    subject = email.get('subject', '')

    if msg_id in seen:
        continue

    # Fetch full email body
    try:
        body = subprocess.check_output(
            ["gog", "gmail", "get", msg_id, "--account", ACCOUNT],
            stderr=subprocess.DEVNULL, timeout=30, text=True
        )
    except Exception as e:
        print(f"  Failed to fetch {msg_id}: {e}", file=sys.stderr)
        continue

    # Extract the FNB transaction line
    fnb_line = None
    for line in body.splitlines():
        if 'FNB:-)' in line:
            fnb_line = line.strip().lstrip('•').strip()
            break

    if not fnb_line:
        # Try parsing from subject as fallback
        if 'FNB:-)' in subject:
            fnb_line = subject.replace('Fwd: ', '').strip()
        else:
            print(f"  No FNB line found in {msg_id}, skipping")
            new_seen.add(msg_id)
            continue

    parsed = parse_fnb_line(fnb_line)
    if not parsed:
        print(f"  Could not parse: {fnb_line[:80]}")
        new_seen.add(msg_id)
        continue

    # Extract date from email header
    date_str = today
    for line in body.splitlines():
        if line.startswith('date\t'):
            raw_date = line.split('\t', 1)[1].strip()
            try:
                # Parse "Tue, 3 Mar 2026 14:24:19 +0200"
                from email.utils import parsedate_to_datetime
                dt = parsedate_to_datetime(raw_date)
                date_str = dt.strftime('%Y-%m-%d')
            except Exception:
                pass
            break

    # Account type: personal (597631) vs business (different suffix)
    acct_suffix = parsed.get('account_suffix', '')
    account_type = 'personal'  # default; extend when business emails arrive

    merchant  = parsed['merchant']
    amount    = parsed['amount']
    tx_type   = parsed['type']
    bal_after = parsed['balance_after']
    reference = parsed['reference']

    category, matched_client, matched_sub = categorise(merchant, tx_type)

    # Stable dedup key = email message ID
    fnb_tx_id = f"email:{msg_id}"

    row = {
        'account_type':  account_type,
        'type':          tx_type,
        'amount':        amount,
        'description':   merchant,
        'category':      category,
        'date':          date_str,
        'reference':     reference,
        'balance_after': bal_after,
        'fnb_tx_id':     fnb_tx_id,
        'matched_client': matched_client,
        'matched_sub':    matched_sub,
    }

    ok = upsert_tx(row)
    if ok:
        print(f"  Upserted: {tx_type} {fmt(amount)} @ {merchant} [{category}]")
        processed += 1

        # Alert accumulators
        if tx_type == 'income' and matched_client:
            client_payments.append({'client': matched_client, 'amount': amount, 'date': date_str})
        if tx_type == 'expense' and category == 'Other':
            unknown_charges.append({'desc': merchant, 'amount': amount, 'date': date_str})
        if bal_after is not None and bal_after < LOW_BAL:
            low_bal_alert = {'balance': bal_after, 'account': acct_suffix}

    new_seen.add(msg_id)
    mark_read(msg_id)

# ── Alerts ─────────────────────────────────────────────────────────────────────
if low_bal_alert:
    tg(
        f"<b>Low Balance Warning</b>\n"
        f"FNB Personal (..{low_bal_alert['account']}): {fmt(low_bal_alert['balance'])} available\n"
        f"Threshold: {fmt(LOW_BAL)}",
        [JOSH]
    )

for p in client_payments:
    tg(
        f"<b>Payment Received</b>\n{p['client']}: {fmt(p['amount'])} on {p['date']}",
        [JOSH, SALAH]
    )

if unknown_charges:
    lines = '\n'.join(f"  {c['date']}: {fmt(c['amount'])} — {c['desc'][:50]}" for c in unknown_charges[:6])
    more  = f"\n  ...and {len(unknown_charges)-6} more" if len(unknown_charges) > 6 else ''
    tg(
        f"<b>Unknown Charges ({len(unknown_charges)})</b>\n{lines}{more}",
        [JOSH]
    )

# ── Save seen IDs ──────────────────────────────────────────────────────────────
all_seen = seen | new_seen
# Keep last 2000 IDs to avoid unbounded growth
all_seen_list = list(all_seen)[-2000:]
with open(SEEN_FILE, 'w') as f:
    f.write('\n'.join(all_seen_list) + '\n')

print(f"Done. Processed {processed} new transaction(s).")
PY
