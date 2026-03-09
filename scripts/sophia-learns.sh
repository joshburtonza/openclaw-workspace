#!/usr/bin/env bash
# sophia-learns.sh
# Nightly 23:45 SAST — distils all interactions from the day into Sophia's memory.
# Sources: WA conversation JSONL, Claude Code session markdowns, daily memory log.
# Updates: memory/sophia/memory.md, per-client notes, per-person notes.
# Model: Claude Haiku (fast, cheap memory extraction).

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"

LOG="$WS/out/sophia-learns.log"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
mkdir -p "$WS/out"

SOPHIA_MEMORY="$WS/memory/sophia/memory.md"
CLAUDE_SESSIONS_DIR="$HOME/.claude/conversations-md"

TODAY=$(date '+%Y-%m-%d')
YESTERDAY=$(date -v-1d '+%Y-%m-%d' 2>/dev/null || date --date='yesterday' '+%Y-%m-%d')

log "Sophia learns — starting for $TODAY"

# ── 1. Gather today's WA conversations ─────────────────────────────────────────
WA_LOG="$WS/out/wa-conversations-${TODAY}.jsonl"
WA_DATA=""
if [[ -f "$WA_LOG" ]]; then
  # Convert JSONL to readable transcript
  WA_DATA=$(python3 -c "
import json, sys
lines = open('$WA_LOG').readlines()
out = []
for l in lines:
    try:
        e = json.loads(l)
        ctx = e.get('group') or e.get('client') or 'DM'
        out.append(f'[{ctx}] {e[\"sender\"]}: {e[\"inbound\"]}')
        out.append(f'[{ctx}] Sophia: {e[\"outbound\"]}')
    except: pass
print('\n'.join(out[:300]))
" 2>/dev/null || true)
  log "WA conversations loaded: $(echo "$WA_DATA" | wc -l) lines"
else
  log "No WA conversation log for today"
fi

# ── 2. Gather today's daily memory markdown ─────────────────────────────────────
DAILY_LOG="$WS/memory/${TODAY}.md"
DAILY_DATA=""
[[ -f "$DAILY_LOG" ]] && DAILY_DATA=$(cat "$DAILY_LOG" 2>/dev/null | head -200)

# ── 3. Gather recent Claude Code session markdowns (last 24h) ──────────────────
SESSION_DATA=""
if [[ -d "$CLAUDE_SESSIONS_DIR" ]]; then
  RECENT_FILES=$(find "$CLAUDE_SESSIONS_DIR" -name "*.md" -newer "$WS/out/sophia-learns.log" 2>/dev/null | head -5 || true)
  for f in $RECENT_FILES; do
    SESSION_DATA+="$(head -80 "$f" 2>/dev/null)\n---\n"
  done
  log "Claude sessions loaded: $(echo "$RECENT_FILES" | grep -c . || echo 0) files"
fi

# ── 4. Read existing Sophia memory ─────────────────────────────────────────────
mkdir -p "$WS/memory/sophia"
EXISTING_SOPHIA_MEMORY=""
[[ -f "$SOPHIA_MEMORY" ]] && EXISTING_SOPHIA_MEMORY=$(cat "$SOPHIA_MEMORY" 2>/dev/null)

# ── 5. Skip if nothing to learn from ──────────────────────────────────────────
if [[ -z "$WA_DATA" && -z "$DAILY_DATA" && -z "$SESSION_DATA" ]]; then
  log "No new interaction data — skipping"
  exit 0
fi

# ── 6. Export everything for Python ────────────────────────────────────────────
export _WA_DATA="$WA_DATA"
export _DAILY_DATA="$DAILY_DATA"
export _SESSION_DATA="$SESSION_DATA"
export _EXISTING_MEMORY="$EXISTING_SOPHIA_MEMORY"
export _TODAY="$TODAY"
export _SOPHIA_MEMORY="$SOPHIA_MEMORY"
export _WS="$WS"

python3 - <<'PYLEARN'
import os, subprocess, json

today            = os.environ.get('_TODAY', '')
wa_data          = os.environ.get('_WA_DATA', '')
daily_data       = os.environ.get('_DAILY_DATA', '')
session_data     = os.environ.get('_SESSION_DATA', '')
existing_memory  = os.environ.get('_EXISTING_MEMORY', '')
sophia_memory_path = os.environ.get('_SOPHIA_MEMORY', '')
ws               = os.environ.get('_WS', '')

def run_haiku(prompt, max_tokens=800):
    tmp = f'/tmp/sophia-learns-{today}.txt'
    with open(tmp, 'w') as f:
        f.write(prompt)
    env = dict(**__import__('os').environ, UNSET_CLAUDECODE='1')
    del env['CLAUDECODE'] if 'CLAUDECODE' in env else None
    try:
        r = subprocess.run(
            ['claude', '--model', 'claude-haiku-4-5-20251001', '--print', '--max-tokens', str(max_tokens)],
            stdin=open(tmp), capture_output=True, text=True, timeout=60,
            env={k: v for k, v in os.environ.items() if k != 'CLAUDECODE'}
        )
        return r.stdout.strip() if r.returncode == 0 else None
    except Exception as e:
        print(f'Haiku error: {e}')
        return None

all_interactions = '\n\n'.join(filter(None, [
    f'=== WhatsApp Conversations ===\n{wa_data}' if wa_data else '',
    f'=== Daily Memory Log ===\n{daily_data}' if daily_data else '',
    f'=== Claude Code Sessions ===\n{session_data[:3000]}' if session_data else '',
]))

if not all_interactions.strip():
    print('Nothing to learn from')
    exit()

# ── Step 1: Extract learnings about clients ───────────────────────────────────
client_learnings = run_haiku(f"""You are a memory distiller for Sophia, an AI client success manager at Amalfi AI.

Read today's interactions below and extract NEW learnings about clients that Sophia should remember long term.
Focus on:
- New preferences, feedback, or requests from clients
- Corrections or complaints (what went wrong, what Sophia should never do again)
- New facts about their projects, business, or personal context
- Communication style preferences
- Anything that changes how Sophia should interact with them

Be specific and concise. Output bullet points only. One learning per line starting with the client name.
If nothing genuinely new was learned, output: NOTHING NEW

EXISTING SOPHIA MEMORY (do not repeat these):
{existing_memory[:2000]}

TODAY'S INTERACTIONS:
{all_interactions[:4000]}""", max_tokens=600)

print(f'Client learnings: {(client_learnings or "")[:100]}')

# ── Step 2: Extract Sophia-level patterns and rules ───────────────────────────
sophia_patterns = run_haiku(f"""You are a memory distiller for Sophia, an AI client success manager at Amalfi AI.

Read today's interactions and extract any NEW patterns, rules, or behaviours Sophia should adopt going forward.
Focus on:
- Communication patterns that worked well or poorly
- Tone adjustments that were requested
- Mistakes that were corrected (especially by Josh)
- New capabilities or workflows that were established
- Any "never do this again" moments

Be specific. Output bullet points only.
If nothing new was learned, output: NOTHING NEW

EXISTING SOPHIA MEMORY (do not repeat these):
{existing_memory[:2000]}

TODAY'S INTERACTIONS:
{all_interactions[:4000]}""", max_tokens=400)

print(f'Sophia patterns: {(sophia_patterns or "")[:100]}')

# ── Step 3: Update sophia/memory.md ──────────────────────────────────────────
new_content = ''
if client_learnings and 'NOTHING NEW' not in client_learnings and client_learnings.strip():
    new_content += f'\n\n## Learnings — {today}\n\n### Client Insights\n{client_learnings.strip()}'
if sophia_patterns and 'NOTHING NEW' not in sophia_patterns and sophia_patterns.strip():
    new_content += f'\n\n### Sophia Behaviour Patterns\n{sophia_patterns.strip()}'

if new_content:
    with open(sophia_memory_path, 'a') as f:
        f.write(new_content + '\n')
    print(f'Sophia memory updated with {len(new_content)} chars')
else:
    print('No new learnings to save')

# ── Step 4: Update per-client notes from WA conversations ────────────────────
if wa_data:
    client_slugs = set()
    for line in wa_data.split('\n'):
        if line.startswith('[') and ']' in line:
            slug = line[1:line.index(']')].strip()
            if slug and slug not in ('DM', 'None', ''):
                client_slugs.add(slug)

    for slug in client_slugs:
        slug_lines = [l for l in wa_data.split('\n') if f'[{slug}]' in l]
        if not slug_lines:
            continue
        safe = slug.lower().replace(' ', '-').replace('/', '-')
        notes_file = f'{ws}/memory/{safe}-notes.md'
        existing = ''
        try:
            with open(notes_file) as f:
                existing = f.read()
        except: pass

        snippet = '\n'.join(slug_lines[:40])
        new_facts = run_haiku(f"""Extract NEW facts about {slug} from this WhatsApp conversation that are not already in the notes.
Be brief — bullet points only. Output nothing if nothing new.

EXISTING NOTES:
{existing[:1000] or '(none)'}

CONVERSATION:
{snippet}""", max_tokens=200)

        if new_facts and new_facts.strip() and 'NOTHING' not in new_facts.upper():
            try:
                with open(notes_file, 'a') as f:
                    f.write(f'\n<!-- {today} -->\n{new_facts.strip()}\n')
                print(f'Notes updated for {slug}')
            except Exception as e:
                print(f'Notes write error for {slug}: {e}')

print('Sophia learns — complete')
PYLEARN

log "Sophia learns — complete"
