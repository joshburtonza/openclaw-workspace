#!/bin/bash
# meeting-digest.sh
# Watches meetings/inbox/ for dropped Read.ai/Fathom transcript files (.txt / .md).
# When a new transcript is detected, Claude extracts:
#   (1) CRM note → memory/meeting-journal.md + Telegram
#   (2) Draft follow-up email → email_queue (awaiting_approval)
#   (3) Action items → tasks table in Supabase
#
# Runs every 10 min via LaunchAgent.
# Drop a transcript: cp my-meeting.txt meetings/inbox/

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a
source "$WS/scripts/lib/task-helpers.sh"

LOG="$WS/out/meeting-digest.log"
INBOX="$WS/meetings/inbox"
ARCHIVE="$WS/meetings/archive"
JOURNAL="$WS/memory/meeting-journal.md"

mkdir -p "$INBOX" "$ARCHIVE" "$WS/out"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }
log "=== Meeting digest run ==="

# Quick exit if inbox is empty
shopt -s nullglob
inbox_files=("$INBOX"/*.txt "$INBOX"/*.md)
shopt -u nullglob

if [[ ${#inbox_files[@]} -eq 0 ]]; then
  log "No transcripts in meetings/inbox/ — nothing to do."
  exit 0
fi

log "Found ${#inbox_files[@]} transcript file(s). Processing..."

TASK_ID=$(task_create "Meeting Digest" "Processing ${#inbox_files[@]} transcript(s) from meetings/inbox/" "meeting-digest" "normal")

KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="${TELEGRAM_JOSH_CHAT_ID:-1140320036}"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
MODEL="claude-sonnet-4-6"

export KEY SUPABASE_URL BOT_TOKEN CHAT_ID MODEL INBOX ARCHIVE JOURNAL WS

python3 - <<'PY'
import os, sys, glob, shutil, json, subprocess, datetime, re, tempfile, urllib.request

KEY          = os.environ['KEY']
SUPABASE_URL = os.environ['SUPABASE_URL']
BOT_TOKEN    = os.environ.get('BOT_TOKEN', '')
CHAT_ID      = os.environ.get('CHAT_ID', '')
MODEL        = os.environ['MODEL']
INBOX        = os.environ['INBOX']
ARCHIVE      = os.environ['ARCHIVE']
JOURNAL      = os.environ['JOURNAL']
WS           = os.environ['WS']

# ── Client mappings ───────────────────────────────────────────────────────────

CLIENT_KEYWORDS = {
    'ascend':          'ascend_lc',
    'qms':             'ascend_lc',
    'riaan':           'ascend_lc',
    'favlog':          'favorite_logistics',
    'favorite':        'favorite_logistics',
    'flair':           'favorite_logistics',
    'irshad':          'favorite_logistics',
}

CLIENT_EMAILS = {
    'ascend_lc':           'riaan@ascendlc.co.za',
    'favorite_logistics':  'rapizo92@gmail.com',
}

CLIENT_NAMES = {
    'ascend_lc':           'Ascend LC',
    'favorite_logistics':  'Favorite Logistics',
}

CLIENT_JOURNAL_SECTIONS = {
    'ascend_lc':           'QMS-GUARD',
    'favorite_logistics':  'FAVORITE-FLOW',
}

CLIENT_CONTEXT_PATHS = {
    'ascend_lc':           f"{WS}/clients/qms-guard/CONTEXT.md",
    'favorite_logistics':  f"{WS}/clients/favorite-flow-9637aff2/CONTEXT.md",
}

# ── Helpers ───────────────────────────────────────────────────────────────────

def tg_send(text):
    if not BOT_TOKEN or not CHAT_ID:
        return
    data = json.dumps({'chat_id': CHAT_ID, 'text': text, 'parse_mode': 'HTML'}).encode()
    req = urllib.request.Request(
        f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
        data=data, headers={'Content-Type': 'application/json'}, method='POST'
    )
    try:
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

def supa_post(path, body):
    if not KEY:
        print(f"  [warn] No Supabase key — skipping insert to {path}")
        return
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers={
            'apikey': KEY, 'Authorization': f'Bearer {KEY}',
            'Content-Type': 'application/json', 'Prefer': 'return=minimal',
        },
        method='POST',
    )
    try:
        urllib.request.urlopen(req, timeout=15)
    except Exception as e:
        print(f"  [warn] supa_post {path} failed: {e}")

def run_claude(prompt_text, timeout=180):
    """Run claude --print with prompt via stdin, return stdout text."""
    env = {k: v for k, v in os.environ.items() if k not in ('CLAUDECODE', 'CLAUDE_CODE')}
    with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False,
                                      prefix='/tmp/meeting-digest-') as f:
        f.write(prompt_text)
        pf = f.name
    try:
        result = subprocess.run(
            ['claude', '--print', '--model', MODEL],
            stdin=open(pf), capture_output=True, text=True, timeout=timeout, env=env,
        )
        return result.stdout.strip() or result.stderr.strip() or '(No response)'
    except Exception as e:
        return f'(Claude failed: {e})'
    finally:
        try:
            os.unlink(pf)
        except Exception:
            pass

def update_journal(date_str, meeting_name, client_key, crm_note):
    """Append CRM note to memory/meeting-journal.md, creating the section if needed."""
    section_header = CLIENT_JOURNAL_SECTIONS.get(client_key, 'OTHER')

    try:
        with open(JOURNAL, 'r') as f:
            content = f.read()
    except FileNotFoundError:
        content = "# Meeting Journal\n\n*Last updated: — 0 meetings*\n\n---\n"

    # Bump meeting count in header
    count_match = re.search(r'(\d+) meetings\*', content)
    old_count = int(count_match.group(1)) if count_match else 0
    new_count = old_count + 1
    content = re.sub(
        r'\*Last updated:.*?\*',
        f'*Last updated: {date_str} — {new_count} meetings*',
        content,
    )

    # Build the meeting entry block
    entry = (
        f"\n### {date_str} — {meeting_name}\n\n"
        f"**Meeting type:** Post-meeting digest\n"
        f"**Client/With:** {CLIENT_NAMES.get(client_key, 'Unknown')}\n"
        f"**Date:** {date_str}\n\n"
        f"---\n\n"
        f"{crm_note}\n\n"
        f"---\n"
    )

    section_line = f"## {section_header}"
    if section_line in content:
        # Insert immediately after the section header line
        content = content.replace(section_line + '\n', section_line + '\n' + entry, 1)
    else:
        # Create a new section at the end
        content = content.rstrip() + f'\n\n{section_line}\n{entry}'

    with open(JOURNAL, 'w') as f:
        f.write(content)

# ── Main processing loop ──────────────────────────────────────────────────────

files = sorted(glob.glob(f"{INBOX}/*.txt") + glob.glob(f"{INBOX}/*.md"))

if not files:
    print("Nothing to process.")
    sys.exit(0)

processed = 0
errors = 0
date_str = datetime.datetime.now().strftime('%Y-%m-%d')

for filepath in files:
    filename  = os.path.basename(filepath)
    meeting_name = os.path.splitext(filename)[0].replace('-', ' ').replace('_', ' ').strip()
    print(f"\n  Processing: {filename}")

    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read().strip()

        if len(content) < 100:
            print(f"  [skip] Content too short — skipping")
            continue

        # ── Detect client ─────────────────────────────────────────────────────
        probe = (filename + ' ' + content[:1500]).lower()
        client_key  = next((v for k, v in CLIENT_KEYWORDS.items() if k in probe), None)
        client_name = CLIENT_NAMES.get(client_key, 'Unknown / Prospect')

        # Load client context if available
        client_context = ''
        if client_key:
            ctx_path = CLIENT_CONTEXT_PATHS.get(client_key, '')
            if ctx_path and os.path.exists(ctx_path):
                with open(ctx_path) as cf:
                    client_context = f"\n## Client Context\n{cf.read()[:3000]}\n"

        print(f"  Client: {client_name}")

        # ── Run Claude: extract all three outputs ─────────────────────────────
        prompt = f"""You are a post-meeting extraction agent for Josh Burton, founder of Amalfi AI — an AI automation agency in South Africa.
{client_context}
## Meeting: {meeting_name}

## Transcript / Notes
{content[:12000]}

Extract THREE things from this meeting. Return them in EXACTLY this format with the exact section headers shown. No preamble, no commentary outside the sections.

---CRM_NOTE---
[Write a 2-3 paragraph CRM note for Sophia (Amalfi AI's AI account manager). Third person, past tense. Cover: what was discussed, decisions made, relationship health, specific next steps committed to, anything to watch out for. Include names, specific numbers or figures mentioned, any promises made. South African English — warm but professional.]

---FOLLOW_UP_EMAIL---
Subject: [subject line]

[Write the full follow-up email from Josh to the client/prospect. Reference specific points discussed. Include clear next steps. 150-250 words. Warm SA business English. Write it ready to send — no placeholders, no [brackets]. If the meeting was internal or no clear external recipient, write a brief internal summary email to the Amalfi team instead.]

---ACTION_ITEMS---
[JSON array only — no other text. Each item: {{"title": "Short action title", "owner": "Josh|Client|Both", "priority": "high|normal", "description": "Specific detail of what needs doing"}}. Only include concrete commitments or clear next steps from the meeting. Return [] if there are no action items.]"""

        print(f"  Running Claude extraction...")
        raw_output = run_claude(prompt, timeout=180)

        # ── Parse the three sections ──────────────────────────────────────────
        crm_note     = ''
        follow_up    = ''
        action_items = []

        crm_match    = re.search(r'---CRM_NOTE---\s*(.*?)(?=---FOLLOW_UP_EMAIL---|$)',    raw_output, re.DOTALL)
        email_match  = re.search(r'---FOLLOW_UP_EMAIL---\s*(.*?)(?=---ACTION_ITEMS---|$)', raw_output, re.DOTALL)
        actions_match = re.search(r'---ACTION_ITEMS---\s*(.*?)$',                          raw_output, re.DOTALL)

        if crm_match:
            crm_note = crm_match.group(1).strip()
        if email_match:
            follow_up = email_match.group(1).strip()
        if actions_match:
            raw_json = actions_match.group(1).strip()
            raw_json = re.sub(r'^```json?\s*', '', raw_json, flags=re.MULTILINE)
            raw_json = re.sub(r'```\s*$',       '', raw_json, flags=re.MULTILINE)
            try:
                parsed = json.loads(raw_json.strip())
                if isinstance(parsed, list):
                    action_items = parsed
            except Exception as e:
                print(f"  [warn] Action items JSON parse failed: {e}")

        # ── (1) CRM note → meeting-journal.md ────────────────────────────────
        if crm_note:
            update_journal(date_str, meeting_name, client_key, crm_note)
            print(f"  [ok] CRM note saved to meeting-journal.md")
        else:
            print(f"  [warn] No CRM note extracted — check Claude output")

        # ── (2) Follow-up email → email_queue (awaiting_approval) ────────────
        email_queued = False
        if follow_up:
            subject_match = re.match(r'^Subject:\s*(.+?)[\r\n]', follow_up, re.IGNORECASE)
            if subject_match:
                subject_line = subject_match.group(1).strip()
                email_body   = follow_up[subject_match.end():].strip()
            else:
                subject_line = f"Following up from our meeting — {meeting_name}"
                email_body   = follow_up

            to_email   = CLIENT_EMAILS.get(client_key, '') if client_key else ''
            to_display = to_email or 'no client detected'

            if to_email:
                supa_post("email_queue", {
                    "from_email":        "sophia@amalfiai.com",
                    "to_email":          to_email,
                    "subject":           subject_line,
                    "body":              email_body,
                    "client":            client_key,
                    "status":            "awaiting_approval",
                    "requires_approval": True,
                    "analysis": {
                        "source":    "meeting-digest",
                        "meeting":   meeting_name,
                        "generated": date_str,
                    },
                })
                print(f"  [ok] Follow-up email queued → {to_email}: {subject_line}")
                email_queued = True
            else:
                # No matched client — queue as unknown for Josh to review
                supa_post("email_queue", {
                    "from_email":        "sophia@amalfiai.com",
                    "to_email":          "josh@amalfiai.com",
                    "subject":           f"[DRAFT — no client matched] {subject_line}",
                    "body":              email_body,
                    "client":            "unknown",
                    "status":            "awaiting_approval",
                    "requires_approval": True,
                    "analysis": {
                        "source":    "meeting-digest",
                        "meeting":   meeting_name,
                        "generated": date_str,
                        "note":      "Client not auto-detected — please review recipient before approving",
                    },
                })
                print(f"  [ok] Follow-up email queued (no client match — routed to Josh for review)")
                email_queued = True
        else:
            print(f"  [warn] No follow-up email generated")

        # ── (3) Action items → tasks table ────────────────────────────────────
        tasks_created = 0
        for item in action_items:
            if not isinstance(item, dict):
                continue
            title       = item.get('title', 'Action item')[:120]
            owner       = item.get('owner', 'Josh')
            raw_pri     = item.get('priority', 'normal')
            description = (item.get('description', '') or '') + f"\n\nSource: {meeting_name} ({date_str})"
            priority    = {'high': 'high', 'urgent': 'urgent'}.get(raw_pri, 'normal')

            if 'client' in owner.lower():
                assigned_to = 'Client'
            elif 'both' in owner.lower():
                assigned_to = 'Josh'
            else:
                assigned_to = 'Josh'

            supa_post("tasks", {
                "title":       f"[{meeting_name}] {title}",
                "description": description,
                "assigned_to": assigned_to,
                "created_by":  "meeting-digest",
                "priority":    priority,
                "status":      "todo",
                "tags":        ["meeting-action", "auto"],
            })
            tasks_created += 1

        if tasks_created:
            print(f"  [ok] {tasks_created} action item(s) created in tasks")
        else:
            print(f"  [info] No action items to create")

        # ── Telegram notification ─────────────────────────────────────────────
        crm_preview   = (crm_note[:600] + '...') if len(crm_note) > 600 else crm_note
        email_line    = "\n✉️ Follow-up email queued for approval" if email_queued else ""
        actions_line  = f"\n✅ {tasks_created} action item(s) added to tasks" if tasks_created else ""

        tg_send(
            f"📋 <b>Meeting digest: {meeting_name}</b>\n"
            f"<b>Client:</b> {client_name}"
            f"{email_line}"
            f"{actions_line}\n\n"
            f"<b>CRM note:</b>\n{crm_preview}"
        )

        # ── Archive ───────────────────────────────────────────────────────────
        archive_name = f"{date_str}_{filename}"
        shutil.move(filepath, f"{ARCHIVE}/{archive_name}")
        print(f"  [ok] Archived → {archive_name}")
        processed += 1

    except Exception as e:
        import traceback
        print(f"  [!] Error processing {filename}: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        errors += 1

print(f"\nDone. Processed: {processed} | Errors: {errors}")
PY

task_complete "$TASK_ID" "Meeting digest complete — check out/ log for details"
log "Meeting digest complete."
