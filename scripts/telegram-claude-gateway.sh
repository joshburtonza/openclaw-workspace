#!/bin/bash
# telegram-claude-gateway.sh
# Routes a Telegram message to Claude Code and sends the response back.
#
# Usage: telegram-claude-gateway.sh <chat_id> <message_text>
#
# Called by telegram-callback-poller.sh for free-text messages.
# Maintains conversation history in tmp/telegram-chat-history.jsonl

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

CHAT_ID="${1:-}"
USER_MSG="${2:-}"
GROUP_HISTORY_FILE="${3:-}"   # optional: path to group chat history jsonl
REPLY_MODE="${4:-text}"       # "audio" → send MiniMax TTS voice note; "text" → plain text
USER_PROFILE="${5:-josh}"     # "josh" (full access) | "salah" (consumer only)

if [[ -z "$CHAT_ID" || -z "$USER_MSG" ]]; then
  echo "Usage: $0 <chat_id> <message> [group_history_file]" >&2
  exit 1
fi

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
export BOT_TOKEN

# ── Helper functions (defined early so command blocks can use them) ───────────
tg_send() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{
      \"chat_id\": \"${CHAT_ID}\",
      \"text\": $(echo "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),
      \"parse_mode\": \"Markdown\"
    }" >/dev/null 2>&1 || true
}

tg_typing() {
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendChatAction" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": \"${CHAT_ID}\", \"action\": \"typing\"}" >/dev/null 2>&1 || true
}

# ── /flight command ───────────────────────────────────────────────────────────
# Search for flights via Playwright.
# Usage: /flight CPT to JNB on 2026-03-06
#        /flight CPT to JNB on Friday [airline lift|flysafair]

if echo "$USER_MSG" | grep -qi '^\s*/flight'; then
  FLIGHT_ARGS=$(echo "$USER_MSG" | sed 's|^\s*/flight\s*||i')

  # ── Smart natural-language parser ────────────────────────────────────────────
  # Handles: city names, "next week", "2 tickets", return dates, airline names
  export _FL_MSG="$FLIGHT_ARGS"
  _FL_PARSED=$(python3 - <<'PYPARSE'
import re, datetime, json, os

msg = os.environ.get('_FL_MSG', '').lower()

CITIES = {
  # Cape Town
  'cape town':'CPT','capetown':'CPT','cpt':'CPT',
  # Johannesburg
  'johannesburg':'JNB','johanesburg':'JNB','joburg':'JNB',
  'jozi':'JNB','jhb':'JNB','jnb':'JNB','or tambo':'JNB','tambo':'JNB',
  # Durban
  'durban':'DUR','dur':'DUR','king shaka':'DUR','dbn':'DUR',
  # Port Elizabeth / Gqeberha
  'port elizabeth':'PLZ','pe':'PLZ','plz':'PLZ','gqeberha':'PLZ',
  # East London
  'east london':'ELS','els':'ELS',
  # George
  'george':'GRJ','grj':'GRJ',
  # Lanseria
  'lanseria':'HLA','hla':'HLA',
  # Bloemfontein
  'bloemfontein':'BFN','bfn':'BFN','bloem':'BFN',
}
DAYS = ['monday','tuesday','wednesday','thursday','friday','saturday','sunday']

def next_weekday(day_name, next_week=False):
  today = datetime.date.today()
  target = DAYS.index(day_name.lower())
  if next_week:
    # "next week X" = the occurrence in the calendar week starting next Monday
    days_to_next_monday = (7 - today.weekday()) % 7 or 7
    next_monday = today + datetime.timedelta(days=days_to_next_monday)
    return (next_monday + datetime.timedelta(days=target)).isoformat()
  else:
    diff = (target - today.weekday()) % 7 or 7
    return (today + datetime.timedelta(days=diff)).isoformat()

def resolve_city(text):
  text = text.strip().lower()
  return CITIES.get(text)

# Passenger count
adults = 1
m = re.search(r'(\d+)\s*(?:ticket|adult|person|people|passenger)', msg)
if m: adults = int(m.group(1))

# "Next week" flag
next_week = bool(re.search(r'next\s+week', msg))

# Explicit ISO dates
explicit_dates = re.findall(r'\d{4}-\d{2}-\d{2}', msg)

# Day name mentions in order
day_mentions = re.findall(r'\b(' + '|'.join(DAYS) + r')\b', msg)

# Resolve outbound date
out_date = None
if explicit_dates:
  out_date = explicit_dates[0]
elif day_mentions:
  out_date = next_weekday(day_mentions[0], next_week=next_week)

# Resolve return date
# Look for keyword: "return/returning/back/to [day/date]" (the "to" between two days)
ret_date = None
if len(explicit_dates) >= 2:
  ret_date = explicit_dates[1]
else:
  # Check for return keyword + date/day
  m = re.search(r'(return(?:ing)?|back)\s+(?:on\s+)?(\d{4}-\d{2}-\d{2})', msg)
  if m: ret_date = m.group(2)
  if not ret_date:
    m = re.search(r'(return(?:ing)?|back)\s+(?:on\s+)?(' + '|'.join(DAYS) + r')\b', msg)
    if m: ret_date = next_weekday(m.group(2), next_week=next_week)
  # Two day names with "to" between them (e.g. "monday to thursday")
  if not ret_date and len(day_mentions) >= 2:
    m = re.search(r'\b(' + '|'.join(DAYS) + r')\s+to\s+(' + '|'.join(DAYS) + r')\b', msg)
    if m: ret_date = next_weekday(m.group(2), next_week=next_week)

# Ensure return is after outbound
if ret_date and out_date and ret_date <= out_date:
  ret_date = None

# Extract cities — try "from X to Y" first, then scan for city names
from_code = None
to_code   = None

m = re.search(r'\bfrom\s+(.+?)\s+to\s+(.+?)(?:\s+on\b|\s+\d|\s*$)', msg)
if m:
  from_code = resolve_city(m.group(1))
  to_code   = resolve_city(m.group(2))

if not from_code or not to_code:
  # Scan for city name occurrences in order
  found = []
  msg_work = msg
  for city in sorted(CITIES.keys(), key=len, reverse=True):
    pos = msg_work.find(city)
    if pos >= 0:
      code = CITIES[city]
      if code not in [c[1] for c in found]:
        found.append((pos, code))
        msg_work = msg_work[:pos] + ' ' * len(city) + msg_work[pos+len(city):]
  found.sort(key=lambda x: x[0])
  if not from_code and found:       from_code = found[0][1]
  if not to_code   and len(found)>1: to_code   = found[1][1]

from_code = from_code or 'CPT'
to_code   = to_code   or 'JNB'
if not out_date:
  out_date = (datetime.date.today() + datetime.timedelta(days=1)).isoformat()

# Explicit airline override
airline_override = ''
if re.search(r'\b(flysafair|safair)\b', msg): airline_override = 'flysafair'
elif re.search(r'\blift\b', msg):             airline_override = 'lift'

# Lift can only fly CPT/JNB/DUR
LIFT_ROUTES = {'CPT-JNB','JNB-CPT','CPT-DUR','DUR-CPT','JNB-DUR','DUR-JNB'}
route = from_code + '-' + to_code
lift_ok = route in LIFT_ROUTES

print(json.dumps({
  'from': from_code, 'to': to_code,
  'date': out_date,  'return': ret_date,
  'adults': adults,
  'airline_override': airline_override,
  'lift_ok': lift_ok,
  'route': route,
}))
PYPARSE
2>/dev/null || echo '{"from":"CPT","to":"JNB","date":"","return":null,"adults":1,"airline_override":"","lift_ok":true,"route":"CPT-JNB"}')

  FLIGHT_FROM=$(echo "$_FL_PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin).get('from','CPT'))"    2>/dev/null || echo "CPT")
  FLIGHT_TO=$(echo "$_FL_PARSED"   | python3 -c "import sys,json; print(json.load(sys.stdin).get('to','JNB'))"      2>/dev/null || echo "JNB")
  FLIGHT_DATE=$(echo "$_FL_PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin).get('date',''))"       2>/dev/null || echo "")
  RETURN_DATE=$(echo "$_FL_PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin).get('return') or '')"  2>/dev/null || echo "")
  ADULTS=$(echo "$_FL_PARSED"      | python3 -c "import sys,json; print(json.load(sys.stdin).get('adults',1))"      2>/dev/null || echo "1")
  LIFT_OK=$(echo "$_FL_PARSED"     | python3 -c "import sys,json; print('yes' if json.load(sys.stdin).get('lift_ok') else 'no')" 2>/dev/null || echo "yes")
  FORCE_AIRLINE=$(echo "$_FL_PARSED" | python3 -c "import sys,json; print(json.load(sys.stdin).get('airline_override',''))" 2>/dev/null || echo "")

  # If Lift can't fly this route and no override → auto FlySafair
  if [[ "$LIFT_OK" == "no" && -z "$FORCE_AIRLINE" ]]; then
    FORCE_AIRLINE="flysafair"
  fi
  # If FlySafair forced on a Lift route, still use FlySafair
  # If Lift forced on a non-Lift route, warn (but try anyway)

  [[ -z "$FLIGHT_DATE" ]] && FLIGHT_DATE=$(date -v+1d '+%Y-%m-%d' 2>/dev/null || date --date='tomorrow' '+%Y-%m-%d')

  # Confirm what we understood
  _CONFIRM="Searching: *${FLIGHT_FROM} \u2192 ${FLIGHT_TO}*  ${FLIGHT_DATE}"
  [[ -n "$RETURN_DATE" ]] && _CONFIRM="${_CONFIRM}, return ${RETURN_DATE}"
  [[ "$ADULTS" -gt 1 ]]   && _CONFIRM="${_CONFIRM}  (${ADULTS} pax)"
  [[ -n "$FORCE_AIRLINE" ]] && _CONFIRM="${_CONFIRM}  via ${FORCE_AIRLINE^}"
  tg_send "$_CONFIRM"

  # ── Run searches ─────────────────────────────────────────────────────────────
  _run_search() {
    node "$WS/scripts/flights/search-flights.mjs" \
      --from "$1" --to "$2" --date "$3" --airline "$4" --adults "$ADULTS" 2>/dev/null \
    || echo '{"ok":false,"from":"'$1'","to":"'$2'","date":"'$3'","flights":[]}'
  }

  _fmt_legs() {
    python3 - <<'PYFMT'
import json, os, re

def pp(p):
    return int(re.sub(r'[^\d]', '', str(p)) or '999999')

def fmt(flights, frm, to, date, label, pax):
    if not flights:
        return f"No {label} flights {frm}\u2192{to} on {date}."
    cheapest = min(pp(f.get('price')) for f in flights)
    pax_note = f" ({pax}x)" if pax > 1 else ""
    lines = [f"*{label}: {frm} \u2192 {to} | {date}{pax_note}*"]
    for i, f in enumerate(flights[:7], 1):
        dep=f.get('departure',''); arr=f.get('arrival','')
        fnum=f.get('flight','');   price=f.get('price','')
        al=f.get('airline','')
        cheap = ' \u2190' if pp(price) == cheapest else ''
        al_tag = f" ({al})" if al else ""
        lines.append(f"{i}. {dep}\u2192{arr}  {fnum}{al_tag}  *{price}*{cheap}")
    return '\n'.join(lines)

pax  = int(os.environ.get('_ADULTS','1'))
out  = json.loads(os.environ.get('_OUT_JSON', '{"ok":false,"flights":[]}'))
ret  = json.loads(os.environ.get('_RET_JSON', ''))  if os.environ.get('_RET_JSON') else None

out_txt = fmt(out.get('flights',[]), out.get('from',''), out.get('to',''), out.get('date',''), 'Outbound', pax)

if ret is not None:
    ret_txt = fmt(ret.get('flights',[]), os.environ.get('_RET_FROM',''), os.environ.get('_RET_TO',''),
                  os.environ.get('_RET_DATE',''), 'Return', pax)
    out_cheap = min((pp(f.get('price')) for f in out.get('flights',[])), default=0)
    ret_cheap = min((pp(f.get('price')) for f in ret.get('flights',[])), default=0)
    combo = out_cheap + ret_cheap
    total_pax = out_cheap * pax + ret_cheap * pax
    combo_txt = f"\nCheapest combo: *R{out_cheap:,} + R{ret_cheap:,} = R{combo:,}*"
    if pax > 1: combo_txt += f"  (x{pax} = R{total_pax:,})"
    print(out_txt + '\n\n' + ret_txt + combo_txt)
else:
    print(out_txt)
PYFMT
  }

  export _ADULTS="$ADULTS"

  # Helper: run search, write JSON to a temp file (works in background)
  _run_search_to() {
    local out_file="$5"
    _run_search "$1" "$2" "$3" "$4" > "$out_file" 2>/dev/null
  }

  _call_fmt() {
    _fmt_legs 2>/dev/null
  }

  if [[ -n "$RETURN_DATE" ]]; then
    # Return trip — parallel outbound + return leg via temp files
    _AL="${FORCE_AIRLINE:-lift}"
    _OUT_TMP=$(mktemp /tmp/flight-out-XXXXXX)
    _RET_TMP=$(mktemp /tmp/flight-ret-XXXXXX)
    _run_search_to "$FLIGHT_FROM" "$FLIGHT_TO"   "$FLIGHT_DATE"  "$_AL" "$_OUT_TMP" &
    _run_search_to "$FLIGHT_TO"   "$FLIGHT_FROM" "$RETURN_DATE"  "$_AL" "$_RET_TMP" &
    wait
    export _OUT_JSON; _OUT_JSON=$(cat "$_OUT_TMP")
    export _RET_JSON; _RET_JSON=$(cat "$_RET_TMP")
    rm -f "$_OUT_TMP" "$_RET_TMP"

  elif [[ -n "$FORCE_AIRLINE" ]]; then
    export _OUT_JSON
    _OUT_JSON=$(_run_search "$FLIGHT_FROM" "$FLIGHT_TO" "$FLIGHT_DATE" "$FORCE_AIRLINE")

  else
    # Both airlines in parallel — merge + sort via temp files
    _LIFT_TMP=$(mktemp /tmp/flight-lift-XXXXXX)
    _SAFE_TMP=$(mktemp /tmp/flight-safe-XXXXXX)
    _run_search_to "$FLIGHT_FROM" "$FLIGHT_TO" "$FLIGHT_DATE" "lift"      "$_LIFT_TMP" &
    _run_search_to "$FLIGHT_FROM" "$FLIGHT_TO" "$FLIGHT_DATE" "flysafair" "$_SAFE_TMP" &
    wait
    export _LIFT_JSON; _LIFT_JSON=$(cat "$_LIFT_TMP")
    export _SAFAIR_JSON; _SAFAIR_JSON=$(cat "$_SAFE_TMP")
    rm -f "$_LIFT_TMP" "$_SAFE_TMP"
    export _OUT_JSON
    _OUT_JSON=$(python3 - <<'PYMERGE'
import json, os, re
def pp(p): return int(re.sub(r'[^\d]', '', str(p)) or '999999')
lift   = json.loads(os.environ.get('_LIFT_JSON',   '{"ok":false,"flights":[]}'))
safair = json.loads(os.environ.get('_SAFAIR_JSON', '{"ok":false,"flights":[]}'))
combined = []
for f in (lift.get('flights') or []):   f['airline']='Lift';     combined.append(f)
for f in (safair.get('flights') or []): f['airline']='FlySafair'; combined.append(f)
combined.sort(key=lambda x: pp(x.get('price')))
print(json.dumps({"ok":True, "from":lift.get('from') or safair.get('from',''),
  "to":lift.get('to') or safair.get('to',''), "date":lift.get('date') or safair.get('date',''),
  "flights":combined}))
PYMERGE
)
  fi

  # ── Send cheapest flight card with inline Book / Cancel buttons ──────────────
  export _CHAT_ID="$CHAT_ID"
  python3 - <<'PYBOOK'
import json, os, re, requests

def pp(p): return int(re.sub(r'[^\d]', '', str(p)) or '999999')

BOT_TOKEN = os.environ.get('BOT_TOKEN', '')
CHAT_ID   = os.environ.get('_CHAT_ID', '')
ADULTS    = int(os.environ.get('_ADULTS', '1'))
WS = os.environ.get('AOS_ROOT', '/Users/henryburton/.openclaw/workspace-anthropic')

try:
    out = json.loads(os.environ.get('_OUT_JSON', '{}'))
except Exception:
    out = {}

ret_raw = os.environ.get('_RET_JSON', '') or None
ret = None
if ret_raw:
    try:
        ret = json.loads(ret_raw)
    except Exception:
        pass

out_flights = out.get('flights') or []
ret_flights = (ret.get('flights') or []) if ret else []

if not out_flights:
    requests.post(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        json={'chat_id': CHAT_ID,
              'text': f"No flights found for {out.get('from','?')} \u2192 {out.get('to','?')} on {out.get('date','?')}."},
        timeout=10
    )
    raise SystemExit(0)

cheapest_out = min(out_flights, key=lambda f: pp(f.get('price')))
cheapest_ret = min(ret_flights, key=lambda f: pp(f.get('price'))) if ret_flights else None

def flight_card(f, frm, to):
    dep  = f.get('departure', '?'); arr = f.get('arrival', '?')
    dur  = f.get('duration') or '';  fnum = f.get('flight', '?')
    prc  = f.get('price', '?');      al = f.get('airline') or ''
    dur_str = f' ({dur})' if dur else ''
    al_str  = f' | {al}' if al else ''
    prc_n   = pp(prc)
    pax_str = f' \u00d7{ADULTS} = *R{prc_n*ADULTS:,}*' if ADULTS > 1 else ''
    return (f'*{fnum}*  {frm} \u2192 {to}\n'
            f'\U0001f554 {dep} \u2192 {arr}{dur_str}{al_str}\n'
            f'\U0001f4b0 *{prc}*{pax_str}')

lines = [f'\u2708\ufe0f *{out.get("date","?")}* \u2014 cheapest option\n']
lines.append(flight_card(cheapest_out, out.get('from', ''), out.get('to', '')))

if cheapest_ret:
    lines.append('')
    lines.append('\U0001f504 *Return:*')
    lines.append(flight_card(cheapest_ret, ret.get('from', ''), ret.get('to', '')))
    total = pp(cheapest_out.get('price')) + pp(cheapest_ret.get('price'))
    lines.append(f'\n\U0001f4b5 *Combined: R{total:,}*'
                 + (f' \u00d7{ADULTS} = *R{total*ADULTS:,}*' if ADULTS > 1 else ''))

lines.append('\nTap \u2708\ufe0f to book or \u2716 to cancel.')

# Determine airline for booking
al_raw = (cheapest_out.get('airline') or out.get('airline') or '').lower()
airline = 'lift' if al_raw == 'lift' else 'flysafair'

# Save pending booking
pending = {
    'airline':        airline,
    'from':           out.get('from'),
    'to':             out.get('to'),
    'date':           out.get('date'),
    'flight':         cheapest_out.get('flight'),
    'price':          cheapest_out.get('price'),
    'adults':         ADULTS,
    'return_date':    ret.get('date')   if ret else None,
    'return_from':    ret.get('from')   if ret else None,
    'return_to':      ret.get('to')     if ret else None,
    'return_flight':  cheapest_ret.get('flight') if cheapest_ret else None,
    'return_price':   cheapest_ret.get('price')  if cheapest_ret else None,
    'return_airline': ((cheapest_ret.get('airline') or airline).lower()
                       if cheapest_ret else None),
}
os.makedirs(f'{WS}/tmp', exist_ok=True)
with open(f'{WS}/tmp/pending-flight-{CHAT_ID}.json', 'w') as _pf:
    json.dump(pending, _pf)

requests.post(
    f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
    json={
        'chat_id':    CHAT_ID,
        'text':       '\n'.join(lines),
        'parse_mode': 'Markdown',
        'reply_markup': {
            'inline_keyboard': [[
                {'text': 'Book it \u2708\ufe0f', 'callback_data': f'book_flight:{CHAT_ID}'},
                {'text': 'Cancel \u2716',         'callback_data': f'book_cancel:{CHAT_ID}'},
            ]]
        },
    },
    timeout=10
)
PYBOOK

  exit 0
fi

# ── /reply wa [contact] [message] command ─────────────────────────────────────
# Sends a WhatsApp message via the Business Cloud API.
# Usage: /reply wa ascend_lc Invoice sent — please confirm receipt.
#        /reply wa +27761234567 Hey, just following up.

if echo "$USER_MSG" | grep -qi '^\s*/reply wa '; then
  WA_ARGS=$(echo "$USER_MSG" | sed 's|^\s*/reply wa ||i')
  CONTACT_RAW=$(echo "$WA_ARGS" | awk '{print $1}')
  WA_TEXT=$(echo "$WA_ARGS" | cut -d' ' -f2-)

  # Resolve contact slug or raw number from contacts.json
  TO_NUMBER=""
  CONTACT_DISPLAY=""
  if echo "$CONTACT_RAW" | grep -qE '^\+?[0-9]{7,}$'; then
    # Raw number provided
    TO_NUMBER="$CONTACT_RAW"
    CONTACT_DISPLAY="$CONTACT_RAW"
  else
    # Look up slug in contacts.json
    CONTACTS_JSON="$WS/data/contacts.json"
    if [[ -f "$CONTACTS_JSON" ]]; then
      LOOKUP=$(python3 -c "
import json, sys
slug = '${CONTACT_RAW}'.lower()
data = json.load(open('${CONTACTS_JSON}'))
for c in data.get('clients', []):
    if c.get('slug','').lower() == slug or c.get('name','').lower().replace(' ','_') == slug:
        print(c.get('number','') + '|' + c.get('name',''))
        sys.exit(0)
print('|')
" 2>/dev/null || echo "|")
      TO_NUMBER="${LOOKUP%%|*}"
      CONTACT_DISPLAY="${LOOKUP##*|}"
    fi
  fi

  tg_send_cmd() {
    local text="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" \
      -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(echo "$text" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))'),\"parse_mode\":\"Markdown\"}" >/dev/null 2>&1 || true
  }

  if [[ -z "$TO_NUMBER" || -z "$WA_TEXT" || "$TO_NUMBER" == "|" ]]; then
    tg_send_cmd "⚠️ Usage: \`/reply wa [contact_slug_or_number] [message]\`

Known contacts: $(python3 -c "
import json
try:
    data = json.load(open('$WS/data/contacts.json'))
    for c in data.get('clients',[]): print('  •', c.get('slug',''), '—', c.get('name',''))
except: print('  (could not load contacts.json)')
" 2>/dev/null)"
    exit 0
  fi

  if [[ "${WHATSAPP_TOKEN:-REPLACE_WITH_WHATSAPP_ACCESS_TOKEN}" == "REPLACE_WITH_WHATSAPP_ACCESS_TOKEN" || -z "${WHATSAPP_TOKEN:-}" ]]; then
    tg_send_cmd "⚠️ WhatsApp not configured. Set WHATSAPP_TOKEN and WHATSAPP_PHONE_ID in .env.scheduler."
    exit 0
  fi

  WA_RESP=$(curl -s -X POST \
    "https://graph.facebook.com/v21.0/${WHATSAPP_PHONE_ID}/messages" \
    -H "Authorization: Bearer ${WHATSAPP_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{\"messaging_product\":\"whatsapp\",\"to\":\"${TO_NUMBER}\",\"type\":\"text\",\"text\":{\"body\":$(echo "$WA_TEXT" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}}")

  WA_OK=$(echo "$WA_RESP" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print('ok' if d.get('messages') else 'fail')" 2>/dev/null || echo "fail")

  if [[ "$WA_OK" == "ok" ]]; then
    tg_send_cmd "✅ WhatsApp sent to *${CONTACT_DISPLAY:-$TO_NUMBER}*: \"${WA_TEXT}\""
  else
    ERR=$(echo "$WA_RESP" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('error',{}).get('message','unknown error'))" 2>/dev/null || echo "unknown error")
    tg_send_cmd "❌ WhatsApp send failed: ${ERR}"
  fi
  exit 0
fi

# ── /image command ────────────────────────────────────────────────────────────
# Generate an image via FLUX.1-schnell (HuggingFace Inference API).
# Usage: /image a futuristic cityscape at sunset

if echo "$USER_MSG" | grep -qi '^\s*/image'; then
  IMG_PROMPT=$(echo "$USER_MSG" | sed 's|^\s*/image\s*||i')

  if [[ -z "$IMG_PROMPT" ]]; then
    tg_send "Usage: /image <prompt>"
    exit 0
  fi

  tg_send "Generating image..."

  # Show upload_photo action
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendChatAction" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": \"${CHAT_ID}\", \"action\": \"upload_photo\"}" >/dev/null 2>&1 || true

  IMG_OUT="/tmp/tg-image-${CHAT_ID}-$(date +%s).png"
  export HUGGINGFACE_API_KEY

  if python3 "$WS/scripts/hf-image-gen.py" "$IMG_PROMPT" "$IMG_OUT" 2>>"$WS/out/gateway-errors.log"; then
    # Send the image
    IMG_RESP=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendPhoto" \
      -F "chat_id=${CHAT_ID}" \
      -F "photo=@${IMG_OUT}" \
      -F "caption=$(echo "$IMG_PROMPT" | cut -c1-200)" 2>/dev/null || echo "")
    IMG_OK=$(echo "$IMG_RESP" | python3 -c "import sys,json; print('ok' if json.load(sys.stdin).get('ok') else 'fail')" 2>/dev/null || echo "fail")

    if [[ "$IMG_OK" != "ok" ]]; then
      tg_send "Image generated but upload failed. Try again."
    fi
  else
    tg_send "Image generation failed. Try a different prompt."
  fi

  rm -f "$IMG_OUT" 2>/dev/null || true
  exit 0
fi

# ── /os command — Client OS kill switch ───────────────────────────────────────
# Usage: /os                    → list all clients + status
#        /os pause <slug>       → pause client (outbound stops, monitoring stays)
#        /os stop <slug>        → stop all agents (except daemon)
#        /os resume <slug>      → resume all agents

if echo "$USER_MSG" | grep -qi '^\s*/os\b'; then
  OS_ARGS=$(echo "$USER_MSG" | sed 's|^\s*/os\s*||i' | xargs)
  OS_ACTION=$(echo "$OS_ARGS" | awk '{print tolower($1)}')
  OS_SLUG=$(echo "$OS_ARGS" | awk '{print tolower($2)}')

  export _SUPA_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
  export _SUPA_KEY="$SUPABASE_SERVICE_ROLE_KEY"
  export _OS_ACTION="$OS_ACTION"
  export _OS_SLUG="$OS_SLUG"

  OS_RESULT=$(python3 << 'PYOS'
import json, os, urllib.request, datetime

URL  = os.environ.get('_SUPA_URL', 'https://afmpbtynucpbglwtbfuz.supabase.co')
KEY  = os.environ.get('_SUPA_KEY', '')
ACT  = os.environ.get('_OS_ACTION', '')
SLUG = os.environ.get('_OS_SLUG', '')

def supa(method, path, data=None):
    url = f"{URL}/rest/v1/{path}"
    body = json.dumps(data).encode() if data else None
    req = urllib.request.Request(url, data=body, method=method, headers={
        'apikey': KEY,
        'Authorization': f'Bearer {KEY}',
        'Content-Type': 'application/json',
        'Prefer': 'return=representation',
    })
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception as e:
        return None

def time_since(iso):
    if not iso: return 'never'
    try:
        dt = datetime.datetime.fromisoformat(iso.replace('Z','+00:00'))
        diff = datetime.datetime.now(datetime.timezone.utc) - dt
        mins  = int(diff.total_seconds() // 60)
        hours = mins // 60
        days  = hours // 24
        if days > 0:  return f'{days}d ago'
        if hours > 0: return f'{hours}h ago'
        if mins > 0:  return f'{mins}m ago'
        return 'just now'
    except:
        return 'unknown'

STATUS_EMOJI = {'active': '🟢', 'paused': '🟡', 'stopped': '🔴'}
RETAINER_EMOJI = {'active': '✅', 'overdue': '⚠️', 'cancelled': '❌'}

if ACT in ('pause', 'stop', 'resume', 'active'):
    if not SLUG:
        print('Usage: /os pause|stop|resume <client_slug>')
    else:
        new_status = 'active' if ACT == 'resume' else ACT
        rows = supa('PATCH',
            f'client_os_registry?slug=eq.{SLUG}',
            {
                'status': new_status,
                'status_changed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'status_changed_by': 'telegram_josh',
            })
        if rows:
            name = rows[0].get('name', SLUG)
            emoji = STATUS_EMOJI.get(new_status, '?')
            print(f'{emoji} {name} set to *{new_status}*\nClient daemon will enforce within 5 min.')
        else:
            print(f'Client not found: {SLUG}\nCheck slug spelling.')
else:
    # List all clients
    rows = supa('GET', 'client_os_registry?select=*&order=name') or []
    if not rows:
        print('No clients in registry.')
    else:
        lines = ['*Client OS Registry*', '']
        for c in rows:
            st  = c.get('status', 'unknown')
            ret = c.get('retainer_status', 'unknown')
            hb  = time_since(c.get('last_heartbeat'))
            mo  = int(c.get('monthly_amount') or 0)
            se  = STATUS_EMOJI.get(st, '?')
            re  = RETAINER_EMOJI.get(ret, '?')
            lines.append(f"{se} *{c['name']}* (`{c['slug']}`)")
            lines.append(f"  Status: {st} | Retainer: {re} {ret}")
            lines.append(f"  Heartbeat: {hb} | R{mo:,}/mo")
            lines.append('')
        lines.append('Commands: `/os pause <slug>` `/os stop <slug>` `/os resume <slug>`')
        print('\n'.join(lines))
PYOS
)

  tg_send "$OS_RESULT"
  exit 0
fi

# Route to per-user system prompt and isolated history
if [[ "$USER_PROFILE" == "salah" ]]; then
  SYSTEM_PROMPT_FILE="$WS/prompts/telegram-salah-system.md"
  HISTORY_FILE="$WS/tmp/telegram-salah-history.jsonl"
  USER_DISPLAY="Salah"
else
  SYSTEM_PROMPT_FILE="$WS/prompts/telegram-claude-system.md"
  HISTORY_FILE="$WS/tmp/telegram-chat-history.jsonl"
  USER_DISPLAY="Josh"
fi
mkdir -p "$WS/tmp"

# In group chats: small random delay to avoid responding simultaneously with other bots
if [[ -n "$GROUP_HISTORY_FILE" ]]; then
  sleep $(python3 -c "import random; print(round(random.uniform(1.0, 2.5), 1))")
fi

# (tg_send and tg_typing defined above near top of file)

# ── Build conversation history ────────────────────────────────────────────────
HISTORY=""

if [[ -n "$GROUP_HISTORY_FILE" && -f "$GROUP_HISTORY_FILE" ]]; then
  # Group chat: use shared history (includes messages from all bots + humans)
  HISTORY=$(tail -40 "$GROUP_HISTORY_FILE" | python3 -c "
import sys, json
lines = [l.strip() for l in sys.stdin if l.strip()]
parts = []
for line in lines:
    try:
        obj = json.loads(line)
        role = obj.get('role','?')
        msg  = obj.get('message','')
        ts   = obj.get('ts','')
        prefix = f'[{ts}] ' if ts else ''
        parts.append(f'{prefix}{role}: {msg}')
    except:
        pass
print('\n'.join(parts))
" 2>/dev/null) || true
elif [[ -f "$HISTORY_FILE" ]]; then
  # Private chat: use personal history
  HISTORY=$(tail -20 "$HISTORY_FILE" | python3 -c "
import sys, json
lines = [l.strip() for l in sys.stdin if l.strip()]
parts = []
for line in lines:
    try:
        obj = json.loads(line)
        role = obj.get('role','?')
        msg  = obj.get('message','')
        parts.append(f'{role}: {msg}')
    except:
        pass
print('\n'.join(parts))
" 2>/dev/null) || true
fi

# ── Brave web search (inject live context when message looks like a question) ──
BRAVE_KEY="${BRAVE_API_KEY:-}"
WEB_CONTEXT=""

if [[ -n "$BRAVE_KEY" ]]; then
  # Trigger search if message looks like a question or mentions searchable topics
  if echo "$USER_MSG" | grep -qiE '([?]|^\s*(what|who|where|when|how|why|find|search|look|tell me about|research|browse)|\b(price|cost|buy|purchase|check out|look up|search for|find me|latest|current|news|how much|how many|best|top|compare|review|where can)\b)'; then
    BRAVE_QUERY=$(echo "$USER_MSG" | tr -d '\n' | cut -c1-200)
    BRAVE_RESP=$(curl -sf \
      "https://api.search.brave.com/res/v1/web/search?q=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "$BRAVE_QUERY")&count=5&text_decorations=0&search_lang=en" \
      -H "Accept: application/json" \
      -H "Accept-Encoding: gzip" \
      -H "X-Subscription-Token: ${BRAVE_KEY}" \
      --compressed 2>/dev/null || echo "")

    if [[ -n "$BRAVE_RESP" ]]; then
      _BRAVE_TMP=$(mktemp /tmp/brave-results-XXXXXX)
      export _BRAVE_JSON="$BRAVE_RESP"
      python3 - > "$_BRAVE_TMP" 2>/dev/null <<'PYbrave'
import json, os, sys
try:
    data = json.loads(os.environ.get('_BRAVE_JSON', '{}'))
    results = data.get('web', {}).get('results', [])
    lines = []
    for r in results[:5]:
        title = r.get('title','').strip()
        url   = r.get('url','').strip()
        desc  = r.get('description','').strip()
        if title or desc:
            lines.append("- " + title + "\n  " + url + "\n  " + desc)
    if lines:
        print("=== LIVE WEB SEARCH RESULTS ===\n" + "\n\n".join(lines))
except Exception:
    pass
PYbrave
      WEB_CONTEXT=$(cat "$_BRAVE_TMP" 2>/dev/null || true)
      rm -f "$_BRAVE_TMP"
    fi
  fi
fi

# ── Build the full prompt ─────────────────────────────────────────────────────
SYSTEM_PROMPT=$(cat "$SYSTEM_PROMPT_FILE" 2>/dev/null || echo "You are Claude, Amalfi AI's AI assistant.")
TODAY=$(date '+%A, %d %B %Y %H:%M SAST')

# Load persistent memory context
LONG_TERM_MEMORY=$(cat "$WS/memory/MEMORY.md" 2>/dev/null || echo "")
CURRENT_STATE=$(cat "$WS/CURRENT_STATE.md" 2>/dev/null || echo "")
RESEARCH_INTEL=$(cat "$WS/memory/research-intel.md" 2>/dev/null || echo "")

# Load OS identity
OS_SOUL=$(cat "$WS/prompts/amalfi-os-soul.md" 2>/dev/null || echo "")

# Per-user memory — inject the right profile for whoever is messaging
if [[ "$USER_PROFILE" == "salah" ]]; then
  USER_PERSONAL_MEMORY=$(cat "$WS/memory/salah-memory.md" 2>/dev/null || echo "")
  USER_TASKS_MEMORY=$(cat "$WS/memory/salah-tasks.md" 2>/dev/null || echo "")
  SOPHIA_SOUL=""
  SOPHIA_MEMORY=""
else
  USER_PERSONAL_MEMORY=$(cat "$WS/memory/josh-profile.md" 2>/dev/null || echo "")
  USER_TASKS_MEMORY=""
  # Load Sophia identity context (Josh-only)
  SOPHIA_SOUL=$(cat "$WS/prompts/sophia/soul.md" 2>/dev/null || echo "")
  SOPHIA_MEMORY=$(cat "$WS/memory/sophia/memory.md" 2>/dev/null || echo "")
fi

# Inject group chat context
if [[ -n "$GROUP_HISTORY_FILE" ]]; then
  GROUP_CONTEXT="
━━━ GROUP CHAT MODE ━━━

You are @JoshAmalfiBot in a group Telegram chat alongside other bots and humans.

Other bots in this group:
- @RaceTechnikAiBot — handles Race Technik operations (Mac mini, Supabase DB, bookings, Yoco payments, PWA dashboard, process templates). When it says something, listen and internalise it.

Rules for group chats:
- You were mentioned with @JoshAmalfiBot — respond to that specific request only
- READ the full conversation history above carefully — it includes messages from other bots and humans
- Do NOT re-introduce yourself or repeat what others just said
- Be concise — group chats, not essays
- If another bot gave an update and you're asked to act on it, reference it specifically: \"based on what RaceTechnikAiBot said about the Mac mini stack...\"
- Do NOT respond to messages not directed at you
- Tone: natural, human — like a colleague in a group chat
"
else
  GROUP_CONTEXT=""
fi

MEMORY_BLOCK=""
if [[ -n "$LONG_TERM_MEMORY" ]]; then
  if [[ "$USER_PROFILE" == "salah" ]]; then
    MEMORY_BLOCK="
=== AMALFI OS — IDENTITY ===
${OS_SOUL}

=== WHO SALAH IS ===
${USER_PERSONAL_MEMORY}

=== SALAH'S TASKS & CONTEXT ===
${USER_TASKS_MEMORY}

=== LONG-TERM MEMORY ===
${LONG_TERM_MEMORY}

=== CURRENT SYSTEM STATE ===
${CURRENT_STATE}

=== STRATEGIC RESEARCH INTELLIGENCE ===
${RESEARCH_INTEL}
"
  else
    MEMORY_BLOCK="
=== AMALFI OS — IDENTITY ===
${OS_SOUL}

=== WHO JOSH IS ===
${USER_PERSONAL_MEMORY}

=== SOPHIA — WHO SHE IS ===
${SOPHIA_SOUL}

=== SOPHIA — MEMORY ===
${SOPHIA_MEMORY}

=== LONG-TERM MEMORY ===
${LONG_TERM_MEMORY}

=== CURRENT SYSTEM STATE ===
${CURRENT_STATE}

=== STRATEGIC RESEARCH INTELLIGENCE ===
${RESEARCH_INTEL}
"
  fi
fi

WEB_BLOCK=""
if [[ -n "$WEB_CONTEXT" ]]; then
  WEB_BLOCK="
${WEB_CONTEXT}
"
fi

if [[ -n "$HISTORY" ]]; then
  FULL_PROMPT="${SYSTEM_PROMPT}${GROUP_CONTEXT}
Today: ${TODAY}
${MEMORY_BLOCK}${WEB_BLOCK}
=== RECENT CONVERSATION ===
${HISTORY}

${USER_DISPLAY}: ${USER_MSG}"
else
  FULL_PROMPT="${SYSTEM_PROMPT}${GROUP_CONTEXT}
Today: ${TODAY}
${MEMORY_BLOCK}${WEB_BLOCK}
${USER_DISPLAY}: ${USER_MSG}"
fi

# ── Store the user message in history ────────────────────────────────────────
# In group chats, messages are already logged by the poller — skip to avoid duplicates
if [[ -z "$GROUP_HISTORY_FILE" ]]; then
  echo "{\"role\":\"${USER_DISPLAY}\",\"message\":$(echo "$USER_MSG" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" >> "$HISTORY_FILE"
fi

# ── Show typing indicator ─────────────────────────────────────────────────────
tg_typing

# ── Run Claude ────────────────────────────────────────────────────────────────
unset CLAUDECODE
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
PROMPT_TMP=$(mktemp /tmp/tg-prompt-XXXXXX)
printf '%s' "$FULL_PROMPT" > "$PROMPT_TMP"
RESPONSE=$(claude --print --model claude-sonnet-4-6 --dangerously-skip-permissions < "$PROMPT_TMP" 2>>"$WS/out/gateway-errors.log")
rm -f "$PROMPT_TMP"

# ── Send response back to Telegram ───────────────────────────────────────────
if [[ -n "$RESPONSE" ]]; then

  # ── Audio reply (voice note input → MiniMax TTS voice note output) ──────────
  if [[ "$REPLY_MODE" == "audio" ]]; then
    # Strip markdown so it doesn't get spoken as symbols
    # (use temp file — heredoc inside $() can't use || fallback in bash)
    export _TTS_RESPONSE="$RESPONSE"
    _STRIP_TMP=$(mktemp /tmp/tts-strip-XXXXXX)
    python3 - > "$_STRIP_TMP" 2>/dev/null <<'PYSTRIP'
import re, os
text = os.environ.get('_TTS_RESPONSE', '')
text = re.sub(r'\*\*(.+?)\*\*', r'\1', text, flags=re.DOTALL)
text = re.sub(r'\*(.+?)\*', r'\1', text)
text = re.sub(r'```.*?```', '', text, flags=re.DOTALL)
text = re.sub(r'`(.+?)`', r'\1', text)
text = re.sub(r'^#{1,6}\s*', '', text, flags=re.MULTILINE)
text = re.sub(r'^[-*\u2022]\s+', '', text, flags=re.MULTILINE)
text = re.sub(r'\[(.+?)\]\(.+?\)', r'\1', text)
text = re.sub(r'<[^>]+>', '', text)
text = re.sub(r'\n{3,}', '\n\n', text)
print(text.strip()[:4500])
PYSTRIP
    CLEAN_TEXT=$(cat "$_STRIP_TMP" 2>/dev/null || true)
    rm -f "$_STRIP_TMP"

    AUDIO_OUT="/tmp/tg-voice-${CHAT_ID}-$(date +%s).opus"
    TTS_OK=0

    if [[ -n "$CLEAN_TEXT" ]]; then
      # Show upload_voice action while TTS renders
      curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendChatAction" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\": \"${CHAT_ID}\", \"action\": \"upload_voice\"}" >/dev/null 2>&1 || true

      if bash "$WS/scripts/tts/openai-tts.sh" "$CLEAN_TEXT" "$AUDIO_OUT" 2>>"$WS/out/gateway-errors.log"; then
        TTS_RESP=$(curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendVoice" \
          -F "chat_id=${CHAT_ID}" \
          -F "voice=@${AUDIO_OUT}" 2>/dev/null || echo "")
        TTS_OK=$(echo "$TTS_RESP" | python3 -c "import sys,json; print(1 if json.load(sys.stdin).get('ok') else 0)" 2>/dev/null || echo "0")
      fi
    fi

    rm -f "$AUDIO_OUT" 2>/dev/null || true

    if [[ "$TTS_OK" != "1" ]]; then
      # TTS failed — fall back to text so the response is never lost
      tg_send "$RESPONSE"
    fi

  # ── Text reply ───────────────────────────────────────────────────────────────
  else
    # Telegram has 4096 char limit — split if needed
    if [[ ${#RESPONSE} -le 4000 ]]; then
      tg_send "$RESPONSE"
    else
      # Split on double newlines
      echo "$RESPONSE" | python3 - <<PY
import os, subprocess, sys

BOT_TOKEN = os.environ.get('BOT_TOKEN','')
CHAT_ID   = '${CHAT_ID}'
text = sys.stdin.read()

chunks = []
current = ''
for para in text.split('\n\n'):
    if len(current) + len(para) + 2 > 3800:
        if current:
            chunks.append(current.strip())
        current = para
    else:
        current += ('\n\n' if current else '') + para
if current:
    chunks.append(current.strip())

for chunk in chunks:
    subprocess.run([
        'curl','-s','-X','POST',
        f'https://api.telegram.org/bot{BOT_TOKEN}/sendMessage',
        '-H','Content-Type: application/json',
        '-d', __import__('json').dumps({
            'chat_id': CHAT_ID,
            'text': chunk,
            'parse_mode': 'Markdown',
        })
    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
PY
    fi
  fi

  # Update Josh's profile in background (non-blocking — learns from every exchange)
  if [[ -z "$GROUP_HISTORY_FILE" ]]; then
    export _UJP_MSG="$USER_MSG" _UJP_RESP="$RESPONSE"
    bash "$WS/scripts/update-josh-profile.sh" "$_UJP_MSG" "$_UJP_RESP" \
      >>"$WS/out/gateway-errors.log" 2>&1 &
  fi

  # Store response in history (same for both reply modes)
  if [[ -n "$GROUP_HISTORY_FILE" ]]; then
    # Write bot's own response to the shared group history
    TS=$(date '+%H:%M')
    echo "{\"ts\":\"${TS}\",\"role\":\"JoshAmalfiBot\",\"is_bot\":true,\"message\":$(echo "$RESPONSE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" >> "$GROUP_HISTORY_FILE"
  else
    echo "{\"role\":\"Claude\",\"message\":$(echo "$RESPONSE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))')}" >> "$HISTORY_FILE"

    # Append to daily conversation log (feeds weekly-memory.sh distillation)
    TODAY_LOG="$WS/memory/$(date '+%Y-%m-%d').md"
    {
      echo ""
      echo "### $(date '+%H:%M SAST') — Telegram"
      echo "**Josh:** $USER_MSG"
      echo "**Claude:** $RESPONSE"
    } >> "$TODAY_LOG"
  fi
else
  tg_send "_(no response)_"
fi
