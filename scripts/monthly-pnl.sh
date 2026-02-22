#!/usr/bin/env bash
# monthly-pnl.sh
# Runs on the 1st of each month at 08:00 SAST.
# Reads income_entries + debt_entries, generates a P&L summary,
# sends to Josh via Telegram + posts to Mission Control notifications.

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Load secrets from env file
ENV_FILE="$(dirname "$0")/../.env.scheduler"
[[ -f "$ENV_FILE" ]] || ENV_FILE="$(dirname "$0")/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="1140320036"

export SUPABASE_URL SUPABASE_KEY BOT_TOKEN CHAT_ID

python3 - <<'PY'
import os, json, requests, datetime, sys

URL  = os.environ['SUPABASE_URL']
KEY  = os.environ['SUPABASE_KEY']
BOT  = os.environ['BOT_TOKEN']
CHAT = os.environ['CHAT_ID']

SAST = datetime.timezone(datetime.timedelta(hours=2))
now  = datetime.datetime.now(SAST)

# We're running on the 1st — report is for the month just ended
last_month = (now.replace(day=1) - datetime.timedelta(days=1))
this_month_key  = now.strftime('%Y-%m')         # current month (just started)
last_month_key  = last_month.strftime('%Y-%m')  # month we're reporting on
two_months_ago  = (last_month.replace(day=1) - datetime.timedelta(days=1)).strftime('%Y-%m')

def supa(path):
    r = requests.get(
        f"{URL}/rest/v1/{path}",
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}'},
        timeout=20
    )
    r.raise_for_status()
    return r.json()

def tg(text):
    requests.post(
        f"https://api.telegram.org/bot{BOT}/sendMessage",
        json={'chat_id': CHAT, 'text': text, 'parse_mode': 'HTML'},
        timeout=10
    )

def post_notification(title, body):
    requests.post(
        f"{URL}/rest/v1/notifications",
        headers={'apikey': KEY, 'Authorization': f'Bearer {KEY}',
                 'Content-Type': 'application/json', 'Prefer': 'return=minimal'},
        json={
            'type': 'system',
            'title': title,
            'body': body,
            'agent': 'Finance Bot',
            'priority': 'normal',
            'status': 'unread',
        },
        timeout=10
    )

def fmt_zar(amount):
    return f"R{amount:,.0f}"

print(f"Generating P&L report for {last_month_key}...")

# ── Income ────────────────────────────────────────────────────────────────────
income_last = supa(f"income_entries?month=eq.{last_month_key}&select=client,project,amount,currency,status")
income_prev = supa(f"income_entries?month=eq.{two_months_ago}&select=amount,status")

total_last  = sum(e['amount'] for e in income_last)
total_prev  = sum(e['amount'] for e in income_prev)
mom_change  = total_last - total_prev
mom_pct     = (mom_change / total_prev * 100) if total_prev else 0

# YTD (current calendar year)
year_prefix = now.strftime('%Y')
income_ytd  = supa(f"income_entries?month=like.{year_prefix}%&select=amount,status")
total_ytd   = sum(e['amount'] for e in income_ytd)

# ── Debt ──────────────────────────────────────────────────────────────────────
debts = supa("debt_entries?select=name,remaining_amount,monthly_payment,total_amount")
total_debt     = sum(d['remaining_amount'] for d in debts)
monthly_repay  = sum(d['monthly_payment']  for d in debts)

# ── Build report ──────────────────────────────────────────────────────────────
arrow    = '▲' if mom_change >= 0 else '▼'
sign     = '+' if mom_change >= 0 else ''
pct_str  = f"{sign}{mom_pct:.1f}%"
mom_str  = f"{arrow} {fmt_zar(abs(mom_change))} ({pct_str}) vs previous month"

income_lines = []
for e in sorted(income_last, key=lambda x: -x['amount']):
    flag = '✅' if e.get('status') == 'paid' else '⏳'
    income_lines.append(f"  {flag} {e['client']}: {fmt_zar(e['amount'])}")

debt_lines = []
for d in sorted(debts, key=lambda x: -x['remaining_amount']):
    months_left = int(d['remaining_amount'] / d['monthly_payment']) if d['monthly_payment'] else 0
    debt_lines.append(f"  • {d['name']}: {fmt_zar(d['remaining_amount'])} remaining (~{months_left} months)")

report_body = (
    f"💰 <b>Monthly P&L — {last_month.strftime('%B %Y')}</b>\n\n"
    f"<b>Income</b>\n"
    + '\n'.join(income_lines or ['  No entries found']) +
    f"\n\n<b>Total: {fmt_zar(total_last)}</b>\n"
    f"{mom_str}\n"
    f"YTD {year_prefix}: {fmt_zar(total_ytd)}\n\n"
    f"<b>Debt Snapshot</b>\n"
    f"Total remaining: {fmt_zar(total_debt)}\n"
    f"Monthly repayments: {fmt_zar(monthly_repay)}\n"
    + '\n'.join(debt_lines or ['  No debt entries']) +
    f"\n\n<b>Net after repayments: {fmt_zar(total_last - monthly_repay)}</b>"
)

tg(report_body)

# Post plain text version to Mission Control
plain_body = (
    f"Income {last_month.strftime('%b %Y')}: {fmt_zar(total_last)} ({pct_str} MoM) | "
    f"YTD: {fmt_zar(total_ytd)} | "
    f"Debt: {fmt_zar(total_debt)} | "
    f"Net after repayments: {fmt_zar(total_last - monthly_repay)}"
)
post_notification(f"Monthly P&L — {last_month.strftime('%B %Y')}", plain_body)

print(f"P&L report sent. Income: {fmt_zar(total_last)}, Debt: {fmt_zar(total_debt)}")
PY
