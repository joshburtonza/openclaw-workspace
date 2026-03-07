#!/usr/bin/env bash
# whatsapp-claude-gateway.sh
# Polls whatsapp_messages for unprocessed inbound messages from the owner (Josh).
# Sends each message to Claude and replies via Twilio WhatsApp API.
# Only auto-responds to messages from WA_OWNER_NUMBER.
# Runs every 30s via LaunchAgent (KeepAlive + ThrottleInterval).

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
if [[ -f "$ENV_FILE" ]]; then source "$ENV_FILE"; fi

SUPABASE_URL="${AOS_SUPABASE_URL:-https://afmpbtynucpbglwtbfuz.supabase.co}"
SERVICE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
TWILIO_ACCOUNT_SID="${TWILIO_ACCOUNT_SID:-}"
TWILIO_AUTH_TOKEN="${TWILIO_AUTH_TOKEN:-}"
# Twilio WhatsApp-enabled number in E.164 (e.g. +14155238886 for sandbox)
TWILIO_WA_FROM="${TWILIO_WA_FROM:-}"
DEEPGRAM_API_KEY="${DEEPGRAM_API_KEY:-}"
# Josh's personal WhatsApp number in E.164 (e.g. +27821234567)
WA_OWNER_NUMBER="${WA_OWNER_NUMBER:-}"

HISTORY_FILE="$WS/tmp/whatsapp-chat-history.jsonl"
LOG_FILE="$WS/out/whatsapp-gateway.log"
ERR_FILE="$WS/out/whatsapp-gateway-errors.log"
SYSTEM_PROMPT_FILE="$WS/prompts/telegram-claude-system.md"

mkdir -p "$WS/tmp" "$WS/out"
touch "$HISTORY_FILE"

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE" 2>/dev/null || true; }

# ── Bail early if credentials are placeholders or missing ────────────────────
if [[ -z "$TWILIO_ACCOUNT_SID" || "$TWILIO_ACCOUNT_SID" == REPLACE* ]]; then
  log "SKIP: TWILIO_ACCOUNT_SID not configured"
  exit 0
fi
if [[ -z "$TWILIO_AUTH_TOKEN" || "$TWILIO_AUTH_TOKEN" == REPLACE* ]]; then
  log "SKIP: TWILIO_AUTH_TOKEN not configured"
  exit 0
fi
if [[ -z "$TWILIO_WA_FROM" ]]; then
  log "SKIP: TWILIO_WA_FROM not set"
  exit 0
fi
if [[ -z "$WA_OWNER_NUMBER" ]]; then
  log "SKIP: WA_OWNER_NUMBER not set — set Josh's WhatsApp number in .env.scheduler"
  exit 0
fi

export SUPABASE_URL SERVICE_KEY TWILIO_ACCOUNT_SID TWILIO_AUTH_TOKEN TWILIO_WA_FROM
export DEEPGRAM_API_KEY WA_OWNER_NUMBER WS HISTORY_FILE ERR_FILE SYSTEM_PROMPT_FILE

# ── Fetch + process unread messages via Python ────────────────────────────────
python3 - <<'PY'
import os, json, sys, datetime, subprocess, tempfile, urllib.request, urllib.parse, urllib.error, base64

SUPABASE_URL   = os.environ['SUPABASE_URL']
SERVICE_KEY    = os.environ['SERVICE_KEY']
TWILIO_SID     = os.environ['TWILIO_ACCOUNT_SID']
TWILIO_TOKEN   = os.environ['TWILIO_AUTH_TOKEN']
TWILIO_FROM    = os.environ['TWILIO_WA_FROM']   # e.g. +14155238886
DEEPGRAM_KEY   = os.environ.get('DEEPGRAM_API_KEY', '')
OWNER_NUMBER   = os.environ['WA_OWNER_NUMBER']  # e.g. +27821234567
WS             = os.environ['WS']
HISTORY_FILE   = os.environ['HISTORY_FILE']
ERR_FILE       = os.environ['ERR_FILE']
SYSTEM_PROMPT_FILE = os.environ['SYSTEM_PROMPT_FILE']

SAST = datetime.timezone(datetime.timedelta(hours=2))

# ── Twilio Basic auth header ───────────────────────────────────────────────────
_TWILIO_AUTH = 'Basic ' + base64.b64encode(f'{TWILIO_SID}:{TWILIO_TOKEN}'.encode()).decode()

# ── Helpers ───────────────────────────────────────────────────────────────────

def log(msg):
    try:
        ts = datetime.datetime.now(SAST).strftime('%H:%M:%S')
        with open(f"{WS}/out/whatsapp-gateway.log", 'a') as f:
            f.write(f"[{ts}] {msg}\n")
    except Exception:
        pass

def supa_get(path, params=None):
    url = f"{SUPABASE_URL}/rest/v1/{path}"
    if params:
        url += '?' + urllib.parse.urlencode(params)
    req = urllib.request.Request(url, headers={
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
        'Accept': 'application/json',
    })
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read())

def supa_patch(path, params, body):
    url = f"{SUPABASE_URL}/rest/v1/{path}?" + urllib.parse.urlencode(params)
    data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method='PATCH', headers={
        'apikey': SERVICE_KEY,
        'Authorization': f'Bearer {SERVICE_KEY}',
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal',
    })
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status in (200, 204)

def wa_send(to_number, text):
    """Send a WhatsApp reply via Twilio Messages API, chunking if needed."""
    # Build list of chunks (WhatsApp max 4096 chars)
    chunks = []
    if len(text) <= 4000:
        chunks = [text]
    else:
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

    url = f'https://api.twilio.com/2010-04-01/Accounts/{TWILIO_SID}/Messages.json'
    for chunk in chunks:
        body = urllib.parse.urlencode({
            'From': f'whatsapp:{TWILIO_FROM}',
            'To':   f'whatsapp:{to_number}',
            'Body': chunk,
        }).encode()
        req = urllib.request.Request(url, data=body, headers={
            'Authorization': _TWILIO_AUTH,
            'Content-Type':  'application/x-www-form-urlencoded',
        })
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                resp = json.loads(r.read())
                sid  = resp.get('sid', '')
                log(f"Sent chunk ({len(chunk)} chars) to {to_number} — sid={sid}")
        except urllib.error.HTTPError as e:
            body_err = e.read().decode('utf-8', errors='replace')
            log(f"ERROR wa_send HTTP {e.code}: {body_err[:300]}")
            raise

def download_twilio_media(media_url):
    """Download Twilio-hosted media (image/audio/video) using Basic auth."""
    req = urllib.request.Request(media_url, headers={
        'Authorization': _TWILIO_AUTH,
    })
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()

def transcribe_audio(audio_bytes, mime_type='audio/ogg'):
    """Transcribe audio via Deepgram nova-2."""
    if not DEEPGRAM_KEY or DEEPGRAM_KEY.startswith('REPLACE'):
        return '[Voice message — Deepgram key not configured]'
    req = urllib.request.Request(
        'https://api.deepgram.com/v1/listen?model=nova-2&smart_format=true&detect_language=true',
        data=audio_bytes,
        headers={
            'Authorization': f'Token {DEEPGRAM_KEY}',
            'Content-Type':  mime_type,
        },
        method='POST',
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        dg = json.loads(r.read())
    transcript = (
        dg.get('results', {})
          .get('channels', [{}])[0]
          .get('alternatives', [{}])[0]
          .get('transcript', '')
          .strip()
    )
    detected_lang = (
        dg.get('results', {})
          .get('channels', [{}])[0]
          .get('detected_language', '')
    )
    lang_note = f' [{detected_lang}]' if detected_lang and detected_lang != 'en' else ''
    if transcript:
        return f'[Voice message{lang_note} — transcribed]: {transcript}'
    return '[Voice message — transcription returned empty]'

def load_history(n=20):
    lines = []
    try:
        with open(HISTORY_FILE) as f:
            lines = [l.strip() for l in f if l.strip()]
    except FileNotFoundError:
        pass
    entries = []
    for line in lines[-n:]:
        try:
            entries.append(json.loads(line))
        except Exception:
            pass
    return entries

def build_history_text(entries):
    return '\n'.join(f"{e.get('role','?')}: {e.get('message','')}" for e in entries)

def append_history(role, message):
    with open(HISTORY_FILE, 'a') as f:
        f.write(json.dumps({'role': role, 'message': message}) + '\n')

def run_claude(prompt_text):
    """Write prompt to tmpfile and run claude --print."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, prefix='/tmp/wa-prompt-') as f:
        f.write(prompt_text)
        tmpfile = f.name
    try:
        env = dict(os.environ)
        env.pop('CLAUDECODE', None)
        result = subprocess.run(
            ['claude', '--print', '--model', 'claude-sonnet-4-6', '--dangerously-skip-permissions'],
            stdin=open(tmpfile, 'r'),
            capture_output=True,
            text=True,
            timeout=120,
            env=env,
        )
        if result.returncode != 0:
            err = result.stderr.strip()[:500]
            log(f"ERROR claude exited {result.returncode}: {err}")
            with open(ERR_FILE, 'a') as f:
                f.write(f"[{datetime.datetime.now(SAST).isoformat()}] Claude error: {err}\n")
            return None
        return result.stdout.strip()
    except subprocess.TimeoutExpired:
        log("ERROR claude timed out after 120s")
        return None
    except FileNotFoundError:
        log("ERROR claude binary not found in PATH")
        return None
    finally:
        os.unlink(tmpfile)

# ── Fetch unprocessed messages from owner ─────────────────────────────────────
try:
    msgs = supa_get('whatsapp_messages', {
        'reply_sent': 'is.null',
        'from_number': f'eq.{OWNER_NUMBER}',
        'order': 'received_at.asc',
        'select': 'id,message_id,from_number,from_name,message_type,body,media_url,media_mime_type,received_at',
    })
except urllib.error.URLError as e:
    log(f"Supabase fetch error (network): {e}")
    sys.exit(0)
except urllib.error.HTTPError as e:
    body = e.read().decode('utf-8', errors='replace')
    log(f"Supabase fetch HTTP {e.code}: {body[:200]}")
    sys.exit(0)
except Exception as e:
    log(f"Supabase fetch unexpected error: {e}")
    sys.exit(0)

if not msgs:
    sys.exit(0)

log(f"Found {len(msgs)} unprocessed message(s) from {OWNER_NUMBER}")

# ── Load fixed context ─────────────────────────────────────────────────────────
system_prompt = 'You are Claude, Amalfi AI\'s AI assistant. You are talking to Josh via WhatsApp.'
try:
    with open(SYSTEM_PROMPT_FILE) as f:
        system_prompt = f.read()
except FileNotFoundError:
    pass

long_term_memory = ''
try:
    with open(f"{WS}/memory/MEMORY.md") as f:
        long_term_memory = f.read()
except Exception:
    pass

current_state = ''
try:
    with open(f"{WS}/CURRENT_STATE.md") as f:
        current_state = f.read()
except Exception:
    pass

josh_profile = ''
try:
    with open(f"{WS}/memory/josh-profile.md") as f:
        josh_profile = f.read()
except Exception:
    pass

# ── Process each message ───────────────────────────────────────────────────────
for msg in msgs:
    row_id    = msg['id']
    from_num  = msg.get('from_number', OWNER_NUMBER)
    msg_type  = msg.get('message_type', 'text')
    body      = msg.get('body') or ''
    media_url = msg.get('media_url') or ''
    mime_type = msg.get('media_mime_type') or 'audio/ogg'

    # ── Resolve user text ──────────────────────────────────────────────────────
    if msg_type == 'text':
        user_text = body
    elif msg_type in ('audio', 'voice'):
        if media_url:
            try:
                audio_bytes = download_twilio_media(media_url)
                user_text   = transcribe_audio(audio_bytes, mime_type)
                log(f"Transcribed audio: {user_text[:80]}")
            except Exception as e:
                log(f"Audio transcription failed for {row_id}: {e}")
                user_text = f'[Voice message — transcription failed: {e}]'
        else:
            user_text = '[Voice message received — no media URL]'
    elif msg_type == 'image':
        user_text = f'[Image received{(" — " + body) if body else ""}]'
    else:
        user_text = body or f'[{msg_type} message]'

    if not user_text:
        log(f"Skipping empty message {row_id}")
        continue

    # ── Build prompt ───────────────────────────────────────────────────────────
    today           = datetime.datetime.now(SAST).strftime('%A, %d %B %Y %H:%M SAST')
    history_entries = load_history(20)
    history_text    = build_history_text(history_entries)

    memory_block = ''
    if josh_profile or long_term_memory or current_state:
        memory_block = f"""
=== WHO JOSH IS ===
{josh_profile}

=== LONG-TERM MEMORY ===
{long_term_memory}

=== CURRENT SYSTEM STATE ===
{current_state}
"""

    if history_text:
        full_prompt = (
            f"{system_prompt}\n\n"
            f"Today: {today}\nChannel: WhatsApp\n"
            f"{memory_block}\n"
            f"=== RECENT CONVERSATION ===\n{history_text}\n\n"
            f"Josh: {user_text}"
        )
    else:
        full_prompt = (
            f"{system_prompt}\n\n"
            f"Today: {today}\nChannel: WhatsApp\n"
            f"{memory_block}\n"
            f"Josh: {user_text}"
        )

    # ── Store user message in history ──────────────────────────────────────────
    append_history('Josh', user_text)

    # ── Run Claude ─────────────────────────────────────────────────────────────
    log(f"Running Claude for: {user_text[:80]}")
    response = run_claude(full_prompt)

    if not response:
        log(f"No response from Claude for {row_id}")
        try:
            supa_patch('whatsapp_messages', {'id': f'eq.{row_id}'}, {
                'reply_sent': '[Claude returned no response]',
                'replied_at': datetime.datetime.utcnow().isoformat() + 'Z',
            })
        except Exception as ex:
            log(f"Failed to mark no-response: {ex}")
        continue

    # ── Send WhatsApp reply via Twilio ─────────────────────────────────────────
    try:
        wa_send(from_num, response)
    except Exception as e:
        log(f"WhatsApp send failed for {row_id}: {e}")
        with open(ERR_FILE, 'a') as f:
            f.write(f"[{datetime.datetime.now(SAST).isoformat()}] WA send error: {e}\n")
        continue

    # ── Store response in history ──────────────────────────────────────────────
    append_history('Claude', response)

    # ── Daily conversation log ────────────────────────────────────────────────
    today_log = f"{WS}/memory/{datetime.datetime.now(SAST).strftime('%Y-%m-%d')}.md"
    try:
        ts = datetime.datetime.now(SAST).strftime('%H:%M SAST')
        with open(today_log, 'a') as f:
            f.write(f"\n### {ts} — WhatsApp\n**Josh:** {user_text}\n**Claude:** {response}\n")
    except Exception:
        pass

    # ── Mark row replied ────────────────────────────────────────────────────────
    try:
        supa_patch('whatsapp_messages', {'id': f'eq.{row_id}'}, {
            'reply_sent': response[:2000],
            'replied_at': datetime.datetime.utcnow().isoformat() + 'Z',
        })
        log(f"Done: replied to {row_id}")
    except Exception as e:
        log(f"Failed to mark replied for {row_id}: {e}")

log("Run complete")
PY
