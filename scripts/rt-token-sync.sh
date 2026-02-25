#!/bin/bash
# rt-token-sync.sh
# Reads fresh Claude Code OAuth token from local keychain and pushes it
# to the Race Technik Mac Mini every 30 minutes.

set -euo pipefail

LOG="/Users/henryburton/.openclaw/workspace-anthropic/out/rt-token-sync.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") $*" >> "$LOG"; }

# Extract token from keychain
RAW=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
if [[ -z "$RAW" ]]; then
  log "ERROR: Could not read Claude Code credentials from keychain"
  exit 1
fi

TOKEN=$(echo "$RAW" | python3 -c "
import sys, json
raw = sys.stdin.read().strip()
try:
    d = json.loads(raw)
    cai = d.get('claudeAiOauth', {})
    print(cai.get('accessToken') or cai.get('access_token') or '')
except Exception as e:
    print('')
" 2>/dev/null)

if [[ -z "$TOKEN" ]]; then
  log "ERROR: Could not parse access token from keychain credentials"
  exit 1
fi

log "Token extracted (${TOKEN:0:20}...)"

# Push to Race Technik Mac Mini
ssh -i ~/.ssh/race_technik -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
  raceai@100.114.191.52 "python3 -c \"
import re
path = '/Users/raceai/.amalfiai/workspace/.env.scheduler'
content = open(path).read()
new = re.sub(r'CLAUDE_CODE_OAUTH_TOKEN=.*', 'CLAUDE_CODE_OAUTH_TOKEN=$TOKEN', content)
open(path, 'w').write(new)
print('updated')
\"" 2>/dev/null && log "Token pushed to Mac Mini" || { log "ERROR: SSH push failed"; exit 1; }

log "Done"
