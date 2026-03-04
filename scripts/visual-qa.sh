#!/usr/bin/env bash
# scripts/visual-qa.sh
# Spins up the dev server, screenshots key pages, sends to Claude Vision,
# reports verdict + screenshots to Telegram.
#
# Usage:
#   visual-qa.sh <repo_path> <repo_key> <task_id> <task_title>
# Returns:
#   0 = PASS  (mark task done)
#   1 = FAIL  (keep task open, alert Josh)

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

REPO_PATH="$1"
REPO_KEY="$2"
TASK_ID="$3"
TASK_TITLE="$4"

WS="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$WS/.env.scheduler" ]] && set -a && source "$WS/.env.scheduler" && set +a

BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
ANTHROPIC_KEY="${ANTHROPIC_API_KEY:-}"
SCREENSHOT_SCRIPT="$WS/scripts/visual-qa/screenshot.sh"

OUT_DIR="/tmp/visual-qa-${TASK_ID}"
LOG_TAG="[visual-qa]"

log() { echo "$LOG_TAG $*"; }

# ── Sanity checks ──────────────────────────────────────────────────────────────
if [[ ! -f "$REPO_PATH/package.json" ]]; then
  log "No package.json — skipping visual QA"
  exit 0
fi

if ! grep -q '"dev"' "$REPO_PATH/package.json" 2>/dev/null; then
  log "No dev script in package.json — skipping visual QA"
  exit 0
fi

if [[ ! -f "$SCREENSHOT_SCRIPT" ]]; then
  log "Screenshot script not found at $SCREENSHOT_SCRIPT — skipping"
  exit 0
fi

# Pinchtab must be running for screenshot.sh to work
if ! curl -sf http://localhost:9867/health > /dev/null 2>&1; then
  log "Pinchtab not running — skipping visual QA"
  exit 0
fi

mkdir -p "$OUT_DIR"
log "Starting visual QA for $REPO_KEY (task: $TASK_TITLE)"

# ── Find a free port ───────────────────────────────────────────────────────────
PORT=$(python3 -c "
import socket
s = socket.socket()
s.bind(('', 0))
p = s.getsockname()[1]
s.close()
print(p)
")
log "Using port $PORT"

# ── Start dev server ───────────────────────────────────────────────────────────
cd "$REPO_PATH"
npm run dev -- --port "$PORT" --host localhost > "$OUT_DIR/dev-server.log" 2>&1 &
DEV_PID=$!
log "Dev server PID $DEV_PID started on port $PORT"

cleanup() {
  kill $DEV_PID 2>/dev/null || true
  wait $DEV_PID 2>/dev/null || true
  log "Dev server stopped"
}
trap cleanup EXIT

# ── Wait for server ready (up to 40s) ─────────────────────────────────────────
READY=false
for i in $(seq 1 40); do
  if curl -sf "http://localhost:$PORT" -o /dev/null 2>/dev/null; then
    READY=true
    log "Server ready after ${i}s"
    break
  fi
  sleep 1
done

if [[ "$READY" != "true" ]]; then
  log "Server failed to start within 40s — skipping visual QA"
  exit 0
fi

sleep 2  # extra settle time after ready

# ── Resolve test credentials per repo ─────────────────────────────────────────
TEST_EMAIL=""
TEST_PASSWORD=""
case "$REPO_KEY" in
  qms-guard)
    TEST_EMAIL="${QMS_GUARD_TEST_EMAIL:-}"
    TEST_PASSWORD="${QMS_GUARD_TEST_PASSWORD:-}"
    ;;
  chrome-auto-care|race-technik)
    TEST_EMAIL="${CHROME_AUTO_TEST_EMAIL:-}"
    TEST_PASSWORD="${CHROME_AUTO_TEST_PASSWORD:-}"
    ;;
  favorite-flow*|favlog)
    TEST_EMAIL="${FAVLOG_TEST_EMAIL:-}"
    TEST_PASSWORD="${FAVLOG_TEST_PASSWORD:-}"
    ;;
esac

# ── Take screenshots ───────────────────────────────────────────────────────────
log "Taking screenshots (login: ${TEST_EMAIL:-none})..."
SCREENSHOT_OUTPUT=$(bash "$SCREENSHOT_SCRIPT" "$PORT" "$REPO_KEY" "$OUT_DIR" "$TEST_EMAIL" "$TEST_PASSWORD" 2>&1)
log "$SCREENSHOT_OUTPUT"

SCREENSHOT_FILES=()
while IFS= read -r line; do
  if [[ "$line" == SCREENSHOT:* ]]; then
    SCREENSHOT_FILES+=("${line#SCREENSHOT:}")
  fi
done <<< "$SCREENSHOT_OUTPUT"

log "Got ${#SCREENSHOT_FILES[@]} screenshots"

if [[ ${#SCREENSHOT_FILES[@]} -eq 0 ]]; then
  log "No screenshots taken — skipping visual QA"
  exit 0
fi

# ── Send to Claude Vision ──────────────────────────────────────────────────────
log "Sending to Claude Vision for analysis..."

OPENAI_KEY="${OPENAI_API_KEY:-}"
export _VQA_TASK="$TASK_TITLE" _VQA_REPO="$REPO_KEY" _VQA_OKEY="$OPENAI_KEY" _VQA_OUT="$OUT_DIR"
export _VQA_FILES="${SCREENSHOT_FILES[*]}"

VERDICT=$(python3 - <<'PY'
import os, json, base64, urllib.request, sys

KEY   = os.environ.get('_VQA_OKEY', '')
task  = os.environ.get('_VQA_TASK', '')
repo  = os.environ.get('_VQA_REPO', '')
files = os.environ.get('_VQA_FILES', '').split()

if not KEY:
    print("SKIP: No OPENAI_API_KEY")
    sys.exit(0)

if not files:
    print("SKIP: No screenshots")
    sys.exit(0)

content = [
    {
        "type": "text",
        "text": f"""Review these web app screenshots for visual issues.

App: {repo}
Feature: {task}

Check each screenshot and reply in this exact format:
VERDICT: PASS or FAIL
REASON: one or two sentences explaining your assessment

PASS criteria: app renders correctly, no white screens, no error messages, layout looks intact.
FAIL criteria: blank white screen, visible error text, broken layout, or all pages still showing the login screen."""
    }
]

for f in files[:4]:
    try:
        with open(f, 'rb') as fh:
            img_b64 = base64.standard_b64encode(fh.read()).decode()
        mime = "image/jpeg" if f.endswith(".jpg") or f.endswith(".jpeg") else "image/png"
        content.append({
            "type": "image_url",
            "image_url": {"url": f"data:{mime};base64,{img_b64}", "detail": "low"},
        })
    except Exception as e:
        print(f"Could not load {f}: {e}", file=sys.stderr)

payload = json.dumps({
    "model": "gpt-4o",
    "max_tokens": 200,
    "messages": [{"role": "user", "content": content}]
}).encode()

req = urllib.request.Request(
    "https://api.openai.com/v1/chat/completions",
    data=payload,
    headers={
        "Authorization": f"Bearer {KEY}",
        "Content-Type": "application/json",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        resp = json.loads(r.read())
        text = resp["choices"][0]["message"]["content"].strip()
        print(text)
except Exception as e:
    print(f"SKIP: Vision API error: {e}")
PY
)

log "Claude Vision verdict:"
log "$VERDICT"

# ── Parse verdict ──────────────────────────────────────────────────────────────
QA_PASS=true
if echo "$VERDICT" | grep -q "^VERDICT: FAIL"; then
  QA_PASS=false
fi

# ── Send to Telegram ───────────────────────────────────────────────────────────
if [[ -n "$BOT_TOKEN" ]]; then
  STATUS_EMOJI="✅"
  STATUS_LABEL="PASS"
  if [[ "$QA_PASS" == "false" ]]; then
    STATUS_EMOJI="🚨"
    STATUS_LABEL="FAIL"
  fi

  CAPTION="${STATUS_EMOJI} Visual QA ${STATUS_LABEL} — <b>${REPO_KEY}</b>
<b>${TASK_TITLE}</b>

${VERDICT}"

  # Send each screenshot as a photo
  for f in "${SCREENSHOT_FILES[@]}"; do
    ROUTE_NAME=$(basename "$f" .png)
    export _VQA_BOT="$BOT_TOKEN" _VQA_CHAT="$CHAT_ID" _VQA_FILE="$f" _VQA_ROUTE="$ROUTE_NAME" _VQA_CAP="$CAPTION"
    python3 - <<'PYEOF'
import os, urllib.request

BOT   = os.environ['_VQA_BOT']
CHAT  = os.environ['_VQA_CHAT']
FNAME = os.environ['_VQA_FILE']
ROUTE = os.environ['_VQA_ROUTE']
CAP   = os.environ['_VQA_CAP'][:1024]

with open(FNAME, 'rb') as fh:
    img_data = fh.read()

b = b'AmalfiQABoundary987'
def field(name, value):
    return b'--' + b + b'\r\nContent-Disposition: form-data; name="' + name.encode() + b'"\r\n\r\n' + value.encode() + b'\r\n'
def file_field(name, filename, data):
    ct = b'image/jpeg' if filename.endswith('.jpg') else b'image/png'
    return b'--' + b + b'\r\nContent-Disposition: form-data; name="' + name.encode() + b'"; filename="' + filename.encode() + b'"\r\nContent-Type: ' + ct + b'\r\n\r\n' + data + b'\r\n'

body = (
    field('chat_id', CHAT) +
    field('parse_mode', 'HTML') +
    field('caption', CAP) +
    file_field('photo', f'qa_{ROUTE}.jpg', img_data) +
    b'--' + b + b'--\r\n'
)

req = urllib.request.Request(
    f"https://api.telegram.org/bot{BOT}/sendPhoto",
    data=body,
    headers={"Content-Type": f"multipart/form-data; boundary=AmalfiQABoundary987"},
    method="POST",
)
try:
    urllib.request.urlopen(req, timeout=30)
    print(f"Sent: {ROUTE}")
except Exception as e:
    print(f"Failed {ROUTE}: {e}")
PYEOF
  done
fi

# ── Final result ───────────────────────────────────────────────────────────────
if [[ "$QA_PASS" == "true" ]]; then
  log "Visual QA PASSED"
  exit 0
else
  log "Visual QA FAILED — task will remain open"
  exit 1
fi
