#!/usr/bin/env bash
# research-digest.sh
# 1. Fetches pending research sources (inbox files + dashboard submissions + URLs)
# 2. Extracts strategic intelligence with Claude
# 3. Identifies implementation gaps vs current system → creates tasks
# 4. Updates memory/research-intel.md + system_config table
#
# Runs every 30 min via LaunchAgent.

set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WS/.env.scheduler"
[[ -f "$ENV_FILE" ]] && set -a && source "$ENV_FILE" && set +a

source "$WS/scripts/lib/task-helpers.sh"

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
BOT_TOKEN="${TELEGRAM_BOT_TOKEN:-}"
CHAT_ID="7584896900"
MODEL="claude-sonnet-4-6"
INBOX="$WS/research/inbox"
ARCHIVE="$WS/research/archive"
INTEL_FILE="$WS/memory/research-intel.md"
LOG="$WS/out/research-digest.log"

mkdir -p "$INBOX" "$ARCHIVE" "$WS/out"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "=== Research digest run ==="

export SUPABASE_URL SUPABASE_KEY BOT_TOKEN CHAT_ID MODEL INBOX ARCHIVE INTEL_FILE WS

python3 - <<'PY'
import os, sys, json, glob, shutil, datetime, tempfile, subprocess, re
import urllib.request, urllib.error
from html.parser import HTMLParser

SUPABASE_URL = os.environ['SUPABASE_URL']
KEY          = os.environ['SUPABASE_KEY']
BOT_TOKEN    = os.environ.get('BOT_TOKEN', '')
CHAT_ID      = os.environ.get('CHAT_ID', '')
MODEL        = os.environ['MODEL']
INBOX        = os.environ['INBOX']
ARCHIVE      = os.environ['ARCHIVE']
INTEL_FILE   = os.environ['INTEL_FILE']
WS           = os.environ['WS']

# ── HTML text extractor ──────────────────────────────────────────────────────────

class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.chunks = []
        self._skip = False
        self._skip_tags = {'script','style','nav','header','footer','aside','noscript'}

    def handle_starttag(self, tag, attrs):
        if tag in self._skip_tags:
            self._skip = True

    def handle_endtag(self, tag):
        if tag in self._skip_tags:
            self._skip = False

    def handle_data(self, data):
        if not self._skip:
            text = data.strip()
            if text:
                self.chunks.append(text)

    def get_text(self):
        return ' '.join(self.chunks)

def fetch_url(url):
    """Fetch a URL and return plain text content."""
    req = urllib.request.Request(url, headers={
        'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36'
    })
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            charset = 'utf-8'
            content_type = r.headers.get_content_type()
            if 'charset' in (r.headers.get('Content-Type') or ''):
                try:
                    charset = r.headers.get_content_charset() or 'utf-8'
                except Exception:
                    pass
            html = raw.decode(charset, errors='ignore')
    except Exception as e:
        raise ValueError(f"Failed to fetch URL: {e}")

    parser = TextExtractor()
    parser.feed(html)
    text = parser.get_text()

    # Clean up whitespace
    text = re.sub(r'\s{3,}', '\n\n', text)
    return text.strip()[:20000]  # Cap at 20k chars

# ── Supabase helpers ─────────────────────────────────────────────────────────────

def supa_get(path):
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}"},
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())

def supa_post(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=representation"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())

def supa_patch(path, body):
    data = json.dumps(body).encode()
    req = urllib.request.Request(
        f"{SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers={"apikey": KEY, "Authorization": f"Bearer {KEY}",
                 "Content-Type": "application/json", "Prefer": "return=minimal"},
        method="PATCH",
    )
    with urllib.request.urlopen(req, timeout=20) as r:
        return r.read()

def tg(text):
    if not BOT_TOKEN:
        return
    try:
        data = json.dumps({"chat_id": CHAT_ID, "text": text, "parse_mode": "HTML"}).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendMessage",
            data=data, headers={"Content-Type": "application/json"}, method="POST",
        )
        urllib.request.urlopen(req, timeout=10)
    except Exception:
        pass

def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

# ── Transcript completeness check ───────────────────────────────────────────────

TRUNCATION_SIGNALS = [
    'cut off', 'summary ends', 'read ai summary',
    'the transcript was cut', 'transcript was cut', 'cut short',
    're-run analysis', 'transcript truncated', 'transcript cut',
]

def check_completeness(content):
    """
    Returns dict: {score: 'low'|'medium'|'high', truncated: bool, reasons: [str]}
    Score: low  → word_count < 500 or truncation signal found or ends mid-sentence
           medium → 500–799 words, no signals
           high   → 800+ words, no signals
    """
    words = len(content.split())
    lower = content.lower()

    signals_found = [s for s in TRUNCATION_SIGNALS if s in lower]

    # Check if content ends mid-sentence (no .!? in last 200 chars)
    tail = content.strip()[-200:] if len(content.strip()) > 200 else content.strip()
    ends_mid_sentence = bool(tail) and not any(c in tail for c in '.!?')

    truncated = words < 500 or bool(signals_found) or ends_mid_sentence

    if truncated:
        score = 'low'
    elif words < 800:
        score = 'medium'
    else:
        score = 'high'

    reasons = []
    if words < 500:
        reasons.append(f"word count {words} < 500")
    for s in signals_found:
        reasons.append(f"truncation signal: '{s}'")
    if ends_mid_sentence:
        reasons.append("ends mid-sentence")

    return {"score": score, "truncated": truncated, "reasons": reasons, "word_count": words}

TRUNCATION_WARNING = (
    "**⚠ SOURCE TRUNCATED — intelligence below is partial. "
    "Re-process with full transcript before acting.**\n\n"
)

# ── Source quality gate ──────────────────────────────────────────────────────────

REJECTION_SIGNALS = [
    '[truncated]', 'truncated', 'sparse content', 'minimal content',
    'insufficient content', 'no content', 'no transcript', 'could not be extracted',
    'summary ends', 'cut off', 'cut short',
]

REJECTED_LOG = f"{WS}/out/rejected_sources.log"


class SourceRejected(ValueError):
    """Raised when a source fails the pre-LLM quality gate."""
    pass


def quality_gate(content):
    """
    Pre-LLM quality gate. Returns (rejected: bool, reason: str).

    Rejection criteria:
    - Meaningful word count < 200 (below minimum viable content threshold)
    - OR meaningful word count < 400 with 2+ truncation signals, or 1 signal and < 300 words
    """
    words = content.split()
    meaningful_words = [w for w in words if any(c.isalpha() for c in w)]
    word_count = len(meaningful_words)
    lower = content.lower()

    if word_count < 200:
        return True, f"content below minimum threshold ({word_count} meaningful words < 200)"

    if word_count < 400:
        signals = [s for s in REJECTION_SIGNALS if s in lower]
        if len(signals) >= 2 or (signals and word_count < 300):
            return True, f"thin content ({word_count} words) with truncation signals: {signals[:2]}"

    return False, ""


def log_rejection(title, content, reason, date_str):
    """Append rejected source entry to REJECTED_SOURCES log."""
    os.makedirs(os.path.dirname(REJECTED_LOG), exist_ok=True)
    preview = ' '.join(content.split()[:40])
    ts = datetime.datetime.now().strftime('%H:%M:%S')
    entry = (
        f"\n[{date_str} {ts}] REJECTED: {title}\n"
        f"  Reason: {reason}\n"
        f"  Preview: {preview!r}\n"
    )
    with open(REJECTED_LOG, 'a') as f:
        f.write(entry)
    print(f"  ⛔ Quality gate: source rejected — {reason}")
    print(f"  Logged → {REJECTED_LOG}")
    tg(
        f"⛔ <b>Research source rejected by quality gate</b>\n\n"
        f"<b>{title}</b>\n"
        f"<i>Reason: {reason}</i>\n\n"
        f"Re-submit with the full transcript to process this source."
    )


# ── Claude: extract insights ─────────────────────────────────────────────────────

def extract_insights(title, content):
    """Send source to Claude, get structured intelligence back."""
    if len(content) > 14000:
        content = content[:14000] + "\n\n[... truncated ...]"

    prompt = f"""You are a strategic intelligence analyst for Amalfi AI, a boutique AI automation agency in South Africa run by Josh. Josh builds AI agents and automation systems for SMB clients and is closely tracking the AI agent/automation space.

RESEARCH SOURCE: {title}

CONTENT:
{content}

Extract strategic intelligence relevant to:
1. Where AI agents and automation are heading (next 12-24 months)
2. Business model patterns and pricing signals for AI agencies
3. SMB adoption — what's working, what's failing, what's next
4. Client verticals Josh serves: legal, recruitment, logistics, property, professional services
5. South African or emerging market angles

Return EXACTLY this format — no preamble:

## Key Themes
- [theme — why it matters for Amalfi AI]
(3-6 bullets)

## Business Model Signals
- [pricing, packaging, GTM signal with direct implication]
(2-4 bullets)

## AI Agent & Automation Landscape
- [specific tech, tool, or architectural insight]
(2-4 bullets)

## SMB Adoption Patterns
- [what's working or not for SMBs adopting AI]
(2-3 bullets)

## Client-Relevant Intelligence
- [insight for specific verticals: legal / recruitment / logistics / finance / property]
(2-4 bullets)

## Quotable Signal
One sentence — the single most important takeaway from this source.

## Completeness Score
One word only — low, medium, or high — rating how complete and substantive the source content is (high = full transcript/article with rich detail; medium = partial but usable; low = heavily summarised, truncated, or thin)."""

    env = {k: v for k, v in os.environ.items() if k not in ('CLAUDECODE', 'CLAUDE_CODE')}
    with tempfile.NamedTemporaryFile(mode='w', suffix='', delete=False, prefix='/tmp/research-prompt-') as f:
        f.write(prompt)
        pf = f.name

    result = subprocess.run(
        ['claude', '--print', '--model', MODEL],
        stdin=open(pf), capture_output=True, text=True, timeout=120, env=env,
    )
    os.unlink(pf)

    if not result.stdout.strip():
        raise ValueError(f"Empty response from Claude: {result.stderr[:200]}")

    return result.stdout.strip()

# ── Claude: identify implementation gaps ────────────────────────────────────────

def identify_gaps(title, insights):
    """Second pass: compare research vs current system, surface actionable gaps → tasks."""
    current_state = ""
    try:
        with open(f"{WS}/CURRENT_STATE.md", 'r') as f:
            current_state = f.read()[:6000]
    except Exception:
        pass

    existing_intel = ""
    try:
        with open(INTEL_FILE, 'r') as f:
            existing_intel = f.read()[:3000]
    except Exception:
        pass

    prompt = f"""You are an autonomous improvement agent for Amalfi AI's AI tech stack.

You have just processed new research and extracted these insights:

SOURCE: {title}

INSIGHTS:
{insights}

CURRENT SYSTEM (what we already have built):
{current_state}

EXISTING ACCUMULATED INTEL (what we've already learned and potentially acted on):
{existing_intel}

Based on this research, identify 2-4 SPECIFIC, IMPLEMENTABLE improvements to our actual codebase.

Good tasks look like:
- "Update sophia-cron.md to add urgency framing in month-3 retention emails — research shows AI CSMs that frame value in loss-aversion terms get 40% fewer churns"
- "Add reply sentiment classifier to alex-reply-detection.sh — research shows qualifying reply intent (positive/unsubscribe/info-request) enables 3x better follow-up prioritisation"
- "Add AI trends section to morning-brief.sh — research shows top AI agency founders do 30-min daily AI news consumption; wire this into Josh's morning brief"

Bad tasks: vague ideas, things already built, non-code tasks, "consider doing X"

Return ONLY a JSON array (no markdown, no explanation):
[
  {{
    "title": "Action title max 60 chars",
    "description": "Specific implementation instructions — which file, what to change, paste-ready guidance. Reference the research insight that motivates this.",
    "priority": "high|medium|low",
    "files": ["scripts/file.sh", "prompts/file.md"]
  }}
]

If there are genuinely no worthwhile implementation gaps from this research, return: []"""

    env = {k: v for k, v in os.environ.items() if k not in ('CLAUDECODE', 'CLAUDE_CODE')}
    with tempfile.NamedTemporaryFile(mode='w', suffix='', delete=False, prefix='/tmp/gaps-prompt-') as f:
        f.write(prompt)
        pf = f.name

    result = subprocess.run(
        ['claude', '--print', '--model', MODEL],
        stdin=open(pf), capture_output=True, text=True, timeout=60, env=env,
    )
    os.unlink(pf)

    raw = result.stdout.strip()
    if not raw:
        return []

    # Strip markdown fences if Claude added them
    raw = re.sub(r'^```json?\s*', '', raw, flags=re.MULTILINE)
    raw = re.sub(r'\s*```$', '', raw, flags=re.MULTILINE)
    raw = raw.strip()

    try:
        gaps = json.loads(raw)
        if isinstance(gaps, list):
            return gaps
    except json.JSONDecodeError as e:
        print(f"  [!] Gap JSON parse failed: {e} | raw: {raw[:300]}")

    return []

def create_gap_tasks(title, gaps):
    """Insert each gap as a task with tags=['research-implement']."""
    if not gaps:
        return 0

    created = 0
    for gap in gaps:
        try:
            files_str = ', '.join(gap.get('files', []))
            desc = gap.get('description', '')
            if files_str:
                desc += f"\n\nFiles: {files_str}"
            desc += f"\n\nSource: {title}"

            # Map priority to valid task values: normal / high / urgent
            raw_priority = gap.get('priority', 'normal')
            priority = {'low': 'normal', 'medium': 'normal', 'high': 'high', 'urgent': 'urgent'}.get(raw_priority, 'normal')

            body = {
                "title":       gap.get('title', 'Research gap')[:120],
                "description": desc,
                "assigned_to": "Claude",
                "created_by":  "research-digest",
                "priority":    priority,
                "status":      "todo",
                "tags":        ["research-implement", "auto"],
            }
            supa_post("tasks", body)
            created += 1
            print(f"  → Task created: {gap.get('title')}")
        except Exception as e:
            print(f"  [!] Task create failed: {e}")

    return created

# ── Update research-intel.md ─────────────────────────────────────────────────────

def update_intel_file(title, insights, date_str):
    try:
        with open(INTEL_FILE, 'r') as f:
            current = f.read()
    except FileNotFoundError:
        current = "# Strategic Research Intelligence\n\n"

    source_block = f"\n### From: {title} ({date_str})\n{insights}\n"

    sources_match = re.search(r'\*Sources processed: (\d+)\*', current)
    old_count = int(sources_match.group(1)) if sources_match else 0
    new_count = old_count + 1

    new_content = re.sub(r'\*Sources processed: \d+\*', f'*Sources processed: {new_count}*', current)
    new_content = re.sub(
        r'\*Auto-maintained.*?\*',
        f'*Auto-maintained by research-digest agent. Last updated: {date_str}*',
        new_content,
    )
    new_content = re.sub(r'\*Will populate as transcripts are processed\.\*\n', '', new_content)

    if '---\n\n*Sources processed:' in new_content:
        new_content = new_content.replace(
            '---\n\n*Sources processed:',
            source_block + '\n---\n\n*Sources processed:',
        )
    else:
        new_content = new_content.rstrip() + '\n' + source_block + f'\n---\n\n*Sources processed: {new_count}*\n'

    with open(INTEL_FILE, 'w') as f:
        f.write(new_content)

    return new_count

def sync_intel_to_supabase():
    try:
        with open(INTEL_FILE, 'r') as f:
            content = f.read()

        existing = supa_get("system_config?key=eq.research_intel&select=id")
        if existing:
            supa_patch("system_config?key=eq.research_intel", {
                "value": content,
                "updated_at": now_iso(),
            })
        else:
            supa_post("system_config", {
                "key": "research_intel",
                "value": content,
                "updated_at": now_iso(),
            })
    except Exception as e:
        print(f"  [!] Supabase sync failed: {e}")

# ── Process a single source ──────────────────────────────────────────────────────

def process_source(title, content, date_str):
    """Full pipeline for one source: insights + gaps + intel update."""
    # If content looks like a URL, fetch it
    stripped = content.strip()
    if stripped.startswith('http://') or stripped.startswith('https://'):
        print(f"  Fetching URL: {stripped[:80]}...")
        content = fetch_url(stripped)
        print(f"  Fetched {len(content)} chars")

    if len(content) < 100:
        raise ValueError("Content too short (< 100 chars) — skipping")

    # ── Pre-LLM quality gate ──────────────────────────────────────────────
    rejected, reject_reason = quality_gate(content)
    if rejected:
        log_rejection(title, content, reject_reason, date_str)
        raise SourceRejected(reject_reason)
    # ─────────────────────────────────────────────────────────────────────

    # Completeness pre-check
    completeness = check_completeness(content)
    if completeness['truncated']:
        reasons_str = '; '.join(completeness['reasons'])
        print(f"  ⚠ Completeness: {completeness['score']} ({reasons_str})")
        tg(
            f"⚠️ <b>Research source appears truncated</b>\n\n"
            f"<b>{title}</b> — re-submit full transcript for complete extraction.\n\n"
            f"<i>Reasons: {reasons_str}</i>"
        )
    else:
        print(f"  Completeness: {completeness['score']} ({completeness['word_count']} words)")

    # Pass 1: extract intelligence
    print(f"  Extracting intel...")
    insights = extract_insights(title, content)

    # Prepend truncation warning to insights if source is incomplete
    if completeness['truncated']:
        insights = TRUNCATION_WARNING + insights

    count = update_intel_file(title, insights, date_str)
    sync_intel_to_supabase()
    print(f"  Intel updated ({count} total sources)")

    # Pass 2: identify implementation gaps
    print(f"  Analysing gaps...")
    gaps = identify_gaps(title, insights)
    tasks_created = create_gap_tasks(title, gaps)
    if tasks_created:
        print(f"  {tasks_created} implementation task(s) queued")
    else:
        print(f"  No new gaps identified")

    return insights, tasks_created, completeness

# ── Collect pending work ─────────────────────────────────────────────────────────

inbox_files = sorted(glob.glob(f"{INBOX}/*.txt") + glob.glob(f"{INBOX}/*.md") + glob.glob(f"{INBOX}/*.url"))

pending_db = []
try:
    pending_db = supa_get("research_sources?status=eq.pending&select=*&order=created_at.asc&limit=20")
except Exception as e:
    print(f"  [!] Could not fetch pending DB sources: {e}")

total_pending = len(inbox_files) + len(pending_db)

if total_pending == 0:
    print("Nothing to process.")
    sys.exit(0)

print(f"Processing {len(inbox_files)} file(s) + {len(pending_db)} queued submission(s)...")

processed = 0
errors = 0
new_tasks = 0
date_str = datetime.datetime.now().strftime('%Y-%m-%d')

# ── Inbox files ──────────────────────────────────────────────────────────────────

for filepath in inbox_files:
    filename = os.path.basename(filepath)
    title = os.path.splitext(filename)[0].replace('-', ' ').replace('_', ' ')
    print(f"\n  Processing file: {filename}")

    try:
        with open(filepath, 'r', encoding='utf-8', errors='ignore') as f:
            content = f.read().strip()

        insights, tasks_n, completeness = process_source(title, content, date_str)
        new_tasks += tasks_n

        # Log to research_sources
        try:
            supa_post("research_sources", {
                "title":       title,
                "raw_content": content[:5000],
                "status":      "done",
                "metadata":    {
                    "filename":         filename,
                    "insights_count":   insights.count('\n- '),
                    "completeness_score": completeness['score'],
                    "word_count":       completeness['word_count'],
                    "truncated":        completeness['truncated'],
                },
            })
        except Exception:
            pass

        # Archive
        archive_name = f"{date_str}_{filename}"
        shutil.move(filepath, f"{ARCHIVE}/{archive_name}")
        print(f"  Archived → {archive_name}")
        processed += 1

    except SourceRejected:
        # Archive rejected file so it isn't reprocessed on next run
        try:
            archive_name = f"{date_str}_rejected_{filename}"
            shutil.move(filepath, f"{ARCHIVE}/{archive_name}")
            print(f"  Archived (rejected) → {archive_name}")
        except Exception:
            pass
    except Exception as e:
        print(f"  [!] Error processing {filename}: {e}", file=sys.stderr)
        errors += 1

# ── DB queue ─────────────────────────────────────────────────────────────────────

for source in pending_db:
    sid     = source['id']
    title   = source.get('title') or 'Untitled'
    content = source.get('raw_content') or ''
    print(f"\n  Processing DB entry: {title}")

    try:
        supa_patch(f"research_sources?id=eq.{sid}", {"status": "processing"})

        insights, tasks_n, completeness = process_source(title, content, date_str)
        new_tasks += tasks_n

        supa_patch(f"research_sources?id=eq.{sid}", {
            "status":   "done",
            "metadata": {
                "insights_count":    insights.count('\n- '),
                "completeness_score": completeness['score'],
                "word_count":        completeness['word_count'],
                "truncated":         completeness['truncated'],
            },
        })
        processed += 1

    except SourceRejected as e:
        print(f"  ⛔ Quality gate rejected DB entry {sid}: {e}")
        try:
            supa_patch(f"research_sources?id=eq.{sid}", {"status": "rejected"})
        except Exception:
            pass
    except Exception as e:
        print(f"  [!] Error processing DB entry {sid}: {e}", file=sys.stderr)
        try:
            supa_patch(f"research_sources?id=eq.{sid}", {"status": "error"})
        except Exception:
            pass
        errors += 1

# ── Telegram summary ─────────────────────────────────────────────────────────────

if processed > 0:
    tasks_line = f"\n{new_tasks} implementation task{'s' if new_tasks != 1 else ''} queued for auto-implement." if new_tasks else ""
    tg(
        f"🧠 <b>Research Digest</b> — {processed} source{'s' if processed > 1 else ''} processed\n"
        f"Strategic intel updated.{tasks_line}\n"
        f"<i>Mission Control → Research to review.</i>"
    )

print(f"\nDone. Processed: {processed} | Errors: {errors} | New tasks: {new_tasks}")
PY
