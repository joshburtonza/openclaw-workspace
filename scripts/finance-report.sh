#!/usr/bin/env bash
# finance-report.sh
# Runs on the 1st of each month at 08:00 SAST.
# Pulls last month's finance_transactions + income_entries + subscriptions
# from Supabase, groups by category, and sends a financial summary to
# Josh (1140320036) and Salah (8597169435) via Telegram.
#
# Companion to finance-poller.mjs — requires finance_transactions table
# (migration 019_finance_transactions.sql).

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
JOSH_CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
SALAH_CHAT_ID="${TELEGRAM_SALAH_CHAT_ID:-8597169435}"

export SUPABASE_URL SUPABASE_KEY BOT_TOKEN JOSH_CHAT_ID SALAH_CHAT_ID

python3 - <<'PY'
import os, json, requests, datetime, sys

URL    = os.environ['SUPABASE_URL']
KEY    = os.environ['SUPABASE_KEY']
BOT    = os.environ['BOT_TOKEN']
JOSH   = os.environ['JOSH_CHAT_ID']
SALAH  = os.environ['SALAH_CHAT_ID']

SAST   = datetime.timezone(datetime.timedelta(hours=2))
now    = datetime.datetime.now(SAST)

# Report covers the month just ended
last_m = (now.replace(day=1) - datetime.timedelta(days=1))
month_key   = last_m.strftime('%Y-%m')   # e.g. 2026-02
month_label = last_m.strftime('%B %Y')   # e.g. February 2026
month_start = f"{month_key}-01"
month_end   = now.replace(day=1).strftime('%Y-%m-%d')  # exclusive

print(f"Generating finance report for {month_label}...")

headers = {
    'apikey': KEY,
    'Authorization': f'Bearer {KEY}',
    'Content-Type': 'application/json',
}

def supa_get(path):
    r = requests.get(f"{URL}/rest/v1/{path}", headers=headers, timeout=30)
    if r.status_code != 200:
        print(f"  Supabase error {r.status_code}: {r.text[:200]}", file=sys.stderr)
        return []
    return r.json()

def tg(text, chat_ids):
    for cid in chat_ids:
        try:
            requests.post(
                f"https://api.telegram.org/bot{BOT}/sendMessage",
                json={'chat_id': cid, 'text': text, 'parse_mode': 'HTML'},
                timeout=15
            )
        except Exception as e:
            print(f"  TG error: {e}", file=sys.stderr)

def fmt(n):
    return f"R{abs(n):,.0f}"

# ── Pull finance_transactions for last month ───────────────────────────────────
txns = supa_get(
    f"finance_transactions?date=gte.{month_start}&date=lt.{month_end}"
    f"&select=type,amount,category,description,account_type,matched_client,matched_sub,balance_after,date"
    f"&order=date.asc&limit=5000"
)
print(f"  Pulled {len(txns)} transactions")

# ── Pull income_entries for last month ────────────────────────────────────────
income_entries = supa_get(
    f"income_entries?month=eq.{month_key}&select=client,project,amount,status"
)
print(f"  Pulled {len(income_entries)} income entries")

# ── Pull active subscriptions ─────────────────────────────────────────────────
subs_db = supa_get("subscriptions?status=eq.active&select=name,amount,category")
print(f"  Pulled {len(subs_db)} active subscriptions")

# ── Aggregate transactions ────────────────────────────────────────────────────
CATEGORIES = ['Income', 'Subscription', 'Hardware', 'Drawings', 'Bank Fees', 'Other']

totals     = {c: 0.0 for c in CATEGORIES}
cat_items  = {c: []  for c in CATEGORIES}
unknown_charges = []
closing_balance = None

for tx in txns:
    amt  = float(tx.get('amount', 0))
    cat  = tx.get('category') or 'Other'
    txtp = tx.get('type', 'expense')
    desc = tx.get('description', '')
    bal  = tx.get('balance_after')
    if bal is not None:
        closing_balance = float(bal)

    if cat not in totals:
        cat = 'Other'

    if txtp == 'income':
        totals['Income'] += amt
        mc = tx.get('matched_client')
        if mc:
            cat_items['Income'].append(f"{mc}: {fmt(amt)}")
    else:
        totals[cat] += amt
        if cat == 'Subscription' and tx.get('matched_sub'):
            cat_items['Subscription'].append(f"{tx['matched_sub']}: {fmt(amt)}")
        elif cat == 'Other':
            unknown_charges.append(f"{tx.get('date','')}: {fmt(amt)} {desc[:40]}")

total_income  = totals['Income']
total_expense = sum(totals[c] for c in CATEGORIES if c != 'Income')
net           = total_income - total_expense
drawings      = totals['Drawings']

# ── Income entries summary ────────────────────────────────────────────────────
paid_entries    = [e for e in income_entries if e.get('status') == 'paid']
pending_entries = [e for e in income_entries if e.get('status') != 'paid']
paid_total      = sum(float(e['amount']) for e in paid_entries)
pending_total   = sum(float(e['amount']) for e in pending_entries)

# ── Subscription budget vs actual ─────────────────────────────────────────────
sub_budget  = sum(float(s['amount']) for s in subs_db)
sub_actual  = totals['Subscription']
sub_delta   = sub_actual - sub_budget

# ── Build report ──────────────────────────────────────────────────────────────
sep = "\n"

income_lines = sep.join(cat_items['Income'][:10]) if cat_items['Income'] else "  (no FNB credits matched to clients)"
sub_lines    = sep.join(f"  {l}" for l in cat_items['Subscription'][:12]) if cat_items['Subscription'] else "  (no subscription charges found)"

# income entries block
ie_paid_lines    = sep.join(f"  {e['client']}: {fmt(float(e['amount']))}" for e in paid_entries[:10])
ie_pending_lines = sep.join(f"  {e['client']}: {fmt(float(e['amount']))}" for e in pending_entries[:10])
ie_block = ""
if income_entries:
    ie_block = (
        f"\nINVOICE TRACKER\n"
        f"  Paid: {fmt(paid_total)} ({len(paid_entries)} invoices)\n"
        + (f"{ie_paid_lines}\n" if ie_paid_lines else "")
        + (f"  Pending: {fmt(pending_total)} ({len(pending_entries)} invoices)\n" if pending_entries else "")
        + (f"{ie_pending_lines}\n" if ie_pending_lines else "")
    )

unknown_block = ""
if unknown_charges:
    unk_lines = sep.join(f"  {l}" for l in unknown_charges[:6])
    unknown_block = f"\nUNKNOWN CHARGES ({len(unknown_charges)} items)\n{unk_lines}\n"
elif txns:
    unknown_block = "\nUNKNOWN CHARGES: none\n"

sub_audit_line = (
    f"  Budget: {fmt(sub_budget)}/month ({len(subs_db)} services)\n"
    f"  Actual charged: {fmt(sub_actual)}"
    + (f" (+{fmt(sub_delta)} over budget)" if sub_delta > 0 else f" ({fmt(abs(sub_delta))} under budget)" if sub_delta < 0 else "")
)

report = (
    f"<b>AMALFI AI — FINANCIAL SUMMARY {month_label.upper()}</b>\n\n"
    f"<b>INCOME</b>: {fmt(total_income)} ({len([t for t in txns if t['type']=='income'])} credits)\n"
    + (sep.join(f"  {l}" for l in cat_items['Income'][:10]) + "\n" if cat_items['Income'] else "")
    + f"\n<b>EXPENSES</b>: {fmt(total_expense)}\n"
    f"  Subscriptions: {fmt(totals['Subscription'])}\n"
    f"  Hardware: {fmt(totals['Hardware'])}\n"
    f"  Bank fees: {fmt(totals['Bank Fees'])}\n"
    f"  Other: {fmt(totals['Other'])}\n"
    + f"\n<b>DRAWINGS</b>: {fmt(drawings)}\n"
    f"<b>NET</b>: {fmt(net)}\n"
    + (f"<b>CLOSING BALANCE</b>: {fmt(closing_balance)}\n" if closing_balance is not None else "")
    + ie_block
    + f"\n<b>SUBSCRIPTION AUDIT</b>\n{sub_audit_line}\n"
    + (f"\nCharges this month:\n{sub_lines}\n" if cat_items['Subscription'] else "")
    + unknown_block
)

print("Report built — sending to Telegram...")
tg(report, [JOSH, SALAH])
print(f"Report sent. Net: {fmt(net)}, Income: {fmt(total_income)}, Expenses: {fmt(total_expense)}")
PY
