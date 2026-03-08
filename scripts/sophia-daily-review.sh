#!/usr/bin/env bash
# sophia-daily-review.sh — Daily self-review and self-healing for Sophia WhatsApp
# Reads last 24h of WhatsApp logs, grades Sophia against prompt rules,
# saves report, auto-patches prompts on repeated violations, Telegram summary.
# Runs: 06:00 SAST daily via LaunchAgent
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

AOS_ROOT="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
WS="$AOS_ROOT"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${AOS_TELEGRAM_OWNER_CHAT_ID:-1140320036}"
OPENAI_KEY="${OPENAI_API_KEY:-}"

GATEWAY_LOG="$WS/out/whatsapp-wjs-gateway.log"
REVIEWS_DIR="$WS/memory/sophia-reviews"
TODAY=$(date '+%Y-%m-%d')
REPORT_FILE="$REVIEWS_DIR/$TODAY.md"
LOG="$WS/out/sophia-daily-review.log"

mkdir -p "$REVIEWS_DIR"

log() { echo "[$(date '+%H:%M:%S')] $1" | tee -a "$LOG"; }

tg_send() {
  local text="$1" parse_mode="${2:-HTML}"
  [[ -z "$BOT_TOKEN" ]] && { log "No Telegram token, skipping notification"; return; }
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d "{\"chat_id\":\"${CHAT_ID}\",\"text\":$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$text"),\"parse_mode\":\"${parse_mode}\"}" \
    > /dev/null
}

log "=== Sophia Daily Review — $TODAY ==="

if [[ ! -f "$GATEWAY_LOG" ]]; then
  log "Gateway log not found at $GATEWAY_LOG"
  tg_send "⚠️ <b>Sophia Review:</b> Gateway log not found, skipping."
  exit 0
fi

if [[ -z "$OPENAI_KEY" ]]; then
  log "No OpenAI API key, cannot run review"
  tg_send "⚠️ <b>Sophia Review:</b> No OpenAI key configured."
  exit 1
fi

# Hand off to Python for log parsing + grading + report
python3 << 'PYEOF'
import json, os, re, sys, urllib.request
from datetime import datetime, timedelta

WS = os.environ.get("AOS_ROOT", "/Users/henryburton/.openclaw/workspace-anthropic")
GATEWAY_LOG = os.path.join(WS, "out", "whatsapp-wjs-gateway.log")
REVIEWS_DIR = os.path.join(WS, "memory", "sophia-reviews")
OPENAI_KEY = os.environ.get("OPENAI_API_KEY", "")
TODAY = datetime.now().strftime("%Y-%m-%d")
REPORT_FILE = os.path.join(REVIEWS_DIR, f"{TODAY}.md")
GROUP_PROMPT = os.path.join(WS, "prompts", "sophia-whatsapp-group.md")
DM_PROMPT = os.path.join(WS, "prompts", "sophia-personal-dm.md")

def log(msg):
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)

BOT_TOKEN = os.environ.get("TELEGRAM_BOT_TOKEN", "")
CHAT_ID = os.environ.get("AOS_TELEGRAM_OWNER_CHAT_ID", "1140320036")

def call_openai(prompt):
    if not OPENAI_KEY:
        return None
    body = json.dumps({
        "model": "gpt-4o",
        "messages": [{"role": "user", "content": prompt}],
        "temperature": 0.3
    }).encode()
    req = urllib.request.Request(
        "https://api.openai.com/v1/chat/completions", data=body,
        headers={"Authorization": f"Bearer {OPENAI_KEY}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=90) as r:
            return json.loads(r.read())["choices"][0]["message"]["content"].strip()
    except Exception as e:
        log(f"OpenAI failed: {e}")
        return None

def tg_send(text, parse_mode="HTML"):
    if not BOT_TOKEN:
        log("No Telegram token, skipping notification")
        return
    body = json.dumps({"chat_id": CHAT_ID, "text": text, "parse_mode": parse_mode}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage", data=body,
        headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=30)
    except Exception as e:
        log(f"Telegram send failed: {e}")

# --- Parse last 24h of gateway log ---
cutoff = datetime.now() - timedelta(hours=24)
interactions = []
current_inbound = None

try:
    with open(GATEWAY_LOG, "r") as f:
        lines = f.readlines()
except Exception as e:
    log(f"Failed to read gateway log: {e}")
    sys.exit(1)

log(f"Scanning {len(lines)} log lines for last 24h...")

for line in lines:
    line = line.strip()
    if not line:
        continue

    # Extract timestamp
    ts_match = re.match(r"\[(\d{2}:\d{2}:\d{2})\]", line)
    if not ts_match:
        continue

    # Try to parse with today's date first, then yesterday
    ts_str = ts_match.group(1)
    try:
        ts = datetime.strptime(f"{TODAY} {ts_str}", "%Y-%m-%d %H:%M:%S")
        if ts > datetime.now():
            ts -= timedelta(days=1)
    except ValueError:
        continue

    if ts < cutoff:
        continue

    # Inbound message
    inbound_group = re.match(
        r'\[\d{2}:\d{2}:\d{2}\] Message from (\+\d+) \(group: "(.+?)"\): (.+)', line)
    inbound_dm = re.match(
        r'\[\d{2}:\d{2}:\d{2}\] Message from (\+\d+): (.+)', line)

    if inbound_group:
        current_inbound = {
            "time": ts_str, "sender": inbound_group.group(1),
            "group": inbound_group.group(2), "message": inbound_group.group(3),
            "type": "group"
        }
    elif inbound_dm and "(group:" not in line:
        current_inbound = {
            "time": ts_str, "sender": inbound_dm.group(1),
            "group": None, "message": inbound_dm.group(2),
            "type": "dm"
        }

    # Sophia response
    replied = re.match(r'\[\d{2}:\d{2}:\d{2}\] Replied: (.+)', line)
    if replied and current_inbound:
        interactions.append({
            **current_inbound,
            "sophia_response": replied.group(1),
            "action": "replied"
        })
        current_inbound = None

    # Sophia skip
    skip = re.match(r'\[\d{2}:\d{2}:\d{2}\] Sophia chose not to respond \(SKIP\)', line)
    if skip and current_inbound:
        interactions.append({
            **current_inbound,
            "sophia_response": None,
            "action": "skip"
        })
        current_inbound = None

    # Self-correction
    correction = re.match(r'\[\d{2}:\d{2}:\d{2}\] Self-correcting \((\d+) violation\): (.+)', line)
    if correction and interactions:
        interactions[-1]["self_correction"] = {
            "count": correction.group(1),
            "description": correction.group(2)
        }

log(f"Found {len(interactions)} interactions in last 24h")

if not interactions:
    log("No interactions to review")
    # Write empty report
    with open(REPORT_FILE, "w") as f:
        f.write(f"# Sophia Daily Review — {TODAY}\n\n")
        f.write("No interactions found in the last 24 hours.\n")
    sys.exit(0)

# --- Load prompt rules for context ---
rules_context = ""
for pf in [GROUP_PROMPT, DM_PROMPT]:
    if os.path.exists(pf):
        with open(pf, "r") as f:
            rules_context += f"\n### {os.path.basename(pf)}\n{f.read()}\n"

# --- Build interaction summary for grading ---
interaction_text = ""
for i, ix in enumerate(interactions[:50], 1):  # Cap at 50 to fit context
    ctx = f"{'Group: ' + ix['group'] if ix['group'] else 'DM'}"
    interaction_text += f"\n--- Interaction {i} [{ix['time']}] ({ctx}) ---\n"
    interaction_text += f"Sender: {ix['sender']}\n"
    interaction_text += f"Message: {ix['message']}\n"
    if ix["action"] == "replied":
        interaction_text += f"Sophia replied: {ix['sophia_response']}\n"
    else:
        interaction_text += "Sophia: SKIPPED (chose not to respond)\n"
    if "self_correction" in ix:
        interaction_text += f"Self-corrected: {ix['self_correction']['description']}\n"

# --- Grade with GPT-4o ---
grading_prompt = f"""You are reviewing Sophia's WhatsApp performance for {TODAY}.

Sophia is a customer success manager AI persona for Amalfi AI. She must follow strict rules.

RULES SHE MUST FOLLOW:
{rules_context}

KEY VIOLATIONS TO CHECK (ordered by severity):
1. CRITICAL: Used hyphens or dashes (—, –, -) in responses
2. Asked who someone is in a group chat
3. Used system acknowledgments ("Noted", "Got it", "Understood")
4. Opened with hollow filler ("Hope you're well", "Thanks for reaching out")
5. Described getting excited about technology
6. Wrote like a report (headers, bullet points in casual chat)
7. Failed to SKIP when Josh or Salah posted updates
8. Failed to SKIP thread-closing messages (thumbs up, "thanks", emoji-only)
9. Responded when silence was the correct default
10. Used SA slang excessively (light touches only, mirror client energy)
11. Failed to mirror client language/tone

INTERACTIONS TO REVIEW:
{interaction_text}

RESPOND IN THIS EXACT FORMAT:
SCORE: X/10
TOTAL_INTERACTIONS: N
VIOLATIONS: N
GOOD_DECISIONS: N

VIOLATIONS_LIST:
- [CRITICAL/HIGH/MEDIUM/LOW] Interaction N: Description of violation

GOOD_DECISIONS_LIST:
- Interaction N: What she did well

PATTERNS:
- Pattern 1: Description (count: N occurrences)

RECOMMENDATIONS:
- Recommendation 1
- Recommendation 2

OVERALL: One paragraph summary of Sophia's performance today."""

log("Calling GPT-4o for grading...")
grade_result = call_openai(grading_prompt)

if not grade_result:
    log("Grading failed — no response from OpenAI")
    with open(REPORT_FILE, "w") as f:
        f.write(f"# Sophia Daily Review — {TODAY}\n\n")
        f.write("## Error\nGPT-4o grading call failed. Manual review needed.\n\n")
        f.write(f"## Raw Interactions ({len(interactions)} total)\n")
        f.write(interaction_text)
    sys.exit(1)

log("Grading complete")

# --- Parse score ---
score_match = re.search(r'SCORE:\s*(\d+)/10', grade_result)
score = int(score_match.group(1)) if score_match else "?"
violations_match = re.search(r'VIOLATIONS:\s*(\d+)', grade_result)
violation_count = int(violations_match.group(1)) if violations_match else 0

# --- Write report ---
with open(REPORT_FILE, "w") as f:
    f.write(f"# Sophia Daily Review — {TODAY}\n\n")
    f.write(f"**Score:** {score}/10\n")
    f.write(f"**Interactions reviewed:** {len(interactions)}\n\n")
    f.write("## GPT-4o Assessment\n\n")
    f.write(grade_result + "\n\n")
    f.write("---\n\n")
    f.write(f"## Raw Interactions ({len(interactions)} total)\n\n")
    f.write(interaction_text + "\n")

log(f"Report saved to {REPORT_FILE}")

# --- Check for repeated violation patterns (auto-patch trigger) ---
# Extract violation descriptions from the grading
pattern_section = re.search(r'PATTERNS:\n(.*?)(?:\n\n|\nRECOMMENDATIONS:)', grade_result, re.DOTALL)
auto_patch_candidates = []

if pattern_section:
    for pat_line in pattern_section.group(1).strip().split("\n"):
        count_match = re.search(r'count:\s*(\d+)', pat_line)
        if count_match and int(count_match.group(1)) >= 3:
            auto_patch_candidates.append(pat_line.strip().lstrip("- "))

if auto_patch_candidates:
    log(f"Found {len(auto_patch_candidates)} patterns with 3+ occurrences — generating patches")

    patch_prompt = f"""Based on these recurring Sophia violations (3+ occurrences today):

{chr(10).join(auto_patch_candidates)}

Current group prompt rules are in sophia-whatsapp-group.md.
Current DM prompt rules are in sophia-personal-dm.md.

Suggest SPECIFIC text additions to add to the prompt files to prevent these violations.
Format as:
FILE: filename
ADD_AFTER: "exact line to add after"
NEW_LINE: "new rule text to insert"

Only suggest additions, never deletions. Be specific and concise."""

    patch_result = call_openai(patch_prompt)

    if patch_result:
        # Save patch suggestions to report (don't auto-apply yet until proven reliable)
        with open(REPORT_FILE, "a") as f:
            f.write("\n## Auto-Patch Suggestions (3+ recurring violations)\n\n")
            f.write(patch_result + "\n")

        # Parse and apply patches
        patches_applied = 0
        for block in patch_result.split("FILE:")[1:]:
            lines = block.strip().split("\n")
            if len(lines) < 3:
                continue

            filename = lines[0].strip()
            target_file = None
            if "group" in filename.lower():
                target_file = GROUP_PROMPT
            elif "dm" in filename.lower() or "personal" in filename.lower():
                target_file = DM_PROMPT

            if not target_file or not os.path.exists(target_file):
                continue

            add_after_match = re.search(r'ADD_AFTER:\s*"(.+?)"', block)
            new_line_match = re.search(r'NEW_LINE:\s*"(.+?)"', block)

            if add_after_match and new_line_match:
                anchor = add_after_match.group(1)
                new_rule = new_line_match.group(1)

                try:
                    with open(target_file, "r") as f:
                        content = f.read()

                    if anchor in content and new_rule not in content:
                        content = content.replace(anchor, f"{anchor}\n{new_rule}")
                        with open(target_file, "w") as f:
                            f.write(content)
                        patches_applied += 1
                        log(f"Auto-patched {os.path.basename(target_file)}: {new_rule[:60]}...")
                except Exception as e:
                    log(f"Patch failed for {target_file}: {e}")

        if patches_applied:
            with open(REPORT_FILE, "a") as f:
                f.write(f"\n**{patches_applied} patches auto-applied.**\n")
            log(f"{patches_applied} auto-patches applied to prompt files")

# --- Telegram summary ---
emoji = "🟢" if isinstance(score, int) and score >= 8 else "🟡" if isinstance(score, int) and score >= 5 else "🔴"

tg_msg = f"""{emoji} <b>Sophia Daily Review — {TODAY}</b>

Score: <b>{score}/10</b>
Interactions: {len(interactions)}
Violations: {violation_count}"""

if auto_patch_candidates:
    tg_msg += f"\n🔧 Auto-patches: {len(auto_patch_candidates)} patterns detected"

tg_msg += f"\n\n📄 Report: memory/sophia-reviews/{TODAY}.md"

tg_send(tg_msg)
log(f"Score: {score}/10 — review complete")
PYEOF
log "Daily review complete"
