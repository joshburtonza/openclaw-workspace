#!/usr/bin/env bash
# memory-writer.sh
# Processes unprocessed interaction_log entries → updates user_models + agent_memory.
# Uses Claude Haiku for lightweight inference (cheap, fast, high-volume).
# Runs every 30 min via LaunchAgent.

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
LOG="$WS/out/memory-writer.log"

mkdir -p "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

if [[ -z "$KEY" ]]; then
  log "ERROR: SUPABASE_SERVICE_ROLE_KEY not set"; exit 1
fi

log "=== Memory writer run ==="

export KEY SUPABASE_URL WS

python3 - <<'PY'
import os, json, subprocess, urllib.request, datetime, tempfile, sys

KEY          = os.environ['KEY']
SUPABASE_URL = os.environ['SUPABASE_URL']
WS           = os.environ['WS']
HAIKU_MODEL  = 'claude-haiku-4-5-20251001'
BATCH_SIZE   = 20

def supa_get(path):
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            return json.loads(r.read())
    except Exception as e:
        print(f"  [warn] supa_get failed: {e}", file=sys.stderr)
        return []

def supa_patch(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        method="PATCH",
    )
    try:
        urllib.request.urlopen(req, timeout=10)
        return True
    except Exception as e:
        print(f"  [warn] supa_patch failed: {e}", file=sys.stderr)
        return False

def supa_post(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=representation"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read())
    except Exception as e:
        print(f"  [warn] supa_post failed: {e}", file=sys.stderr)
        return []

def upsert_user_model(user_id, user_type, updates: dict):
    """Merge updates into user_models. Creates row if missing."""
    rows = supa_get(f"user_models?user_id=eq.{user_id}&select=id,communication,decision_patterns,goals,relationship,preferences,flags,raw_observations")
    now_iso = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

    if rows:
        existing = rows[0]
        merged = {}
        for field in ('communication', 'decision_patterns', 'goals', 'relationship', 'preferences', 'flags'):
            base = existing.get(field) or {}
            if isinstance(base, str):
                try: base = json.loads(base)
                except Exception: base = {}
            incoming = updates.get(field, {})
            if isinstance(incoming, dict):
                merged[field] = {**base, **incoming}

        # Append new observations
        obs = existing.get('raw_observations') or []
        new_obs = updates.get('raw_observations', [])
        merged['raw_observations'] = (obs + new_obs)[-50:]  # keep last 50
        merged['updated_at'] = now_iso

        supa_patch(f"user_models?user_id=eq.{user_id}", merged)
    else:
        payload = {
            'user_id': user_id,
            'user_type': user_type,
            'communication': updates.get('communication', {}),
            'decision_patterns': updates.get('decision_patterns', {}),
            'goals': updates.get('goals', {}),
            'relationship': updates.get('relationship', {}),
            'preferences': updates.get('preferences', {}),
            'flags': updates.get('flags', {}),
            'raw_observations': updates.get('raw_observations', []),
        }
        supa_post("user_models", payload)

def upsert_agent_memory(agent, scope, memory_type, content, confidence=0.7):
    """Add or reinforce a memory entry for an agent."""
    # Check for near-duplicate (same agent+scope+type+content prefix)
    existing = supa_get(
        f"agent_memory?agent=eq.{agent}&scope=eq.{scope}&memory_type=eq.{memory_type}"
        f"&select=id,content,confidence&limit=20"
    )
    now_iso = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    content_lower = content.lower()[:80]
    match = next((r for r in existing if r.get('content','').lower()[:80] == content_lower), None)

    if match:
        # Reinforce confidence (Bayesian-ish update: nudge toward 1.0)
        old_conf = float(match.get('confidence', 0.5))
        new_conf = min(1.0, old_conf + (1.0 - old_conf) * 0.2)
        supa_patch(f"agent_memory?id=eq.{match['id']}",
                   {'confidence': new_conf, 'reinforced_at': now_iso})
    else:
        supa_post("agent_memory", {
            'agent': agent, 'scope': scope, 'memory_type': memory_type,
            'content': content, 'confidence': confidence,
        })

def claude_haiku(prompt):
    env = {k: v for k, v in os.environ.items() if k not in ('CLAUDECODE', 'CLAUDE_CODE')}
    tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, prefix='/tmp/mw-')
    tmp.write(prompt)
    tmp.close()
    try:
        r = subprocess.run(
            ['claude', '--print', '--model', HAIKU_MODEL, '--dangerously-skip-permissions'],
            stdin=open(tmp.name), capture_output=True, text=True, timeout=60, env=env,
        )
        return r.stdout.strip()
    except Exception as e:
        print(f"  [warn] Haiku call failed: {e}", file=sys.stderr)
        return ''
    finally:
        os.unlink(tmp.name)

# ── Fetch unprocessed signals ─────────────────────────────────────────────────

signals = supa_get(
    f"interaction_log?processed=eq.false"
    f"&order=timestamp.asc&limit={BATCH_SIZE}"
    f"&select=id,actor,user_id,signal_type,signal_data,timestamp"
)

if not signals:
    print("Nothing to process.")
    raise SystemExit(0)

print(f"Processing {len(signals)} signal(s)...")

# ── Build interpretation prompt ───────────────────────────────────────────────

signals_text = json.dumps(signals, indent=2)

SYSTEM = """You are a memory inference engine for an adaptive AI operating system.

You receive a batch of interaction signals — typed events from humans using the system.
Your job: infer what each signal reveals about the user's patterns, preferences, and state.

Return a JSON array. Each element corresponds to one signal (same order as input) with:
{
  "signal_id": "<id from input>",
  "user_id": "<user_id from signal>",
  "user_type": "owner|client|lead",
  "user_model_updates": {
    "communication": {},
    "decision_patterns": {},
    "relationship": {},
    "preferences": {},
    "flags": {},
    "raw_observations": ["<dated observation string>"]
  },
  "agent_memories": [
    {"agent": "sophia|alex|coach|conductor", "scope": "<user_id or global>",
     "memory_type": "pattern|preference|style_learned|observation|rule",
     "content": "<concise learned fact>", "confidence": 0.0-1.0}
  ]
}

Signal taxonomy:
- email_approved → user likes this draft style/approach
- email_rejected → user dislikes something about the draft (infer what from context)
- email_adjusted → user wants changes (what kind?)
- email_held → user is cautious about this email
- reminder_done → user completed this type of task
- reminder_snoozed → timing was wrong, or user is busy/avoiding

Rules:
- Be specific and actionable in inferences. Not "user approved email" but "user approves short, direct Sophia emails with specific project references"
- Low confidence (0.3-0.5) for single data points. Higher (0.7-0.9) for patterns across multiple signals.
- raw_observations should be dated strings like "[2026-02-26] Approved Sophia check-in to ascend_lc — subject referenced recent commits"
- Skip user_model_updates or agent_memories sections if nothing meaningful to infer
- Return ONLY the JSON array, no explanation"""

prompt = f"{SYSTEM}\n\nSignals:\n{signals_text}"

raw = claude_haiku(prompt)
if not raw:
    print("  [warn] Empty Haiku response — marking signals processed anyway")
    for s in signals:
        supa_patch(f"interaction_log?id=eq.{s['id']}", {'processed': True, 'notes': 'skipped: empty inference'})
    raise SystemExit(0)

# ── Parse and apply updates ───────────────────────────────────────────────────

try:
    # Strip markdown code blocks if present
    clean = raw.strip()
    if clean.startswith('```'):
        clean = clean.split('\n', 1)[1].rsplit('```', 1)[0].strip()
    inferences = json.loads(clean)
except Exception as e:
    print(f"  [warn] Could not parse Haiku JSON: {e}\nRaw: {raw[:300]}", file=sys.stderr)
    for s in signals:
        supa_patch(f"interaction_log?id=eq.{s['id']}", {'processed': True, 'notes': f'parse_error: {str(e)[:80]}'})
    raise SystemExit(0)

applied = 0
for inf in inferences:
    signal_id = inf.get('signal_id', '')
    user_id   = inf.get('user_id', '')
    user_type = inf.get('user_type', 'client')

    # Apply user model updates
    um = inf.get('user_model_updates', {})
    if um and user_id:
        upsert_user_model(user_id, user_type, um)

    # Apply agent memory entries
    for mem in inf.get('agent_memories', []):
        if mem.get('agent') and mem.get('content'):
            upsert_agent_memory(
                agent=mem['agent'],
                scope=mem.get('scope', user_id),
                memory_type=mem.get('memory_type', 'observation'),
                content=mem['content'],
                confidence=float(mem.get('confidence', 0.5)),
            )

    # Mark signal processed
    if signal_id:
        notes = '; '.join(
            m.get('content','')[:80]
            for m in inf.get('agent_memories', [])
        )[:200]
        supa_patch(f"interaction_log?id=eq.{signal_id}",
                   {'processed': True, 'notes': notes or 'processed'})
        applied += 1

print(f"Done — {applied}/{len(signals)} signal(s) processed, user_models and agent_memory updated.")
PY

log "Memory writer complete."
