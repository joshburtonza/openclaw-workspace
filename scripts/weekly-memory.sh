#!/usr/bin/env bash
# weekly-memory.sh — reads last 7 days of memory logs, extracts insights, updates MEMORY.md
# Runs Sundays at 18:00 SAST (16:00 UTC) via LaunchAgent
set -euo pipefail

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
source "$ENV_FILE"
source "$WORKSPACE/scripts/lib/task-helpers.sh"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
unset CLAUDECODE

MEMORY_FILE="$WORKSPACE/memory/MEMORY.md"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Weekly memory starting"
TASK_ID=$(task_create "Weekly Memory Update" "Distilling 7 days of logs into MEMORY.md" "weekly-memory" "normal")

# ── Gather last 7 days of daily logs ─────────────────────────────────────────
LOG_CONTENT=""
for i in 1 2 3 4 5 6 7; do
  D=$(date -v -${i}d '+%Y-%m-%d' 2>/dev/null || date -d "-${i} days" '+%Y-%m-%d' 2>/dev/null || echo "")
  [[ -z "$D" ]] && continue
  LOG_FILE="$WORKSPACE/memory/${D}.md"
  [[ -f "$LOG_FILE" ]] && LOG_CONTENT="${LOG_CONTENT}

=== $D ===
$(cat "$LOG_FILE" | head -60)"
done

if [[ -z "$LOG_CONTENT" ]]; then
  echo "No daily logs found for last 7 days — skipping"
  exit 0
fi

# ── Extract insights via Claude ───────────────────────────────────────────────
PROMPT_TMP=$(mktemp /tmp/weekly-memory-XXXXXX)
cat > "$PROMPT_TMP" << PROMPT
Review these daily logs from the past week and extract ONLY things worth remembering long-term.

${LOG_CONTENT}

Extract concise one-liners under these categories (skip any with nothing new):
- KEY DECISIONS: Important choices made about the system or clients
- CLIENT CONTEXT: Notable things about specific clients (sentiment, issues, wins)
- SYSTEM LESSONS: Things that broke, were fixed, or should be done differently
- FOLLOW-UPS: Anything that needs attention next week
- JOSH PREFERENCES: Any patterns in how Josh likes things done

Format as:
## KEY DECISIONS
- ...

## CLIENT CONTEXT
- ...

(etc — omit empty sections)

Be ruthlessly concise. Only include genuinely useful long-term context. Max 20 bullet points total.
PROMPT

INSIGHTS=$(claude --print --model claude-sonnet-4-6 < "$PROMPT_TMP" 2>/dev/null)
rm -f "$PROMPT_TMP"

if [[ -z "$INSIGHTS" ]]; then
  echo "No insights extracted — skipping MEMORY.md update"
  exit 0
fi

# ── Update MEMORY.md ──────────────────────────────────────────────────────────
WEEK_LABEL=$(date '+week of %B %-d, %Y')
EXISTING=""
[[ -f "$MEMORY_FILE" ]] && EXISTING=$(cat "$MEMORY_FILE")

cat > "$MEMORY_FILE" << MEMORY
# Workspace Memory — Updated $(date '+%Y-%m-%d')

## Weekly Insights (${WEEK_LABEL})
${INSIGHTS}

---

## Previous Memory
${EXISTING}
MEMORY

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") MEMORY.md updated"

# ── Commit to GitHub ──────────────────────────────────────────────────────────
git -C "$WORKSPACE" add memory/MEMORY.md 2>/dev/null || true
git -C "$WORKSPACE" diff --staged --quiet 2>/dev/null || \
  git -C "$WORKSPACE" commit -m "Weekly memory update $(date '+%Y-%m-%d')" --no-verify 2>/dev/null || true

task_complete "$TASK_ID" "MEMORY.md updated and committed"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") Weekly memory complete"
