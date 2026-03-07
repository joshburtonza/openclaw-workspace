#!/usr/bin/env bash
# sophia-trial-decouple.sh
# Runs on 2026-04-01 via LaunchAgent.
# Removes expired trial users from whatsapp-contacts.json and updates Supabase.

set -euo pipefail

WS="/Users/henryburton/.openclaw/workspace-anthropic"
CONTACTS="$WS/memory/whatsapp-contacts.json"
LOG="$WS/out/sophia-trial-decouple.log"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"

source "$WS/.env.scheduler"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG"; }

log "sophia-trial-decouple starting"

TODAY=$(date +%Y-%m-%d)

python3 << PYEOF
import json, os, sys, urllib.request, urllib.error
from datetime import date

contacts_path = os.environ.get('CONTACTS', '$CONTACTS')
supabase_url  = '$SUPABASE_URL'
supabase_key  = '$SUPABASE_SERVICE_ROLE_KEY'
telegram_token = '$TELEGRAM_BOT_TOKEN'
josh_chat_id  = '1140320036'
today         = date.today()

with open(contacts_path) as f:
    contacts = json.load(f)

decoupled = []

for num, entry in list(contacts.items()):
    if entry.get('role') != 'Trial':
        continue
    trial_end_str = entry.get('trialEnd', '')
    if not trial_end_str:
        continue
    trial_end = date.fromisoformat(trial_end_str)
    if today > trial_end:
        decoupled.append((num, entry.get('name', num), trial_end_str))
        del contacts[num]
        print(f"Removed trial user: {entry.get('name')} ({num}) — trial ended {trial_end_str}")

if not decoupled:
    print("No expired trial users to decouple today.")
    sys.exit(0)

# Write updated contacts
with open(contacts_path, 'w') as f:
    json.dump(contacts, f, indent=2)
print(f"contacts.json updated — {len(decoupled)} user(s) removed")

# Update Supabase leads status to 'trial_ended' for each decoupled number
for num, name, end_date in decoupled:
    wa_search = f"WA number: {num}"
    patch = json.dumps({"status": "trial_ended", "notes": f"Trial ended {end_date}. Auto-decoupled by sophia-trial-decouple.sh. Awaiting conversion follow-up."}).encode()
    try:
        req = urllib.request.Request(
            f"{supabase_url}/rest/v1/leads?tags=cs.{{sophia_trial}}&first_name=eq.{name}",
            data=patch,
            method='PATCH',
            headers={
                'apikey': supabase_key,
                'Authorization': f'Bearer {supabase_key}',
                'Content-Type': 'application/json',
                'Prefer': 'return=minimal',
            }
        )
        urllib.request.urlopen(req)
        print(f"Supabase updated for {name}")
    except Exception as e:
        print(f"Supabase update failed for {name}: {e}")

# Notify Josh on Telegram
names = ', '.join(n for _, n, _ in decoupled)
msg = f"Trial ended: {names}\n\nSophia has been decoupled from their WhatsApp. They are marked as trial_ended in leads.\n\nGood time to follow up and convert."
tg_url = f"https://api.telegram.org/bot{telegram_token}/sendMessage"
payload = json.dumps({"chat_id": josh_chat_id, "text": msg}).encode()
try:
    req = urllib.request.Request(tg_url, data=payload, method='POST',
                                  headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req)
    print("Josh notified on Telegram")
except Exception as e:
    print(f"Telegram notify failed: {e}")

PYEOF

log "sophia-trial-decouple done"
