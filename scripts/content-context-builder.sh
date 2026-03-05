#!/usr/bin/env bash
# content-context-builder.sh
# Gathers all live business context into a single file for content agents.
# Called by video-bot and content-ideas before generating scripts.
# Output: $WS/tmp/content-context-today.md (refreshed each run)

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
OUTPUT="$WS/tmp/content-context-today.md"

TODAY=$(date '+%A, %d %B %Y')
TODAY_FILE="$WS/memory/$(date +%Y-%m-%d).md"
YESTERDAY_FILE="$WS/memory/$(date -v-1d +%Y-%m-%d 2>/dev/null || date -d 'yesterday' +%Y-%m-%d).md"

mkdir -p "$WS/tmp"

{
  echo "# Content Context — $TODAY"
  echo ""
  echo "This is live business data. Use it to write specific, timely, real content."
  echo ""

  # ── 1. AOS System State ──────────────────────────────────────────────────────
  echo "## AOS (AI Operating System) — What We Built"
  echo ""
  echo "Amalfi AI runs a 46-agent autonomous system (the AOS) on a Mac. 16 API agents, 28 non-API, 2 infra. Priority tiers protect the API budget (6 calls/hr). Head-agent orchestrates everything. No employees, just AI agents."
  echo ""
  if [[ -f "$WS/CURRENT_STATE.md" ]]; then
    echo "### Current System State"
    head -50 "$WS/CURRENT_STATE.md" 2>/dev/null
    echo ""
  fi

  # ── 2. Recent Activity (what happened yesterday + today) ─────────────────────
  echo "## Recent Activity"
  echo ""
  if [[ -f "$TODAY_FILE" ]]; then
    echo "### Today's Log (latest entries)"
    tail -80 "$TODAY_FILE" 2>/dev/null
    echo ""
  fi
  if [[ -f "$YESTERDAY_FILE" ]]; then
    echo "### Yesterday's Log (highlights)"
    tail -80 "$YESTERDAY_FILE" 2>/dev/null
    echo ""
  fi

  # ── 3. Client Project Data (repo commits — what was actually shipped) ────────
  echo "## Client Projects — Recent Work"
  echo ""
  echo "Amalfi AI has 3 active clients:"
  echo "- Ascend LC (R30k/pm) — QMS Guard: ISO 9001 compliance automation"
  echo "- Favorite Logistics (R20k/pm) — FLAIR ERP: shipments, invoices, payments"
  echo "- Race Technik (R21.5k/pm) — Chrome Auto Care: automotive detailing platform"
  echo ""
  echo "### Recent Code Changes (from daily repo sync)"
  if [[ -f "$WS/out/daily-repo-sync.log" ]]; then
    # Get the last 5 sync summaries (look for the actual content lines)
    grep -A2 "Changes found\|commits\|Ascend\|Favorite\|Race\|QMS\|FLAIR\|Chrome" \
      "$WS/out/daily-repo-sync.log" 2>/dev/null | tail -30
  else
    echo "(no repo sync data available)"
  fi
  echo ""

  # ── 4. Client Interactions (recent Sophia emails — what clients said) ────────
  echo "## Client Interactions (recent)"
  echo ""
  if [[ -n "$KEY" ]]; then
    # Fetch last 7 days of email_queue entries (sent + auto_pending + awaiting)
    EMAILS=$(curl -s "${SUPABASE_URL}/rest/v1/email_queue?select=client,subject,status,created_at&order=created_at.desc&limit=15" \
      -H "apikey: $KEY" \
      -H "Authorization: Bearer $KEY" 2>/dev/null || echo "[]")
    if [[ -n "$EMAILS" ]] && [[ "$EMAILS" != "[]" ]]; then
      echo "$EMAILS" | python3 -c '
import json, sys
try:
    emails = json.load(sys.stdin)
    for e in emails[:15]:
        client = e.get("client","unknown")
        subj = e.get("subject","")
        status = e.get("status","")
        date = e.get("created_at","")[:10]
        print(f"- [{date}] {client}: {subj} ({status})")
except:
    print("(could not parse email data)")
' 2>/dev/null
    else
      echo "(no recent email activity)"
    fi
  else
    echo "(Supabase key not available)"
  fi
  echo ""

  # ── 5. Meeting Intelligence (recent meetings and outcomes) ───────────────────
  echo "## Meeting Intelligence"
  echo ""
  if [[ -f "$WS/memory/meeting-journal.md" ]]; then
    # Get the last 3 meeting entries (most recent)
    tail -60 "$WS/memory/meeting-journal.md" 2>/dev/null
  else
    echo "(no meeting journal available)"
  fi
  echo ""

  # ── 6. Financial Snapshot ────────────────────────────────────────────────────
  echo "## Business Numbers"
  echo ""
  echo "- MRR: R71,500/pm (Ascend R30k + Race R21.5k + FavLog R20k)"
  echo "- Ad hoc buffer: ~R13k/pm"
  echo "- Team: Josh (founder/builder) + Salah (ops/BD) + AI agents (no employees)"
  echo "- Stack: Claude, Supabase, n8n, React, LaunchAgents, Telegram bots"
  echo ""

  # ── 7. AI / Tech / Business News ────────────────────────────────────────────
  echo "## AI and Tech News (for content inspiration)"
  echo ""
  if [[ -f "$WS/tmp/content-news-today.md" ]]; then
    cat "$WS/tmp/content-news-today.md" 2>/dev/null
  elif [[ -f "$WS/sophia-ai-brief.md" ]] && [[ -s "$WS/sophia-ai-brief.md" ]]; then
    head -40 "$WS/sophia-ai-brief.md" 2>/dev/null
  else
    echo "(no news feed available — content-news-fetcher not yet running)"
    echo ""
    echo "Fallback topics to riff on:"
    echo "- AI agents replacing SaaS (the agent vs app debate)"
    echo "- Building in public as a growth strategy"
    echo "- Why most AI agencies sell smoke (and how to actually deliver)"
    echo "- The real cost of running an AI business (infrastructure, API costs, time)"
    echo "- Cold outreach with AI (what works, what is spam)"
    echo "- Client retention > acquisition"
  fi
  echo ""

  # ── 8. Key Memory (long-term learnings) ─────────────────────────────────────
  echo "## Key Learnings (from MEMORY.md)"
  echo ""
  if [[ -f "$WS/memory/MEMORY.md" ]]; then
    # Pull the most useful sections — decisions, lessons, client updates
    head -120 "$WS/memory/MEMORY.md" 2>/dev/null
  fi

} > "$OUTPUT" 2>/dev/null

echo "[content-context] Built $OUTPUT ($(wc -l < "$OUTPUT") lines)"
