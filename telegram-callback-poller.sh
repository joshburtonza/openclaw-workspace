#!/bin/bash
# telegram-callback-poller.sh
# Continuous long-polling service for Telegram updates:
#   - Inline button callbacks (approve/hold/adjust email drafts)
#   - Text commands:
#       /newlead [first] [last] <email> [company]  → insert into leads table
#       /ooo [reason]                               → set Sophia OOO mode
#       /available                                  → clear Sophia OOO mode
#       /remind <time> <desc>                       → set a timed reminder
# Keeps state in a stable file (NOT /tmp — that resets between isolated sessions).
# Runs as a KeepAlive LaunchAgent — loops internally via long-polling (timeout=25s).

set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# ── Pidfile guard: only one instance at a time ────────────────────────────────
PIDFILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/telegram-poller.pid"
mkdir -p "$(dirname "$PIDFILE")"
if [[ -f "$PIDFILE" ]]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null || true)
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "Poller already running (pid $OLD_PID), exiting." >&2
    exit 0
  fi
fi
echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"; exit 0' EXIT INT TERM

# Load secrets from env file
ENV_FILE="/Users/henryburton/.openclaw/workspace-anthropic/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
ANON_KEY="${SUPABASE_ANON_KEY:-}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"

# Use workspace dir so offset survives between restarts
OFFSET_FILE="/Users/henryburton/.openclaw/workspace-anthropic/tmp/telegram_updates_offset"
mkdir -p "$(dirname "$OFFSET_FILE")"

JOSH_BOT_USERNAME="${JOSH_BOT_USERNAME:-JoshAmalfiBot}"
DEEPGRAM_API_KEY="${DEEPGRAM_API_KEY:-}"
TG_API="https://api.telegram.org/bot${BOT_TOKEN}"

# ── Continuous long-polling loop ──────────────────────────────────────────────
while true; do

  # Read current offset each iteration (Python updates it after processing)
  OFFSET=""
  if [[ -f "$OFFSET_FILE" ]]; then
    OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || true)
  fi

  # Long-poll: timeout=25 — server holds connection until update arrives or 25s passes
  URL="${TG_API}/getUpdates?timeout=25&allowed_updates=message,callback_query"
  if [[ -n "$OFFSET" ]]; then
    URL+="&offset=${OFFSET}"
  fi

  # --max-time 35 gives a 10s buffer beyond the server's 25s hold
  RESP=$(curl -s --max-time 35 "$URL") || RESP=""

  if [[ -z "$RESP" ]]; then
    sleep 5
    continue
  fi

  # Skip malformed JSON (e.g. from SIGTERM mid-curl)
  if ! echo "$RESP" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    sleep 2
    continue
  fi

  # ── Check for errors before touching Python ───────────────────────────────
  ERR_CODE=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error_code',0))" 2>/dev/null || echo "0")
  IS_OK=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print('yes' if d.get('ok') else 'no')" 2>/dev/null || echo "no")

  if [[ "$IS_OK" != "yes" ]]; then
    if [[ "$ERR_CODE" == "409" ]]; then
      # Another instance is polling — back off and let it finish
      sleep 10
    else
      echo "getUpdates error $ERR_CODE: $(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('description','unknown'))" 2>/dev/null)" >&2
      sleep 5
    fi
    continue
  fi

  # ── Write raw updates to disk immediately — never lose a message ───────────
  RAW_LOG="/Users/henryburton/.openclaw/workspace-anthropic/out/telegram-raw-updates.jsonl"
  echo "$RESP" >> "$RAW_LOG"

  export RESP OFFSET_FILE BOT_TOKEN SUPABASE_URL ANON_KEY SERVICE_KEY JOSH_BOT_USERNAME DEEPGRAM_API_KEY

  python3 - <<'PY' || true
import json, os, subprocess, sys, re
import requests

resp=json.loads(os.environ.get('RESP','{}'))
if not resp.get('ok'):
    err_code = resp.get('error_code', 0)
    print(f"Telegram getUpdates not ok [{err_code}]: {resp.get('description','unknown')}", file=sys.stderr)
    sys.exit(0)

updates=resp.get('result', [])
if not updates:
    sys.exit(0)

max_update_id=None

WS_ROOT = '/Users/henryburton/.openclaw/workspace-anthropic'
os.makedirs(f"{WS_ROOT}/tmp", exist_ok=True)
os.makedirs(f"{WS_ROOT}/out", exist_ok=True)
GATEWAY_ERR_LOG = f"{WS_ROOT}/out/gateway-errors.log"

# Clean up temp media files older than 3 days on each poller start
import glob, time as _time
_cutoff = _time.time() - (3 * 86400)
for _f in glob.glob(f"{WS_ROOT}/tmp/tg-photo-*") + glob.glob(f"{WS_ROOT}/tmp/tg-doc-*") + glob.glob(f"{WS_ROOT}/tmp/tg-video-thumb-*"):
    try:
        if os.path.getmtime(_f) < _cutoff:
            os.remove(_f)
    except Exception:
        pass

SUPABASE_URL     = os.environ['SUPABASE_URL']
ANON_KEY         = os.environ['ANON_KEY']
SERVICE_KEY      = os.environ['SERVICE_KEY']
BOT_TOKEN        = os.environ['BOT_TOKEN']
SALAH_CHAT_ID    = os.environ.get('TELEGRAM_SALAH_CHAT_ID', '')

def tg_send(chat_id, text):
    try:
        requests.post(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            json={'chat_id': chat_id, 'text': text, 'parse_mode': 'HTML'},
            timeout=10
        )
    except Exception:
        pass

def supa_patch_anon(path, body):
    subprocess.run([
        'curl','-s','-X','PATCH',
        f"{SUPABASE_URL}/rest/v1/{path}",
        '-H',f"apikey: {ANON_KEY}",
        '-H',f"Authorization: Bearer {ANON_KEY}",
        '-H','Content-Type: application/json',
        '-H','Prefer: return=minimal',
        '-d',json.dumps(body)
    ], stdout=subprocess.DEVNULL)

def supa_post_service(path, body):
    r = requests.post(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={
            'apikey': SERVICE_KEY,
            'Authorization': f'Bearer {SERVICE_KEY}',
            'Content-Type': 'application/json',
            'Prefer': 'return=minimal',
        },
        json=body, timeout=15
    )
    return r.status_code, r.text

def log_signal(actor, user_id, signal_type, signal_data=None):
    """Write a typed interaction signal to interaction_log for memory-writer to process."""
    try:
        requests.post(
            f"{SUPABASE_URL}/rest/v1/interaction_log",
            headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                     'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
            json={'actor': actor, 'user_id': user_id,
                  'signal_type': signal_type, 'signal_data': signal_data or {}},
            timeout=5
        )
    except Exception:
        pass  # never block the main flow

# ── Handle /newlead command ───────────────────────────────────────────────────
def handle_newlead(chat_id, text):
    """
    Formats accepted:
      /newlead John Smith john@example.com Acme Corp
      /newlead john@example.com Acme Corp
      /newlead John john@example.com
    """
    # Strip the command
    raw = re.sub(r'^/newlead\s*', '', text, flags=re.IGNORECASE).strip()
    if not raw:
        tg_send(chat_id,
            "📋 <b>Add a lead:</b>\n"
            "<code>/newlead FirstName LastName email@example.com Company Name</code>\n\n"
            "Examples:\n"
            "• /newlead Marcus Smith marcus@gallery.com The Gallery\n"
            "• /newlead sarah@startup.co Startup Inc"
        )
        return

    # Extract email
    email_match = re.search(r'[\w.+-]+@[\w-]+\.[a-z]{2,}', raw, re.IGNORECASE)
    if not email_match:
        tg_send(chat_id, "❌ No valid email found. Include an email address.")
        return

    email = email_match.group(0).lower()
    rest  = raw.replace(email, '').strip()

    # Split remaining words into name parts + company
    words = rest.split()
    first_name = words[0].capitalize() if words else 'Unknown'
    last_name  = words[1].capitalize() if len(words) > 1 else None
    company    = ' '.join(words[2:]) if len(words) > 2 else None

    # If only one word before email and it looks like a company, treat it as company
    if company is None and last_name and not re.match(r'^[A-Z][a-z]+$', last_name):
        company = last_name
        last_name = None

    payload = {
        'first_name': first_name,
        'last_name':  last_name,
        'email':      email,
        'company':    company,
        'source':     'telegram',
        'status':     'new',
        'assigned_to': 'Josh',
    }

    status_code, resp_text = supa_post_service('leads', payload)

    if status_code in (200, 201, 204):
        name_display = ' '.join(filter(None, [first_name, last_name]))
        tg_send(chat_id,
            f"✅ <b>Lead added!</b>\n"
            f"<b>{name_display}</b> @ {company or 'unknown company'}\n"
            f"<code>{email}</code>\n\n"
            f"Visible in Mission Control → Content → Cold Outreach."
        )
    elif status_code == 409 or 'unique' in resp_text.lower():
        tg_send(chat_id, f"⚠️ Lead with email <code>{email}</code> already exists.")
    else:
        tg_send(chat_id, f"❌ Failed to add lead (HTTP {status_code}). Check logs.")

# ── Handle /ooo command ───────────────────────────────────────────────────────
def handle_ooo(chat_id, text):
    reason = re.sub(r'^/ooo\s*', '', text, flags=re.IGNORECASE).strip()
    if not reason:
        reason = "OOO — no reason specified"
    result = subprocess.run(
        ['bash',
         '/Users/henryburton/.openclaw/workspace-anthropic/scripts/sophia-ooo-set.sh',
         'set', reason],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        tg_send(chat_id, f"⏸ <b>OOO mode ON</b>\nReason: {reason}\n\nSophia is holding all drafts.")
    else:
        tg_send(chat_id, f"❌ Failed to set OOO: {result.stderr[:200]}")

# ── Voice mode helpers ────────────────────────────────────────────────────────
def get_reply_mode(chat_id):
    """Return 'audio' if voice mode is on for this chat, else 'text'."""
    flag = f"{WS_ROOT}/tmp/voice-mode-{chat_id}"
    return 'audio' if os.path.exists(flag) else 'text'

def handle_voice_toggle(chat_id):
    flag = f"{WS_ROOT}/tmp/voice-mode-{chat_id}"
    if os.path.exists(flag):
        os.remove(flag)
        tg_send(chat_id, "🔇 Voice mode <b>OFF</b> — back to text replies.")
    else:
        open(flag, 'w').close()
        tg_send(chat_id, "🔊 Voice mode <b>ON</b> — I'll reply with audio.\n\nSend <code>/voice</code> again to switch back to text.")

# ── Handle /available command ─────────────────────────────────────────────────
def handle_available(chat_id):
    result = subprocess.run(
        ['bash',
         '/Users/henryburton/.openclaw/workspace-anthropic/scripts/sophia-ooo-set.sh',
         'clear'],
        capture_output=True, text=True, timeout=30
    )
    if result.returncode == 0:
        tg_send(chat_id, "✅ <b>OOO mode OFF</b>\nSophia is back to normal operations.")
    else:
        tg_send(chat_id, f"❌ Failed to clear OOO: {result.stderr[:200]}")

# ── Handle /agents command ────────────────────────────────────────────────────
def handle_agents(chat_id, text):
    """
    /agents                → show all agents with enabled/disabled status
    /agents enable sophia  → enable Sophia
    /agents disable sophia → disable Sophia
    """
    AGENT_KEYS = {
        'sophia':          ('agent_enabled_sophia',       'Sophia CSM'),
        'alex':            ('agent_enabled_alex',         'Alex Outreach'),
        'task_worker':     ('agent_enabled_task_worker',  'Task Worker'),
        'meet':            ('agent_enabled_meet_intel',   'Meet Intel'),
        'morning':         ('agent_enabled_morning_brief','Morning Brief'),
        'research':        ('agent_enabled_research_digest','Research Digest'),
        'monitor':         ('agent_enabled_monitor',      'System Monitor'),
    }

    parts = text.strip().split()
    action = parts[1].lower() if len(parts) > 1 else 'list'
    target = parts[2].lower() if len(parts) > 2 else ''

    if action in ('enable', 'disable'):
        if not target:
            tg_send(chat_id, "Usage: /agents enable <name> or /agents disable <name>\nNames: " + ', '.join(AGENT_KEYS.keys()))
            return
        matched = None
        for slug, (config_key, display) in AGENT_KEYS.items():
            if target in slug or slug.startswith(target):
                matched = (slug, config_key, display)
                break
        if not matched:
            tg_send(chat_id, f"Unknown agent: {target}\nOptions: {', '.join(AGENT_KEYS.keys())}")
            return
        slug, config_key, display = matched
        new_val = 'true' if action == 'enable' else 'false'
        try:
            resp = requests.post(
                f"{SUPABASE_URL}/rest/v1/system_config",
                headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                         'Content-Type': 'application/json',
                         'Prefer': 'resolution=merge-duplicates,return=minimal'},
                json={'key': config_key, 'value': new_val}, timeout=10
            )
            icon = '✅' if action == 'enable' else '⏸'
            tg_send(chat_id, f"{icon} <b>{display} {action}d</b>\nTakes effect within 5 minutes.")
        except Exception as e:
            tg_send(chat_id, f"❌ Failed: {e}")
        return

    # Default: list all agents with status
    try:
        resp = requests.get(
            f"{SUPABASE_URL}/rest/v1/system_config?key=like.agent_enabled_*&select=key,value",
            headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}, timeout=10
        )
        rows = {r['key']: r['value'] for r in (resp.json() if resp.ok else [])}
    except Exception:
        rows = {}

    lines = ['<b>Agent Status</b>\n']
    for slug, (config_key, display) in AGENT_KEYS.items():
        val = rows.get(config_key, 'true')
        try: enabled = json.loads(val)
        except Exception: enabled = (val != 'false')
        icon = '🟢' if enabled else '🔴'
        lines.append(f"{icon} <b>{display}</b>")

    lines.append('\n<i>Toggle: /agents enable sophia</i>')
    lines.append('<i>or: /agents disable alex</i>')
    tg_send(chat_id, '\n'.join(lines))

# ── Handle /debt command ──────────────────────────────────────────────────────
def handle_debt(chat_id, text):
    """
    /debt                              → show summary
    /debt Name TotalAmount [Remaining] [Monthly]
    Example: /debt Bond 850000 820000 9200
    """
    import re as _re
    raw = _re.sub(r'^/debt\s*', '', text, flags=_re.IGNORECASE).strip()

    if not raw:
        try:
            resp = requests.get(
                f"{SUPABASE_URL}/rest/v1/debt_entries?select=name,total_amount,remaining_amount,monthly_payment&order=remaining_amount.desc",
                headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}, timeout=10
            )
            rows = resp.json()
        except Exception:
            rows = []
        if not rows:
            tg_send(chat_id,
                "📊 <b>Debt Tracker</b>\n\nNo entries yet.\n\n"
                "Add one:\n<code>/debt Name TotalAmount Remaining Monthly</code>\n"
                "Example: <code>/debt Bond 850000 820000 9200</code>"
            )
            return
        total_rem     = sum(r.get('remaining_amount', 0) for r in rows)
        total_monthly = sum(r.get('monthly_payment', 0) for r in rows)
        lines = []
        for r in rows:
            rem  = r.get('remaining_amount', 0)
            tot  = r.get('total_amount', 1) or 1
            pct  = round((1 - rem/tot) * 100)
            mths = round(rem / r['monthly_payment']) if r.get('monthly_payment', 0) > 0 else None
            bar  = '█' * (pct // 10) + '░' * (10 - pct // 10)
            eta  = f" · {mths}mo left" if mths else ''
            lines.append(
                f"<b>{r['name']}</b>\n"
                f"R{rem:,.0f} remaining · R{r.get('monthly_payment',0):,.0f}/mo{eta}\n"
                f"<code>{bar}</code> {pct}%"
            )
        tg_send(chat_id,
            "📊 <b>Debt Summary</b>\n\n" + "\n\n".join(lines) +
            f"\n\n<b>Total: R{total_rem:,.0f}</b> · R{total_monthly:,.0f}/mo obligation"
        )
        return

    parts = _re.split(r'\s+', raw)
    numbers, name_parts = [], []
    for p in parts:
        clean = p.replace(',','').replace('R','').replace('r','').strip('"\'')
        try:
            numbers.append(float(clean))
        except ValueError:
            if not numbers:
                name_parts.append(p.strip('"\''))

    name = ' '.join(name_parts) if name_parts else 'Unnamed debt'
    if not numbers:
        tg_send(chat_id, "❌ Include at least the total amount.\nExample: <code>/debt Bond 850000 820000 9200</code>")
        return

    total_amt     = numbers[0]
    remaining_amt = numbers[1] if len(numbers) > 1 else total_amt
    monthly_pay   = numbers[2] if len(numbers) > 2 else 0

    try:
        r = requests.post(
            f"{SUPABASE_URL}/rest/v1/debt_entries",
            headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                     'Content-Type': 'application/json', 'Prefer': 'return=representation'},
            json={'name': name, 'total_amount': total_amt,
                  'remaining_amount': remaining_amt, 'monthly_payment': monthly_pay},
            timeout=10
        )
        if r.status_code in (200, 201):
            mths = round(remaining_amt / monthly_pay) if monthly_pay > 0 else None
            eta  = f" · paid off in ~{mths} months" if mths else ''
            tg_send(chat_id,
                f"✅ <b>{name}</b> added\n"
                f"Total: R{total_amt:,.0f} · Remaining: R{remaining_amt:,.0f}\n"
                f"Monthly: R{monthly_pay:,.0f}{eta}\n\nView all: <code>/debt</code>"
            )
        else:
            tg_send(chat_id, f"❌ Failed to save (HTTP {r.status_code})")
    except Exception as e:
        tg_send(chat_id, f"❌ Error: {e}")

# ── Handle /finances command ───────────────────────────────────────────────────
def handle_finances(chat_id):
    """Quick P&L snapshot: current month income + debt obligations."""
    import datetime as _dt
    now = _dt.datetime.now(_dt.timezone(_dt.timedelta(hours=2)))
    this_month = now.strftime('%Y-%m')
    try:
        inc_resp  = requests.get(
            f"{SUPABASE_URL}/rest/v1/income_entries?month=eq.{this_month}&select=client,amount,status",
            headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}, timeout=10
        )
        debt_resp = requests.get(
            f"{SUPABASE_URL}/rest/v1/debt_entries?select=name,remaining_amount,monthly_payment",
            headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}, timeout=10
        )
        income_rows = inc_resp.json() if inc_resp.ok else []
        debt_rows   = debt_resp.json() if debt_resp.ok else []
    except Exception:
        income_rows, debt_rows = [], []

    collected      = sum(r['amount'] for r in income_rows if r.get('status') == 'paid')
    outstanding    = sum(r['amount'] for r in income_rows if r.get('status') != 'paid')
    total_debt_rem = sum(r.get('remaining_amount', 0) for r in debt_rows)
    total_monthly  = sum(r.get('monthly_payment', 0) for r in debt_rows)
    net  = collected - total_monthly
    sign = '+' if net >= 0 else ''
    msg  = (
        f"💰 <b>Finances — {now.strftime('%B %Y')}</b>\n\n"
        f"<b>Income</b>\n"
        f"  Collected:    R{collected:,.0f}\n"
        f"  Outstanding:  R{outstanding:,.0f}\n\n"
        f"<b>Debt</b>\n"
        f"  Monthly payments: R{total_monthly:,.0f}\n"
        f"  Total remaining:  R{total_debt_rem:,.0f}\n\n"
        f"<b>Net (collected minus obligations): {sign}R{net:,.0f}</b>"
    )
    if not income_rows and not debt_rows:
        msg += "\n\n<i>No data yet. Add debts with /debt, income entries via Mission Control.</i>"
    tg_send(chat_id, msg)

# ── Handle /log command (NLU-powered) ────────────────────────────────────────
def handle_log_transaction(chat_id, text):
    """
    NLU finance logger. Accepts natural language:
      /log just got 20k from Ascend
      /log paid FNB card 9500
      /log vanta paid their 5500 retainer
      /log expense 1200 cursor sub
    Claude extracts type/amount/category/description, then we confirm with inline buttons.
    """
    import datetime as _dt, tempfile as _tf, os as _os, subprocess as _sp, json as _json

    raw = text[4:].strip()  # strip "/log"
    if not raw:
        tg_send(chat_id,
            "Just describe the transaction naturally:\n"
            "<code>/log just got paid 20k from Ascend</code>\n"
            "<code>/log paid FNB card R9500</code>\n"
            "<code>/log Vanta paid their 5500 retainer</code>"
        )
        return

    today = _dt.date.today().isoformat()
    extract_prompt = f"""Extract a financial transaction from this message. Reply ONLY with valid JSON, no explanation.

Message: "{raw}"
Today's date: {today}

JSON schema:
{{
  "type": "income" or "expense",
  "amount": number (ZAR, no currency symbol),
  "category": string or null  (income: client name; expense: Debt Payment/Business Sub/Personal Sub/Drawings/Business Expense/Personal Expense/Other),
  "description": string or null (short description of the transaction),
  "date": "YYYY-MM-DD"
}}

Rules:
- If the message mentions receiving money, a payment received, retainer paid, invoice settled → type = "income"
- If it mentions paying, spending, debt payment, subscription, expense → type = "expense"
- Extract the amount as a plain number (e.g. "20k" = 20000, "R9,500" = 9500)
- date defaults to today ({today}) unless a specific date is mentioned"""

    tmp = _tf.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, prefix='/tmp/fin-extract-')
    tmp.write(extract_prompt)
    tmp.close()

    try:
        env = _os.environ.copy()
        env['UNSET_CLAUDECODE'] = '1'
        result = _sp.run(
            ['bash', '-c', f'unset CLAUDECODE && claude --print --model claude-haiku-4-5-20251001 < {tmp.name}'],
            capture_output=True, text=True, timeout=30, env=env
        )
        raw_json = result.stdout.strip()
        # Strip markdown code fences if present
        if raw_json.startswith('```'):
            raw_json = '\n'.join(raw_json.split('\n')[1:])
            raw_json = raw_json.rstrip('`').strip()
        tx = _json.loads(raw_json)
    except Exception as ex:
        tg_send(chat_id, f"Couldn't parse that — try: <code>/log income 20000 Ascend LC March retainer</code>\n<i>({ex})</i>")
        return
    finally:
        try: _os.unlink(tmp.name)
        except: pass

    tx_type = tx.get('type', 'expense')
    amount  = float(tx.get('amount', 0))
    cat     = tx.get('category') or ''
    desc    = tx.get('description') or ''
    date    = tx.get('date', today)

    if amount <= 0:
        tg_send(chat_id, "Couldn't extract an amount. Try: <code>/log income 20000 Ascend LC</code>")
        return

    # Store pending transaction in temp file, keyed by chat_id
    pending_file = f"/Users/henryburton/.openclaw/workspace-anthropic/tmp/fin_pending_{chat_id}.json"
    pending = {'type': tx_type, 'amount': amount, 'category': cat or None, 'description': desc or None, 'date': date}
    with open(pending_file, 'w') as f:
        _json.dump(pending, f)

    sign  = '+' if tx_type == 'income' else '-'
    emoji = '' if tx_type == 'income' else ''
    label = desc or cat or tx_type
    try:
        requests.post(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            json={
                'chat_id':    chat_id,
                'parse_mode': 'HTML',
                'text': (
                    f"{emoji} <b>Got it — confirm this?</b>\n\n"
                    f"Type:   <b>{tx_type.capitalize()}</b>\n"
                    f"Amount: <b>{sign}R{amount:,.0f}</b>\n"
                    f"{'Category: ' + cat + chr(10) if cat else ''}"
                    f"{'Description: ' + desc + chr(10) if desc else ''}"
                    f"Date:   <b>{date}</b>"
                ),
                'reply_markup': {'inline_keyboard': [[
                    {'text': ' Confirm', 'callback_data': f'fin_confirm:{chat_id}'},
                    {'text': ' Cancel',  'callback_data': f'fin_cancel:{chat_id}'},
                ]]},
            },
            timeout=10
        )
    except Exception as ex:
        tg_send(chat_id, f"Error sending confirmation: {ex}")

# ── Handle /remind command ────────────────────────────────────────────────────
def handle_remind(chat_id, text, user_profile='josh'):
    """
    Formats:
      /remind 30min Call Riaan
      /remind 1h Send invoice
      /remind 3pm Team sync
      /remind 15:30 Review PR
      /remind tomorrow 9am Send weekly report
    """
    import datetime as _dt, re as _re

    raw = _re.sub(r'^/remind\s*', '', text, flags=_re.IGNORECASE).strip()
    if not raw:
        tg_send(chat_id,
            "⏰ <b>Set a reminder:</b>\n\n"
            "/remind 30min Description\n"
            "/remind 2h Description\n"
            "/remind 3pm Description\n"
            "/remind 15:30 Description\n"
            "/remind tomorrow 9am Description"
        )
        return

    SAST = _dt.timezone(_dt.timedelta(hours=2))
    now  = _dt.datetime.now(SAST)
    due  = None
    desc = raw

    # Pattern: Xmin text
    m = _re.match(r'^(\d+)\s*(?:min(?:ute)?s?|m)\s+(.+)$', raw, _re.IGNORECASE)
    if m:
        due  = now + _dt.timedelta(minutes=int(m.group(1)))
        desc = m.group(2).strip()

    # Pattern: Xh / X hours text
    if not due:
        m = _re.match(r'^(\d+)\s*(?:hour(?:s)?|h(?:r)?)\s+(.+)$', raw, _re.IGNORECASE)
        if m:
            due  = now + _dt.timedelta(hours=int(m.group(1)))
            desc = m.group(2).strip()

    # Pattern: HH:MM text  or  H:MM text
    if not due:
        m = _re.match(r'^(\d{1,2}):(\d{2})\s+(.+)$', raw)
        if m:
            hour, minute, rest = int(m.group(1)), int(m.group(2)), m.group(3)
            due = now.replace(hour=hour, minute=minute, second=0, microsecond=0)
            if due <= now:
                due += _dt.timedelta(days=1)
            desc = rest.strip()

    # Pattern: Ham/pm or Hpm text  (e.g. 3pm, 9am, 10pm)
    if not due:
        m = _re.match(r'^(\d{1,2})\s*(am|pm)\s+(.+)$', raw, _re.IGNORECASE)
        if m:
            hour, ampm, rest = int(m.group(1)), m.group(2).lower(), m.group(3)
            if ampm == 'pm' and hour != 12:
                hour += 12
            elif ampm == 'am' and hour == 12:
                hour = 0
            due = now.replace(hour=hour, minute=0, second=0, microsecond=0)
            if due <= now:
                due += _dt.timedelta(days=1)
            desc = rest.strip()

    # Pattern: tomorrow HAM/PM text  or  tomorrow HH:MM text
    if not due:
        m = _re.match(r'^tomorrow\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+(.+)$', raw, _re.IGNORECASE)
        if m:
            hour, minute = int(m.group(1)), int(m.group(2) or 0)
            ampm, rest   = m.group(3), m.group(4)
            if ampm:
                if ampm.lower() == 'pm' and hour != 12: hour += 12
                elif ampm.lower() == 'am' and hour == 12: hour = 0
            tmrw = now + _dt.timedelta(days=1)
            due  = tmrw.replace(hour=hour, minute=minute, second=0, microsecond=0)
            desc = rest.strip()

    # Pattern: <dayname> HAM/PM text  or  <dayname> HH:MM text  (e.g. "friday 10am Call Riaan")
    if not due:
        DAYS = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday']
        m = _re.match(
            r'^(' + '|'.join(DAYS) + r')\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+(.+)$',
            raw, _re.IGNORECASE
        )
        if m:
            day_name = m.group(1).lower()
            hour     = int(m.group(2))
            minute   = int(m.group(3) or 0)
            ampm     = m.group(4)
            desc     = m.group(5).strip()
            if ampm:
                if ampm.lower() == 'pm' and hour != 12: hour += 12
                elif ampm.lower() == 'am' and hour == 12: hour = 0
            target = DAYS.index(day_name)
            diff   = (target - now.weekday()) % 7 or 7  # always in future
            target_date = (now + _dt.timedelta(days=diff)).date()
            due = _dt.datetime(target_date.year, target_date.month, target_date.day,
                               hour, minute, 0, tzinfo=SAST)

    if not due:
        tg_send(chat_id,
            f"❌ Couldn't parse the time from: <code>{raw[:80]}</code>\n\n"
            "Try: /remind 30min Call Riaan\n"
            "Or:  /remind 3pm Team sync"
        )
        return

    # Insert into Supabase notifications — scoped to the requesting user
    owner = 'Salah' if user_profile == 'salah' else 'Josh'
    payload = {
        'type':     'reminder',
        'title':    desc,
        'status':   'unread',
        'priority': 'normal',
        'agent':    owner,
        'metadata': {'due': due.isoformat(), 'user': user_profile},
    }
    try:
        r = requests.post(
            f"{SUPABASE_URL}/rest/v1/notifications",
            headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                     'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
            json=payload, timeout=15
        )
        if r.status_code in (200, 201, 204):
            if due.date() == now.date():
                due_display = due.strftime('%H:%M SAST')
            else:
                due_display = due.strftime('%a %d %b, %H:%M SAST')
            tg_send(chat_id, f'✅ Reminder set: <b>{desc}</b>\n⏰ {due_display}')
        else:
            tg_send(chat_id, f'❌ Failed to save reminder (HTTP {r.status_code})')
    except Exception as e:
        tg_send(chat_id, f'❌ Error saving reminder: {e}')

# ── Handle /meet command ──────────────────────────────────────────────────────
def handle_meet(chat_id, text):
    """
    Formats accepted (flexible NLP):
      /meet tomorrow 10am Favlog kickoff ozayr@ambassadex.co.za farhaan@gmail.com
      /meet friday 2pm Race Technik sync farhaan.surtie@gmail.com
      /meet 2026-03-05 09:00 Onboarding call client@example.com
    Emails (contain @) are separated from title words automatically.
    Default duration: 1 hour. Timezone: SAST (UTC+2).
    """
    import datetime as _dt, re as _re, json as _json

    raw = _re.sub(r'^/meet\s*', '', text, flags=_re.IGNORECASE).strip()
    if not raw:
        tg_send(chat_id,
            "\U0001f4c5 <b>Schedule a Google Meet:</b>\n\n"
            "/meet tomorrow 10am Favlog kickoff ozayr@example.com\n"
            "/meet friday 2pm Race Technik sync farhaan@gmail.com\n"
            "/meet 2026-03-05 09:00 Onboarding call client@example.com\n\n"
            "Emails (containing @) are auto-detected. Everything else becomes the title."
        )
        return

    SAST = _dt.timezone(_dt.timedelta(hours=2))
    now  = _dt.datetime.now(SAST)
    due  = None
    rest = raw  # remaining text after datetime is parsed out

    # ── Pattern: YYYY-MM-DD HH:MM ────────────────────────────────────────────
    m = _re.match(r'^(\d{4}-\d{2}-\d{2})\s+(\d{1,2}):(\d{2})\s+(.*)$', raw, _re.IGNORECASE)
    if m:
        try:
            d = _dt.date.fromisoformat(m.group(1))
            due = _dt.datetime(d.year, d.month, d.day,
                               int(m.group(2)), int(m.group(3)), 0, tzinfo=SAST)
            rest = m.group(4).strip()
        except ValueError:
            pass

    # ── Pattern: YYYY-MM-DD HAM/PM ────────────────────────────────────────────
    if not due:
        m = _re.match(r'^(\d{4}-\d{2}-\d{2})\s+(\d{1,2})\s*(am|pm)\s+(.*)$', raw, _re.IGNORECASE)
        if m:
            try:
                d    = _dt.date.fromisoformat(m.group(1))
                hour = int(m.group(2))
                ampm = m.group(3).lower()
                if ampm == 'pm' and hour != 12: hour += 12
                elif ampm == 'am' and hour == 12: hour = 0
                due  = _dt.datetime(d.year, d.month, d.day, hour, 0, 0, tzinfo=SAST)
                rest = m.group(4).strip()
            except ValueError:
                pass

    # ── Pattern: tomorrow HH:MM or tomorrow HAM/PM ───────────────────────────
    if not due:
        m = _re.match(r'^tomorrow\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+(.*)$', raw, _re.IGNORECASE)
        if m:
            hour   = int(m.group(1))
            minute = int(m.group(2) or 0)
            ampm   = m.group(3)
            if ampm:
                if ampm.lower() == 'pm' and hour != 12: hour += 12
                elif ampm.lower() == 'am' and hour == 12: hour = 0
            tmrw = now + _dt.timedelta(days=1)
            due  = tmrw.replace(hour=hour, minute=minute, second=0, microsecond=0)
            rest = m.group(4).strip()

    # ── Pattern: <dayname> HH:MM or <dayname> HAM/PM ─────────────────────────
    if not due:
        DAYS = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday']
        m = _re.match(
            r'^(' + '|'.join(DAYS) + r')\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s+(.*)$',
            raw, _re.IGNORECASE
        )
        if m:
            day_name = m.group(1).lower()
            hour     = int(m.group(2))
            minute   = int(m.group(3) or 0)
            ampm     = m.group(4)
            if ampm:
                if ampm.lower() == 'pm' and hour != 12: hour += 12
                elif ampm.lower() == 'am' and hour == 12: hour = 0
            target      = DAYS.index(day_name)
            diff        = (target - now.weekday()) % 7 or 7
            target_date = (now + _dt.timedelta(days=diff)).date()
            due  = _dt.datetime(target_date.year, target_date.month, target_date.day,
                                hour, minute, 0, tzinfo=SAST)
            rest = m.group(5).strip()

    if not due:
        tg_send(chat_id,
            f"\u274c Couldn't parse a date/time from: <code>{raw[:80]}</code>\n\n"
            "Try:\n"
            "/meet tomorrow 10am Title attendee@email.com\n"
            "/meet friday 2pm Title attendee@email.com\n"
            "/meet 2026-03-05 09:00 Title attendee@email.com"
        )
        return

    # ── Split remainder into emails vs title words ────────────────────────────
    words  = rest.split()
    emails = [w for w in words if _re.search(r'@', w)]
    title_words = [w for w in words if not _re.search(r'@', w)]
    title = ' '.join(title_words).strip() or 'Meeting'

    if not emails:
        tg_send(chat_id,
            "\u274c No attendee email found.\n\n"
            "Include at least one email address in the command:\n"
            "/meet tomorrow 10am Title client@example.com"
        )
        return

    # ── Build RFC3339 timestamps (SAST = UTC+2) ───────────────────────────────
    end  = due + _dt.timedelta(hours=1)
    fmt  = '%Y-%m-%dT%H:%M:%S+02:00'
    start_rfc = due.strftime(fmt)
    end_rfc   = end.strftime(fmt)
    emails_csv = ','.join(emails)

    # ── Call gog calendar create ──────────────────────────────────────────────
    gog_cmd = [
        '/opt/homebrew/bin/gog', 'calendar', 'create', 'josh@amalfiai.com',
        '--account', 'josh@amalfiai.com',
        '--summary', title,
        '--from',    start_rfc,
        '--to',      end_rfc,
        '--attendees', emails_csv,
        '--with-meet',
        '--json',
        '--results-only',
    ]
    try:
        gog_env = dict(os.environ)
        gog_env['PATH'] = '/opt/homebrew/bin:/usr/local/bin:' + gog_env.get('PATH', '')
        gog_result = subprocess.run(
            gog_cmd,
            capture_output=True, text=True, timeout=30,
            env=gog_env
        )
        gog_stdout = gog_result.stdout.strip()
        gog_stderr = gog_result.stderr.strip()
    except Exception as e:
        tg_send(chat_id,
            f"\u274c Calendar create failed: {e}\n"
            "Try: calendar.google.com"
        )
        return

    if not gog_stdout:
        err_snippet = gog_stderr[:200] if gog_stderr else 'no output'
        tg_send(chat_id,
            f"\u274c Calendar create failed: {err_snippet}\n"
            "Try: calendar.google.com"
        )
        return

    # ── Parse JSON for Meet link and event ID ─────────────────────────────────
    meet_link = ''
    event_id  = ''
    try:
        cal_data = _json.loads(gog_stdout)
        # gog may return the event directly or nested under 'event'
        event_obj = cal_data if 'id' in cal_data else cal_data.get('event', cal_data)
        event_id  = event_obj.get('id', '')
        entry_points = (
            event_obj
            .get('conferenceData', {})
            .get('entryPoints', [])
        )
        for ep in entry_points:
            if ep.get('entryPointType') == 'video':
                meet_link = ep.get('uri', '')
                break
        if not meet_link:
            # Fallback: look for hangoutLink at top level
            meet_link = event_obj.get('hangoutLink', '')
    except Exception:
        pass

    if not meet_link:
        err_snippet = gog_stderr[:200] if gog_stderr else gog_stdout[:200]
        tg_send(chat_id,
            f"\u274c Calendar create failed: {err_snippet}\n"
            "Try: calendar.google.com"
        )
        return

    # ── Format confirmation message ───────────────────────────────────────────
    day_str  = due.strftime('%A')
    date_str = due.strftime('%-d %b %Y')
    time_str = due.strftime('%H:%M')
    attendees_display = '\n'.join(f"  {e}" for e in emails)

    confirm_msg = (
        f"\u2705 <b>Meet created: {title}</b>\n"
        f"\U0001f4c5 {day_str} {date_str} at {time_str} SAST\n"
        f"\U0001f517 {meet_link}\n"
        f"\U0001f465 {emails_csv}\n\n"
        f"Reply <b>send meet invite</b> to get a draft Sophia invite email."
    )
    tg_send(chat_id, confirm_msg)

    # ── Persist pending meet details for "send meet invite" follow-up ─────────
    pending_meet = {
        'title':      title,
        'start':      start_rfc,
        'end':        end_rfc,
        'meet_link':  meet_link,
        'event_id':   event_id,
        'attendees':  emails,
        'day':        day_str,
        'date':       date_str,
        'time':       time_str,
    }
    pending_file = f"{WS_ROOT}/tmp/pending-meet-{chat_id}.json"
    try:
        with open(pending_file, 'w') as pf:
            _json.dump(pending_meet, pf)
    except Exception:
        pass

# ── Handle research: command ──────────────────────────────────────────────────
def handle_research(chat_id, text):
    """
    Saves research transcripts/URLs to research/inbox/ for the digest agent.

    Formats accepted:
      research: My Source Title\nFull transcript or content here...
      research: https://www.youtube.com/watch?v=...
      research: (shows usage)
    """
    import datetime as _dt, os as _os

    raw = re.sub(r'^research:\s*', '', text, flags=re.IGNORECASE).strip()
    if not raw:
        tg_send(chat_id,
            "📚 <b>Drop research to process:</b>\n\n"
            "<code>research: Source Title\nPaste transcript here...</code>\n\n"
            "Or for a URL:\n"
            "<code>research: Source Title\nhttps://youtube.com/watch?v=...</code>\n\n"
            "Processed within 30 min. Results in <i>Mission Control → Research</i>."
        )
        return

    lines = raw.split('\n', 1)
    title   = lines[0].strip()
    content = lines[1].strip() if len(lines) > 1 else ''

    # Single-line URL or bare content — use generic title
    if not content:
        content = title
        title   = f"Telegram drop {_dt.datetime.now().strftime('%Y-%m-%d %H:%M')}"

    if len(content) < 20 and not content.startswith('http'):
        tg_send(chat_id,
            "⚠️ Content too short — paste the full transcript after the title line.\n\n"
            "<code>research: Title\nFull content here...</code>"
        )
        return

    slug     = re.sub(r'[^a-z0-9]+', '-', title.lower())[:60].strip('-')
    ts       = _dt.datetime.now().strftime('%Y%m%d-%H%M%S')
    filename = f"{ts}-{slug}.txt"
    inbox    = f"{WS}/research/inbox"
    filepath = f"{inbox}/{filename}"

    try:
        _os.makedirs(inbox, exist_ok=True)
        with open(filepath, 'w') as f:
            f.write(content)
        tg_send(chat_id,
            f"📚 <b>Research queued:</b> {title}\n"
            f"Saved to inbox — processed within 30 min.\n"
            f"Check <i>Mission Control → Research</i> for insights."
        )
    except Exception as e:
        tg_send(chat_id, f"❌ Failed to save research: {e}")

# ── Handle /help command ──────────────────────────────────────────────────────
def handle_help(chat_id):
    tg_send(chat_id,
        "<b>Amalfi AI — Claude Code</b>\n\n"
        "💬 <b>Just chat</b> — type anything, Claude will respond\n"
        "Examples:\n"
        "• \"What emails are pending approval?\"\n"
        "• \"Draft a follow-up for Riaan\"\n"
        "• \"Set me as OOO tomorrow\"\n"
        "• \"What did we push to QMS Guard this week?\"\n\n"
        "📋 <b>Commands</b>\n"
        "/remind 30min Description — set a reminder\n"
        "/remind 3pm Description\n"
        "/remind tomorrow 9am Description\n"
        "/meet tomorrow 10am Title attendee@email.com\n"
        "/meet friday 2pm Title email1@co.com email2@co.com\n"
        "/newlead [Name] email@co.com [Company]\n"
        "/ooo [reason] — Sophia holds all drafts\n"
        "/calibrate new — onboard a new client for Sophia\n"
        "/calibrate list — list all configured clients\n"
        "/agents — view/toggle active agents\n"
        "/enrich — run Apollo+Hunter+Apify enrichment on pending leads\n"
        "/enrich email@co.com — verify a single email\n"
        "/available — Resume normal ops\n"
        "/finances — P&L snapshot\n"
        "/log income 20000 Ascend LC March retainer\n"
        "/log expense 9500 Debt Payment FNB CC\n"
        "research: Title\\nContent — queue research for digest\n\n"
        "✅ <b>Email approvals</b> — tap the buttons on cards"
    )

# ── Main loop ─────────────────────────────────────────────────────────────────
for u in updates:
    uid = u.get('update_id')
    if uid is not None:
        max_update_id = max(max_update_id or uid, uid)
    uid_str = str(uid) if uid is not None else __import__('time').strftime('%Y%m%d%H%M%S')

    # ── Callback query (button taps) ──────────────────────────────────────────
    cq = u.get('callback_query')
    if cq:
        data    = cq.get('data','')
        cb_id   = cq.get('id')
        msg     = cq.get('message') or {}
        chat_id = ((msg.get('chat') or {}).get('id'))

        # Ack quickly so Telegram UI stops spinning
        if cb_id:
            try:
                requests.post(
                    f"https://api.telegram.org/bot{BOT_TOKEN}/answerCallbackQuery",
                    json={'callback_query_id': cb_id},
                    timeout=5
                )
            except Exception:
                pass

        try:
            action, email_id = data.split(':', 1)
        except ValueError:
            continue

        # ── Finance transaction confirm/cancel ────────────────────────────────
        if action in ('fin_confirm', 'fin_cancel'):
            import json as _jj, os as _oo
            pending_file = f"/Users/henryburton/.openclaw/workspace-anthropic/tmp/fin_pending_{email_id}.json"
            if action == 'fin_cancel':
                try: _oo.unlink(pending_file)
                except: pass
                tg_send(chat_id, "Transaction cancelled.")
            else:
                try:
                    with open(pending_file) as _f:
                        tx = _jj.load(_f)
                    resp = requests.post(
                        f"{SUPABASE_URL}/rest/v1/finance_transactions",
                        json=tx,
                        headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}', 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
                        timeout=10
                    )
                    try: _oo.unlink(pending_file)
                    except: pass
                    if resp.ok:
                        sign  = '+' if tx['type'] == 'income' else '-'
                        emoji = '' if tx['type'] == 'income' else ''
                        tg_send(chat_id,
                            f"{emoji} <b>Logged!</b>  {sign}R{tx['amount']:,.0f}"
                            f"{(' — ' + (tx.get('description') or tx.get('category', ''))) if (tx.get('description') or tx.get('category')) else ''}"
                        )
                    else:
                        tg_send(chat_id, f"DB error: {resp.text[:150]}")
                except FileNotFoundError:
                    tg_send(chat_id, "Pending transaction expired — please re-send /log.")
                except Exception as ex:
                    tg_send(chat_id, f"Error confirming: {ex}")
            continue

        if action not in ('approve', 'hold', 'adjust', 'remind_done', 'remind_snooze',
                          'book_flight', 'book_cancel', 'wa_dismiss'):
            continue

        # Fetch email context for signal logging (non-blocking)
        _email_ctx = {}
        if action in ('approve', 'hold', 'adjust') and email_id:
            try:
                _r = requests.get(
                    f"{SUPABASE_URL}/rest/v1/email_queue?id=eq.{email_id}&select=client,subject,analysis",
                    headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'},
                    timeout=5
                )
                if _r.status_code == 200 and _r.json():
                    _row = _r.json()[0]
                    _email_ctx = {
                        'email_id': email_id,
                        'client': _row.get('client', ''),
                        'subject': _row.get('subject', ''),
                    }
            except Exception:
                _email_ctx = {'email_id': email_id}

        if action == 'approve':
            supa_patch_anon(f"email_queue?id=eq.{email_id}", {'status': 'approved'})
            log_signal('josh', _email_ctx.get('client') or 'unknown', 'email_approved', _email_ctx)
            if chat_id:
                tg_send(chat_id, '✅ Approved. Scheduler will send shortly.')

        elif action == 'hold':
            supa_patch_anon(f"email_queue?id=eq.{email_id}", {'status': 'awaiting_approval'})
            log_signal('josh', _email_ctx.get('client') or 'unknown', 'email_held', _email_ctx)
            if chat_id:
                tg_send(chat_id, '⏸ Held. Still awaiting approval. You can hit Adjust later.')

        elif action == 'adjust':
            log_signal('josh', _email_ctx.get('client') or 'unknown', 'email_adjusted', _email_ctx)
            if chat_id:
                pending_file = f"/Users/henryburton/.openclaw/workspace-anthropic/tmp/telegram_pending_adjust_{chat_id}"
                with open(pending_file, 'w') as f:
                    f.write(email_id)
                tg_send(chat_id, '✏️ Cool. Reply in this chat with how you want me to adjust the draft.')

        elif action == 'remind_done':
            # Mark reminder dismissed
            requests.patch(
                f"{SUPABASE_URL}/rest/v1/notifications?id=eq.{email_id}",
                headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                         'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
                json={'status': 'dismissed'}, timeout=10
            )
            log_signal('josh', 'josh', 'reminder_done', {'notification_id': email_id})
            if chat_id:
                tg_send(chat_id, '✅ Reminder done!')

        elif action == 'remind_snooze':
            # Snooze 15 min — update due time, clear last_sent_at
            import datetime as _dt
            SAST = _dt.timezone(_dt.timedelta(hours=2))
            snooze_until = (_dt.datetime.now(SAST) + _dt.timedelta(minutes=15)).isoformat()
            # Get current metadata
            try:
                resp = requests.get(
                    f"{SUPABASE_URL}/rest/v1/notifications?id=eq.{email_id}&select=metadata",
                    headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'},
                    timeout=10
                )
                rows = resp.json()
                meta = (rows[0].get('metadata') or {}) if rows else {}
                if isinstance(meta, str):
                    import json as _json
                    try: meta = _json.loads(meta)
                    except Exception: meta = {}
                meta['due'] = snooze_until
                requests.patch(
                    f"{SUPABASE_URL}/rest/v1/notifications?id=eq.{email_id}",
                    headers={'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}',
                             'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
                    json={'metadata': meta, 'status': 'unread'}, timeout=10
                )
            except Exception:
                pass
            log_signal('josh', 'josh', 'reminder_snoozed', {'notification_id': email_id})
            if chat_id:
                tg_send(chat_id, '⏱ Snoozed 15 minutes.')

        elif action == 'wa_dismiss':
            # email_id is the whatsapp_messages row id
            # Message already marked notified — just edit Telegram message to remove buttons
            msg_id = (msg or {}).get('message_id')
            if chat_id and msg_id:
                try:
                    requests.post(
                        f"https://api.telegram.org/bot{BOT_TOKEN}/editMessageReplyMarkup",
                        json={'chat_id': chat_id, 'message_id': msg_id, 'reply_markup': {'inline_keyboard': []}},
                        timeout=5
                    )
                except Exception:
                    pass

        elif action == 'book_flight':
            # email_id here is the chat_id encoded in callback_data as "book_flight:{chat_id}"
            _pending = f"{WS_ROOT}/tmp/pending-flight-{email_id}.json"
            if not os.path.exists(_pending):
                if chat_id:
                    tg_send(chat_id, '⚠️ No pending flight found. Search again with /flight.')
            else:
                try:
                    with open(_pending) as _pf:
                        _booking = json.load(_pf)
                    os.remove(_pending)
                except Exception as _e:
                    if chat_id:
                        tg_send(chat_id, f'❌ Error reading booking: {_e}')
                    continue

                _airline = (_booking.get('airline') or 'flysafair').lower()

                if _airline != 'flysafair':
                    # Lift — send direct booking link (Lift automation not yet implemented)
                    _fr  = _booking.get('from', '');   _to  = _booking.get('to', '')
                    _dt  = _booking.get('date', '');   _ret = _booking.get('return_date') or 'NA'
                    _pax = _booking.get('adults', 1)
                    _url = f"https://www.lift.co.za/flight-results/{_fr}-{_to}/{_dt}/{_ret}/{_pax}/0/0"
                    if chat_id:
                        tg_send(chat_id, f'<b>Lift — tap to book:</b>\n{_url}')
                else:
                    if chat_id:
                        tg_send(chat_id, '\U0001f504 Opening browser to book your FlySafair flight...')
                    _cmd = [
                        'node',
                        f'{WS_ROOT}/scripts/flights/book-flight.mjs',
                        '--airline', 'flysafair',
                        '--from',    _booking.get('from', ''),
                        '--to',      _booking.get('to', ''),
                        '--date',    _booking.get('date', ''),
                        '--adults',  str(_booking.get('adults', 1)),
                        '--confirm',
                    ]
                    if _booking.get('flight'):
                        _cmd += ['--flight', _booking['flight']]
                    if _booking.get('price'):
                        _cmd += ['--price', str(_booking['price'])]
                    if _booking.get('return_date'):
                        _cmd += ['--return', _booking['return_date']]
                    try:
                        _res = subprocess.run(_cmd, capture_output=True, text=True, timeout=180)
                        _out = json.loads(_res.stdout.strip()) if _res.stdout.strip() else {}
                    except Exception as _e:
                        if chat_id:
                            tg_send(chat_id, f'❌ Booking error: {_e}')
                        continue

                    if _out.get('ok'):
                        _msg = _out.get('message', 'Booking initiated.')
                        if chat_id:
                            tg_send(chat_id, f'✅ {_msg}')
                        for _shot in (_out.get('screenshots') or [])[:3]:
                            if os.path.exists(_shot):
                                try:
                                    requests.post(
                                        f"https://api.telegram.org/bot{BOT_TOKEN}/sendPhoto",
                                        data={'chat_id': chat_id},
                                        files={'photo': open(_shot, 'rb')},
                                        timeout=30
                                    )
                                except Exception:
                                    pass
                    else:
                        _err = _out.get('error', 'Unknown error')
                        if chat_id:
                            tg_send(chat_id, f'❌ Booking failed: {_err}')
                        for _shot in (_out.get('screenshots') or [])[:2]:
                            if os.path.exists(_shot):
                                try:
                                    requests.post(
                                        f"https://api.telegram.org/bot{BOT_TOKEN}/sendPhoto",
                                        data={'chat_id': chat_id},
                                        files={'photo': open(_shot, 'rb')},
                                        timeout=30
                                    )
                                except Exception:
                                    pass

        elif action == 'book_cancel':
            _pending = f"{WS_ROOT}/tmp/pending-flight-{email_id}.json"
            try:
                os.remove(_pending)
            except Exception:
                pass
            if chat_id:
                tg_send(chat_id, '\u2716 Flight booking cancelled. Search again with /flight when ready.')

        continue  # done with this update

    # ── Any message type ──────────────────────────────────────────────────────
    msg = u.get('message') or u.get('edited_message')
    if not msg:
        continue

    text       = (msg.get('text') or '').strip()
    caption    = (msg.get('caption') or '').strip()
    chat_id    = ((msg.get('chat') or {}).get('id'))
    chat_type  = (msg.get('chat') or {}).get('type', 'private')
    photo      = msg.get('photo')
    voice      = msg.get('voice')
    video      = msg.get('video')
    video_note = msg.get('video_note')
    document   = msg.get('document')

    has_content = text or photo or voice or video or video_note or document
    if not has_content or not chat_id:
        continue

    is_group = chat_type in ('group', 'supergroup')
    JOSH_BOT_USERNAME = os.environ.get('JOSH_BOT_USERNAME', 'JoshAmalfiBot')
    WS = os.environ.get('AOS_ROOT', '/Users/henryburton/.openclaw/workspace-anthropic')

    # ── Private chat: identify user and persist chat_id ──────────────────────
    if not is_group:
        # Determine which user is messaging
        user_profile = 'josh'
        if SALAH_CHAT_ID and str(chat_id) == str(SALAH_CHAT_ID):
            user_profile = 'salah'
            try:
                with open(f"{WS}/tmp/salah_private_chat_id", 'w') as _cf:
                    _cf.write(str(chat_id))
            except Exception:
                pass
        else:
            try:
                with open(f"{WS}/tmp/josh_private_chat_id", 'w') as _cf:
                    _cf.write(str(chat_id))
            except Exception:
                pass
    else:
        user_profile = 'josh'  # group chats always Josh's context

    # ── Group chat: log ALL messages to shared history ────────────────────────
    if is_group:
        import datetime as _dt
        sender = msg.get('from') or {}
        sender_name = sender.get('username') or sender.get('first_name') or 'Unknown'
        is_bot_msg  = sender.get('is_bot', False)

        group_history_file = f"{WS}/tmp/group-{chat_id}.jsonl"
        log_text = text or caption or '[media]'
        try:
            with open(group_history_file, 'a') as gf:
                import json as _json
                gf.write(_json.dumps({
                    'ts': _dt.datetime.utcnow().strftime('%H:%M'),
                    'role': sender_name,
                    'is_bot': is_bot_msg,
                    'message': log_text,
                }) + '\n')
            with open(group_history_file) as gf:
                lines = gf.readlines()
            if len(lines) > 100:
                with open(group_history_file, 'w') as gf:
                    gf.writelines(lines[-100:])
        except Exception:
            pass

        try:
            import requests as _req
            _req.post(
                f"{SUPABASE_URL}/rest/v1/group_chat_history",
                headers={
                    'apikey': SERVICE_KEY,
                    'Authorization': f'Bearer {SERVICE_KEY}',
                    'Content-Type': 'application/json',
                    'Prefer': 'return=minimal',
                },
                json={
                    'chat_id': str(chat_id),
                    'sender': sender_name,
                    'is_bot': is_bot_msg,
                    'message': log_text,
                },
                timeout=5
            )
        except Exception:
            pass

        mention = f'@{JOSH_BOT_USERNAME}'
        if mention.lower() not in (text or caption or '').lower():
            continue  # log only, don't respond

    # ── Media helpers ─────────────────────────────────────────────────────────
    def tg_download(file_id):
        import time as _t
        # Retry up to 4 times with backoff — [Errno 65] "No route to host" happens
        # transiently after a long-poll cycle when macOS routing table briefly flickers
        # (WiFi DHCP renewal, sleep/wake). getUpdates survives on its existing TCP
        # connection; getFile needs a fresh connection and can hit the stale route.
        last_err = None
        for attempt in range(4):
            try:
                r = requests.get(
                    f"https://api.telegram.org/bot{BOT_TOKEN}/getFile?file_id={file_id}",
                    timeout=15
                )
                data = r.json()
                if not data.get('ok'):
                    raise ValueError(f"Telegram getFile failed: {data.get('description', 'unknown error')}")
                file_path = (data.get('result') or {}).get('file_path')
                if not file_path:
                    raise ValueError(f"Telegram getFile returned no file_path: {data}")
                dl = requests.get(
                    f"https://api.telegram.org/file/bot{BOT_TOKEN}/{file_path}",
                    timeout=90
                )
                dl.raise_for_status()
                if not dl.content:
                    raise ValueError(f"Telegram returned empty file body for {file_path}")
                return dl.content
            except Exception as e:
                last_err = e
                err_str = str(e)
                # Only retry on connection-level errors (routing, DNS, reset)
                if any(x in err_str for x in ('No route to host', 'Connection refused',
                                               'Failed to establish', 'RemoteDisconnected',
                                               'ConnectionReset', 'NewConnectionError')):
                    if attempt < 3:
                        _t.sleep(2 ** attempt)  # 1s, 2s, 4s
                        continue
                raise last_err
        raise last_err

    group_history_file = f"{WS}/tmp/group-{chat_id}.jsonl" if is_group else ''

    # ── Photo ─────────────────────────────────────────────────────────────────
    if photo:
        try:
            candidates = [p for p in photo if p.get('file_id')]
            if not candidates:
                tg_send(chat_id, '⚠️ Photo received but no downloadable version found.')
                continue
            largest   = max(candidates, key=lambda p: p.get('file_size', 0))
            img_data  = tg_download(largest['file_id'])
            img_path  = f"{WS}/tmp/tg-photo-{uid_str}.jpg"
            with open(img_path, 'wb') as f:
                f.write(img_data)

            # ── Route: Blender 3D scene generation ───────────────────────────
            cap_lower = (caption or '').lower()
            if 'blender' in cap_lower:
                subprocess.Popen(
                    ['bash', f'{WS}/scripts/video-editor/tg-blender-from-image.sh',
                     str(chat_id), img_path, caption or ''],
                    stdout=open(f'{WS}/out/blender-from-image.log', 'a'),
                    stderr=open(f'{WS}/out/blender-from-image.err.log', 'a')
                )
            else:
                caption_part = f"\nCaption: {caption}" if caption else ""
                user_display = 'Salah' if user_profile == 'salah' else 'Josh'
                user_text = f"[Photo from {user_display}]{caption_part}\nImage file: {img_path}"
                subprocess.Popen([
                    'bash', f'{WS}/scripts/telegram-claude-gateway.sh',
                    str(chat_id), user_text, group_history_file, get_reply_mode(chat_id), user_profile,
                ], stdout=subprocess.DEVNULL, stderr=open(GATEWAY_ERR_LOG, 'a'))
        except Exception as e:
            tg_send(chat_id, f'❌ Failed to process photo: {e}')
        continue

    # ── Voice message ─────────────────────────────────────────────────────────
    if voice:
        try:
            if not voice.get('file_id'):
                tg_send(chat_id, '⚠️ Voice message received but no downloadable file.')
                continue
            tg_send(chat_id, '🎙 Transcribing...')
            audio_data = tg_download(voice['file_id'])

            deepgram_key = os.environ.get('DEEPGRAM_API_KEY', '')
            if not deepgram_key or deepgram_key == 'REPLACE_WITH_DEEPGRAM_API_KEY':
                user_text = '[Voice message received but Deepgram API key is not set]'
            else:
                import urllib.request
                req = urllib.request.Request(
                    'https://api.deepgram.com/v1/listen?model=nova-2&smart_format=true&detect_language=true',
                    data=audio_data,
                    headers={
                        'Authorization': f'Token {deepgram_key}',
                        'Content-Type': 'audio/ogg',
                    },
                    method='POST',
                )
                with urllib.request.urlopen(req, timeout=120) as resp:
                    dg = json.loads(resp.read())
                transcript = (
                    dg.get('results', {})
                      .get('channels', [{}])[0]
                      .get('alternatives', [{}])[0]
                      .get('transcript', '')
                      .strip()
                )
                detected_lang = (
                    dg.get('results', {})
                      .get('channels', [{}])[0]
                      .get('detected_language', '')
                )
                lang_note = f' [{detected_lang}]' if detected_lang and detected_lang != 'en' else ''
                user_text = (
                    f'[Voice message{lang_note} — transcribed]: {transcript}'
                    if transcript
                    else '[Voice message received but transcription returned empty]'
                )

                # Log to adaptive memory
                if transcript:
                    log_signal('josh', 'josh', 'voice_message_sent', {
                        'transcript': transcript[:500],
                        'language':   detected_lang or 'en',
                        'duration_secs': voice.get('duration', 0),
                    })

            subprocess.Popen([
                'bash', f'{WS}/scripts/telegram-claude-gateway.sh',
                str(chat_id), user_text, group_history_file, 'audio', user_profile,
            ], stdout=subprocess.DEVNULL, stderr=open(GATEWAY_ERR_LOG, 'a'))
        except Exception as e:
            tg_send(chat_id, f'❌ Failed to process voice: {e}')
        continue

    # ── Video / video note ────────────────────────────────────────────────────
    if video or video_note:
        try:
            media     = video or video_note
            file_id   = media.get('file_id', '')
            file_size = media.get('file_size', 0) or 0
            BOT_LIMIT = 20 * 1024 * 1024  # Telegram bot API download limit

            # Caption becomes the title; fall back to timestamp-based name
            title = caption.strip() if caption else f"Video {uid_str[:8]}"

            _too_big_msg = (
                'Upload directly to Google Drive instead:\n'
                '<a href="https://drive.google.com/drive/folders/1mTC-bONcjjo2_-NihFTH4Aum-6GQqsLx">Video Queue folder</a>\n\n'
                'It will be processed at the next poll (6am, 9am, 2pm, 4pm SAST).\n\n'
                '<i>Or compress it below 20 MB and resend here.</i>'
            )

            if not file_id:
                tg_send(chat_id, '⚠️ Video received but no file_id available.')
            elif file_size > BOT_LIMIT:
                tg_send(chat_id,
                    f'⚠️ Video is {file_size // (1024*1024)} MB — above the 20 MB bot API limit.\n\n'
                    + _too_big_msg
                )
            else:
                # file_size may be 0 if Telegram omitted it (common for large files)
                # Attempt download; if Telegram rejects as too big, redirect gracefully
                _video_dl_ok = True
                try:
                    video_data = tg_download(file_id)
                except Exception as _dl_err:
                    _video_dl_ok = False
                    _dl_str = str(_dl_err).lower()
                    if 'file is too big' in _dl_str or 'too big' in _dl_str:
                        tg_send(chat_id,
                            '⚠️ Video is too large for the bot API (20 MB limit).\n\n'
                            + _too_big_msg
                        )
                    else:
                        tg_send(chat_id, f'❌ Failed to download video: {_dl_err}')
                if _video_dl_ok:
                    safe_title = re.sub(r'[^\w\s-]', '', title)[:50].strip()
                    video_path = f"{WS}/tmp/tg-video-{uid_str}.mp4"
                    with open(video_path, 'wb') as f:
                        f.write(video_data)

                    # ── Route: analyse (watch/learn) vs pipeline (process) ────
                    cap_lower = (caption or '').lower()
                    is_analyse = any(kw in cap_lower for kw in (
                        'watch', 'learn', 'ref', 'reference', 'analyse', 'analyze',
                        'study', 'review', 'technique', 'inspect', 'breakdown',
                    ))

                    if is_analyse:
                        tg_send(chat_id, f'👁 Got it ({len(video_data) // 1024}KB). Watching and analysing...')
                        subprocess.Popen(
                            ['bash', f'{WS}/scripts/video-editor/tg-analyse-video.sh',
                             str(chat_id), video_path, caption or ''],
                            stdout=open(f'{WS}/out/video-poller.log', 'a'),
                            stderr=open(f'{WS}/out/video-poller.err.log', 'a')
                        )
                    else:
                        tg_send(chat_id, f'📥 Got it ({len(video_data) // 1024}KB). Starting pipeline...\n\n<i>Trimming silence, generating captions, rendering — usually 2 to 4 min.</i>\n\n<i>Tip: add caption "watch" or "learn" to get an editing technique analysis instead.</i>')
                        subprocess.Popen(
                            ['bash', f'{WS}/scripts/video-editor/tg-process-and-reply.sh',
                             str(chat_id), video_path, safe_title or 'Video'],
                            stdout=open(f'{WS}/out/video-poller.log', 'a'),
                            stderr=open(f'{WS}/out/video-poller.err.log', 'a')
                        )
        except Exception as e:
            tg_send(chat_id, f'❌ Failed to process video: {e}')
        continue

    # ── Document (file) ───────────────────────────────────────────────────────
    if document:
        try:
            import datetime as _dt, os as _os
            mime  = document.get('mime_type', '') or ''
            fname = document.get('file_name', 'file') or 'file'
            fsize = document.get('file_size', 0) or 0

            # Sanitise filename — strip any path components to prevent traversal
            fname_safe = _os.path.basename(fname).strip() or 'file'
            fname_safe = re.sub(r'[^\w.\-() ]', '_', fname_safe)

            caption_part = f"\nCaption: {caption}" if caption else ""
            ext   = fname_safe.rsplit('.', 1)[-1].lower() if '.' in fname_safe else ''
            fname_lower = fname_safe.lower()

            is_text  = (mime in ('text/plain','application/json','text/csv','text/markdown','text/x-log')
                        or ext in ('txt','md','csv','json','log','yaml','yml','toml','ini','xml','html','htm','sh','py','js','ts'))
            is_image = mime.startswith('image/') or ext in ('jpg','jpeg','png','gif','webp','bmp','svg')
            is_pdf   = mime == 'application/pdf' or ext == 'pdf'
            is_video = mime.startswith('video/') or ext in ('mp4','mov','avi','mkv','webm')

            # Telegram Bot API cannot download files > 20 MB
            BOT_LIMIT = 20 * 1024 * 1024
            if fsize > BOT_LIMIT:
                if is_video:
                    # Large video document → redirect to Google Drive, not transcript paste
                    tg_send(chat_id,
                        f"⚠️ <b>{fname_safe}</b> is {fsize // (1024*1024)} MB — above the 20 MB bot API limit.\n\n"
                        "Upload it directly to Google Drive:\n"
                        '<a href="https://drive.google.com/drive/folders/1mTC-bONcjjo2_-NihFTH4Aum-6GQqsLx">Video Queue folder</a>\n\n'
                        "It will be processed at the next poll (6am, 9am, 2pm, 4pm SAST).\n\n"
                        "<i>Or compress it below 20 MB and resend here.</i>"
                    )
                else:
                    tg_send(chat_id,
                        f"⚠️ <b>{fname_safe}</b> is {fsize // (1024*1024)} MB — the bot API limit is 20 MB.\n\n"
                        "To process a large transcript, paste the content directly:\n"
                        "<code>research: Title\n[paste content here]</code>\n\n"
                        "The research digest extracts the key insights automatically."
                    )
                continue

            # Download the file — all types, within size limit
            try:
                doc_data = tg_download(document['file_id'])
            except Exception as dl_err:
                tg_send(chat_id, f"❌ Couldn't download <b>{fname_safe}</b>: {dl_err}")
                continue

            doc_path = f"{WS}/tmp/tg-doc-{uid_str}-{fname_safe}"
            with open(doc_path, 'wb') as f:
                f.write(doc_data)

            if is_image:
                # Images: pass file path — Claude can view them
                user_display = 'Salah' if user_profile == 'salah' else 'Josh'
                user_text = f"[Image file from {user_display}: {fname_safe}]{caption_part}\nFile: {doc_path}"
                subprocess.Popen([
                    'bash', f'{WS}/scripts/telegram-claude-gateway.sh',
                    str(chat_id), user_text, group_history_file, get_reply_mode(chat_id), user_profile,
                ], stdout=subprocess.DEVNULL, stderr=open(GATEWAY_ERR_LOG, 'a'))

            elif is_text:
                # Text files: inline if small, research inbox if large
                content_str = doc_data.decode('utf-8', errors='replace').replace('\x00', '')
                TEXT_INLINE_LIMIT = 30_000  # ~7 500 words

                if len(content_str) > TEXT_INLINE_LIMIT:
                    # Large: auto-route to research inbox
                    title    = fname_safe.rsplit('.', 1)[0] or 'Document'
                    slug     = re.sub(r'[^a-z0-9]+', '-', title.lower())[:60].strip('-') or 'document'
                    ts       = _dt.datetime.now().strftime('%Y%m%d-%H%M%S')
                    inbox    = f"{WS}/research/inbox"
                    fpath    = f"{inbox}/{ts}-{slug}.txt"
                    _os.makedirs(inbox, exist_ok=True)
                    with open(fpath, 'w', encoding='utf-8') as f:
                        f.write(content_str)
                    tg_send(chat_id,
                        f"📚 <b>{fname_safe}</b> — {len(content_str)//1000}K chars queued in research inbox.\n"
                        "Insights ready within 30 min. Check <i>Mission Control → Research</i>."
                    )
                else:
                    # Small: embed inline for Claude to read directly
                    user_display = 'Salah' if user_profile == 'salah' else 'Josh'
                    user_text = (
                        f"[Text file from {user_display}: {fname_safe}]{caption_part}\n\n"
                        f"--- FILE CONTENT ---\n{content_str}\n--- END FILE ---"
                    )
                    subprocess.Popen([
                        'bash', f'{WS}/scripts/telegram-claude-gateway.sh',
                        str(chat_id), user_text, group_history_file, get_reply_mode(chat_id), user_profile,
                    ], stdout=subprocess.DEVNULL, stderr=open(GATEWAY_ERR_LOG, 'a'))

            elif is_pdf:
                # PDFs: Claude Code's Read tool can process PDFs directly
                user_display = 'Salah' if user_profile == 'salah' else 'Josh'
                user_text = f"[PDF from {user_display}: {fname_safe}]{caption_part}\nFile: {doc_path}"
                subprocess.Popen([
                    'bash', f'{WS}/scripts/telegram-claude-gateway.sh',
                    str(chat_id), user_text, group_history_file, get_reply_mode(chat_id), user_profile,
                ], stdout=subprocess.DEVNULL, stderr=open(GATEWAY_ERR_LOG, 'a'))

            elif is_video:
                # .mp4/.mov document → route by caption
                title = caption.strip() if caption else fname_safe.rsplit('.', 1)[0]
                safe_title = re.sub(r'[^\w\s-]', '', title)[:50].strip() or 'Video'
                cap_lower = (caption or '').lower()
                is_analyse = any(kw in cap_lower for kw in (
                    'watch', 'learn', 'ref', 'reference', 'analyse', 'analyze',
                    'study', 'review', 'technique', 'inspect', 'breakdown',
                ))
                if is_analyse:
                    tg_send(chat_id, f'👁 Got it ({fsize // 1024}KB). Watching and analysing...')
                    subprocess.Popen(
                        ['bash', f'{WS}/scripts/video-editor/tg-analyse-video.sh',
                         str(chat_id), doc_path, caption or ''],
                        stdout=open(f'{WS}/out/video-poller.log', 'a'),
                        stderr=open(f'{WS}/out/video-poller.err.log', 'a')
                    )
                else:
                    tg_send(chat_id, f'📥 Got it ({fsize // 1024}KB). Starting pipeline...\n\n<i>Trimming silence, generating captions, rendering — usually 2 to 4 min.</i>')
                    subprocess.Popen(
                        ['bash', f'{WS}/scripts/video-editor/tg-process-and-reply.sh',
                         str(chat_id), doc_path, safe_title],
                        stdout=open(f'{WS}/out/video-poller.log', 'a'),
                        stderr=open(f'{WS}/out/video-poller.err.log', 'a')
                    )

            else:
                # Other binary files: pass path + type — Claude can attempt to read
                mime_display = mime or 'unknown type'
                user_display = 'Salah' if user_profile == 'salah' else 'Josh'
                user_text = f"[File from {user_display}: {fname_safe} ({mime_display})]{caption_part}\nFile: {doc_path}"
                subprocess.Popen([
                    'bash', f'{WS}/scripts/telegram-claude-gateway.sh',
                    str(chat_id), user_text, group_history_file, get_reply_mode(chat_id), user_profile,
                ], stdout=subprocess.DEVNULL, stderr=open(GATEWAY_ERR_LOG, 'a'))

        except Exception as e:
            tg_send(chat_id, f'❌ Failed to process document: {e}')
        continue

    # ── Reference video URL analysis ─────────────────────────────────────────
    # Detect YouTube/TikTok/Instagram/Twitter URLs sent for editing technique analysis
    _VIDEO_URL_PAT = re.compile(
        r'https?://(?:www\.)?(?:'
        r'(?:youtube\.com/(?:watch|shorts)|youtu\.be/)'
        r'|(?:tiktok\.com/@[^/]+/video|vm\.tiktok\.com)'
        r'|(?:instagram\.com/(?:p|reel|reels))'
        r'|(?:twitter\.com|x\.com)/[^/]+/status'
        r')[^\s]*',
        re.IGNORECASE
    )
    _url_match = _VIDEO_URL_PAT.search(text or '')
    if _url_match and user_profile != 'salah':
        video_url = _url_match.group(0)
        try:
            tg_send(chat_id, f'🎬 Downloading reference video for analysis...\n<code>{video_url[:80]}</code>')
            import tempfile as _tf, glob as _glob
            dl_dir = _tf.mkdtemp(prefix='/tmp/ref-video-')
            # Download best quality up to 720p
            dl_result = subprocess.run(
                ['yt-dlp', '-f', 'best[height<=720][ext=mp4]/best[height<=720]/best',
                 '--merge-output-format', 'mp4',
                 '-o', os.path.join(dl_dir, 'video.%(ext)s'),
                 '--no-playlist', '--quiet', video_url],
                capture_output=True, text=True, timeout=120
            )
            dl_files = _glob.glob(os.path.join(dl_dir, '*.mp4')) + _glob.glob(os.path.join(dl_dir, '*.webm'))
            if dl_result.returncode != 0 or not dl_files:
                tg_send(chat_id, f'⚠️ Could not download video ({dl_result.returncode}). It may be private or geo-blocked.\n\n{dl_result.stderr[:300]}')
            else:
                dl_path = dl_files[0]
                # Extract frames every 2.5s → collage for Claude
                frames_dir = os.path.join(dl_dir, 'frames')
                os.makedirs(frames_dir, exist_ok=True)
                duration = float(subprocess.check_output(
                    ['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                     '-of', 'default=noprint_wrappers=1:nokey=1', dl_path],
                    text=True).strip() or '0')
                n_frames = min(9, max(4, int(duration / 2.5)))
                subprocess.run(
                    ['ffmpeg', '-i', dl_path, '-vf',
                     f'fps=1/{duration/n_frames:.1f},scale=360:-2',
                     '-frames:v', str(n_frames),
                     os.path.join(frames_dir, 'f%02d.jpg')],
                    capture_output=True
                )
                frame_files = sorted(_glob.glob(os.path.join(frames_dir, '*.jpg')))
                frame_list = '\n'.join(f'Frame file: {f}' for f in frame_files)
                analyse_prompt = (
                    f"[Reference video analysis request from Josh]\n"
                    f"URL: {video_url}\n"
                    f"Duration: {int(duration)}s\n\n"
                    f"Josh sent this video to study the editing techniques. Analyse the frames and give a detailed breakdown:\n\n"
                    f"1. CAPTION STYLE — font, size, position, color, animation (appear word-by-word? bounce? fade?), outline/shadow\n"
                    f"2. MOTION GRAPHICS — lower thirds, overlays, animated text, icons, arrows, callouts\n"
                    f"3. TRANSITIONS — cuts, zooms, swipes, jump cuts\n"
                    f"4. COLOR GRADING — warm/cool, contrast, saturation style\n"
                    f"5. PACING — estimated cuts per minute, fast/slow rhythm\n"
                    f"6. REMOTION IMPLEMENTATION — specific suggestions for replicating these effects in our Remotion pipeline\n\n"
                    f"{frame_list}"
                )
                subprocess.Popen([
                    'bash', f'{WS}/scripts/telegram-claude-gateway.sh',
                    str(chat_id), analyse_prompt, group_history_file, get_reply_mode(chat_id), user_profile,
                ], stdout=subprocess.DEVNULL, stderr=open(GATEWAY_ERR_LOG, 'a'))
                import shutil as _shutil
                _shutil.rmtree(dl_dir, ignore_errors=True)
        except subprocess.TimeoutExpired:
            tg_send(chat_id, '⏱ Video download timed out after 2 min. Try a shorter clip.')
        except Exception as _e:
            tg_send(chat_id, f'❌ Reference video analysis failed: {_e}')
        continue

    # ── Text: commands + free-text → Claude ───────────────────────────────────
    text_lower = text.lower()
    actor_id = 'salah' if user_profile == 'salah' else 'josh'

    # Josh-only commands — block for Salah (remind + meet are allowed for Salah with user isolation)
    JOSH_ONLY_CMDS = ('/ooo', '/available', '/newlead', '/calibrate', '/agents', '/enrich')
    if user_profile == 'salah' and any(text_lower.startswith(c) for c in JOSH_ONLY_CMDS):
        tg_send(chat_id, "⛔ That command is Josh-only on this system.")
        continue

    # ── Calibration wizard state machine ──────────────────────────────────────
    calibrate_state_file = f"{WS}/tmp/calibrate-state-{chat_id}.json"
    calibrate_data_file  = f"{WS}/tmp/calibrate-data-{chat_id}.json"

    if text_lower.startswith('/calibrate'):
        arg = text.split(None, 1)[1].strip() if ' ' in text else 'new'
        if arg == 'list':
            subprocess.run(['bash', f'{WS}/scripts/sophia-calibrate.sh', 'list'],
                           capture_output=False)
        else:
            subprocess.Popen(['bash', f'{WS}/scripts/sophia-calibrate.sh', arg])
        continue

    # Active calibration wizard — intercept free text as answers
    if os.path.exists(calibrate_state_file) and user_profile == 'josh':
        try:
            state = json.loads(open(calibrate_state_file).read())
        except Exception:
            state = {}

        step = state.get('step', '')
        cdata = state.get('data', {})
        slug  = state.get('slug')

        STEPS = [
            ('company_name',    'Great! Now enter the <b>primary contact name</b> (e.g. "Riaan Kotze"):'),
            ('contact_name',    'What is their <b>role/title</b>? (e.g. "CEO", "Founder"):'),
            ('contact_role',    'What is their <b>email address</b>?'),
            ('contact_email',   'What <b>industry</b> are they in? (e.g. Legal, Property, Retail):'),
            ('industry',        'In one sentence: <b>what does the business do</b>?'),
            ('what_they_do',    'What is the <b>current project</b> Amalfi AI is building for them?'),
            ('current_project', 'What are their <b>top 2-3 priorities</b>? (brief bullet points fine):'),
            ('key_priorities',  'Preferred <b>email tone</b>? (e.g. "formal", "casual and direct", "warm professional"):'),
            ('email_tone',      'Last one — are they on a <b>retainer</b> or <b>project</b> basis? Reply "retainer" or "project":'),
        ]
        STEP_KEYS = [s[0] for s in STEPS]

        if step and step in STEP_KEYS:
            # Save this answer
            cdata[step] = text.strip()

            # Generate slug from company name
            if step == 'company_name':
                import re as _re
                slug = _re.sub(r'[^a-z0-9]+', '_', text.strip().lower()).strip('_')
                state['slug'] = slug

            # Move to next step
            idx = STEP_KEYS.index(step)
            if idx + 1 < len(STEPS):
                next_step, next_prompt = STEPS[idx + 1]
                state['step'] = next_step
                state['data'] = cdata
                with open(calibrate_state_file, 'w') as f:
                    json.dump(state, f)
                tg_send(chat_id, next_prompt)
            else:
                # All steps done — save retainer status and trigger write
                cdata['retainer_status'] = 'retainer' if 'retainer' in text.lower() else 'project_only'
                cdata['project_start_date'] = __import__('datetime').date.today().isoformat()
                with open(calibrate_data_file, 'w') as f:
                    json.dump(cdata, f)
                os.remove(calibrate_state_file)
                tg_send(chat_id, f'⏳ Writing {cdata.get("company_name","client")} context...')
                subprocess.Popen(['bash', f'{WS}/scripts/sophia-calibrate.sh', slug])
        continue

    if text_lower.startswith('/remind'):
        handle_remind(chat_id, text, user_profile)
        log_signal(actor_id, actor_id, 'command_used', {'command': 'remind', 'text': text[:120]})

    elif text_lower.startswith('/newlead'):
        handle_newlead(chat_id, text)
        log_signal('josh', 'josh', 'command_used', {'command': 'newlead', 'text': text[:120]})

    elif text_lower.startswith('/meet'):
        handle_meet(chat_id, text)
        log_signal('josh', 'josh', 'command_used', {'command': 'meet', 'text': text[:120]})

    elif text_lower.startswith('/ooo'):
        handle_ooo(chat_id, text)
        log_signal('josh', 'josh', 'command_used', {'command': 'ooo', 'text': text[:120]})

    elif text_lower.startswith('/available'):
        handle_available(chat_id)
        log_signal('josh', 'josh', 'command_used', {'command': 'available'})

    elif text_lower.startswith('/agents'):
        handle_agents(chat_id, text)
        log_signal('josh', 'josh', 'command_used', {'command': 'agents', 'text': text[:120]})

    elif text_lower.startswith('/enrich'):
        # /enrich               → run enrichment on all pending leads
        # /enrich <email>       → verify a single email
        # /enrich lead <id>     → enrich a specific lead by ID
        parts = text.strip().split(None, 2)
        tg_send(chat_id, '⏳ Running enrichment waterfall (Apollo → Hunter → Apify)...')
        if len(parts) == 2 and '@' in parts[1]:
            # Verify single email
            subprocess.Popen(['bash', f'{WS}/scripts/cold-outreach/enrich-leads.sh', '--email', parts[1]])
        elif len(parts) >= 3 and parts[1].lower() == 'lead':
            subprocess.Popen(['bash', f'{WS}/scripts/cold-outreach/enrich-leads.sh', '--lead', parts[2]])
        else:
            subprocess.Popen(['bash', f'{WS}/scripts/cold-outreach/enrich-leads.sh'])
        log_signal('josh', 'josh', 'command_used', {'command': 'enrich', 'text': text[:120]})

    elif text_lower.startswith('/voice'):
        handle_voice_toggle(chat_id)

    elif text_lower.startswith('/debt'):
        handle_debt(chat_id, text)
        log_signal(actor_id, actor_id, 'command_used', {'command': 'debt', 'text': text[:120]})

    elif text_lower.startswith('/finances') or text_lower == '/finance':
        handle_finances(chat_id)
        log_signal(actor_id, actor_id, 'command_used', {'command': 'finances'})

    elif text_lower.startswith('/log '):
        handle_log_transaction(chat_id, text)
        log_signal(actor_id, actor_id, 'command_used', {'command': 'log', 'text': text[:120]})

    elif text_lower.startswith('/help') or text_lower == '/start':
        handle_help(chat_id)

    elif text_lower.startswith('research:'):
        handle_research(chat_id, text)
        log_signal(actor_id, actor_id, 'command_used', {'command': 'research', 'text': text[:200]})

    else:
        import time as _time

        # Log free-text message for adaptive memory
        log_signal(actor_id, actor_id, 'message_sent', {
            'text': text[:500],
            'length': len(text),
            'hour_utc': __import__('datetime').datetime.now(__import__('datetime').timezone.utc).hour,
        })

        pending_file = f"{WS}/tmp/telegram_pending_adjust_{chat_id}"
        if os.path.exists(pending_file):
            # Adjust requests go immediately — no batching needed
            try:
                with open(pending_file) as f:
                    email_id = f.read().strip()
                os.remove(pending_file)
                msg_text = f'Adjust the email draft for email_id={email_id}. The requested change: {text}'
                subprocess.Popen([
                    'bash', f'{WS}/scripts/telegram-claude-gateway.sh',
                    str(chat_id), msg_text, group_history_file, get_reply_mode(chat_id), user_profile,
                ], stdout=subprocess.DEVNULL, stderr=open(GATEWAY_ERR_LOG, 'a'))
            except Exception:
                pass
        else:
            # Batch: buffer the message, spawn dispatcher that waits 3s for more messages
            batch_file = f"{WS}/tmp/tg-batch-{chat_id}.txt"
            last_file  = f"{WS}/tmp/tg-batch-{chat_id}.last"

            # Append this message to the buffer (double newline as separator)
            with open(batch_file, 'a') as _bf:
                _bf.write(text + '\n\n')

            # Record when the last message arrived
            with open(last_file, 'w') as _lf:
                _lf.write(str(_time.time()))

            # Spawn a dispatcher — it sleeps 3s then fires gateway if no newer messages
            subprocess.Popen([
                'python3',
                f'{WS}/scripts/telegram-batch-dispatcher.py',
                str(chat_id),
                group_history_file,
                user_profile,
            ], stdout=subprocess.DEVNULL, stderr=open(GATEWAY_ERR_LOG, 'a'))

# advance offset
if max_update_id is not None:
    with open(os.environ['OFFSET_FILE'], 'w') as f:
        f.write(str(max_update_id + 1))
PY

done
