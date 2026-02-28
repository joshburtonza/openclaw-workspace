#!/usr/bin/env bash
# generate-broll-specs.sh — Use Claude to analyse transcript and generate B-roll specs
# Usage: generate-broll-specs.sh <words_json> <title> <output_broll_specs_json>
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WORDS_JSON="$1"
TITLE="$2"
BROLL_JSON="$3"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WORKSPACE/.env.scheduler" 2>/dev/null || true

echo "[broll-specs] Analysing transcript for B-roll opportunities..."

# Load context about Josh's stack so Claude generates accurate, specific B-roll
CONTEXT_SUMMARY="
You are generating B-roll specs for Josh Burton's talking head videos about Amalfi AI.
Context about Josh's tech stack:
- AOS (Amalfi OS): AI automation system with 19+ LaunchAgents — morning briefs, task workers, meeting intelligence, Sophia CSM, Alex outreach
- Telegram bot (@JoshAmalfiBot): gets notifications for task completions, reminders, meeting debriefs, Sophia email drafts
- Supabase: tasks table (todo/in_progress/done), leads, audit_log, email_queue
- Mission Control: React dashboard at a Vercel URL — pages: Dashboard, Agents, Tasks, Content, Alex CRM, Research, Finances
- Clients: Ascend LC (QMS platform, ISO 9001), Race Technik (auto service booking), Favlog (supply chain ERP)
- Stack: Claude Sonnet/Opus/Haiku, GPT-5.2, o3, GPT-4o, Deepgram nova-2, OpenAI TTS nova
- Race Technik Mac Mini: runs its own AI instance (Maya), @RaceTechnikAiBot
"

export _BROLL_WORDS_JSON="$WORDS_JSON"
export _BROLL_TITLE="$TITLE"
export _BROLL_OUTPUT="$BROLL_JSON"
export _BROLL_CONTEXT="$CONTEXT_SUMMARY"
export _BROLL_WORKSPACE="$WORKSPACE"

python3 <<'PY'
import os, json, subprocess, sys, tempfile

words_file  = os.environ['_BROLL_WORDS_JSON']
title       = os.environ['_BROLL_TITLE']
output_file = os.environ['_BROLL_OUTPUT']
context     = os.environ['_BROLL_CONTEXT']
ws          = os.environ['_BROLL_WORKSPACE']

with open(words_file, 'r') as f:
    words = json.load(f)

# Build readable transcript with timestamps
transcript_lines = []
current_line = []
current_start = words[0]['start'] if words else 0

for w in words:
    current_line.append(w['word'])
    if len(current_line) >= 8:
        line_start = current_start
        line_end   = w['end']
        transcript_lines.append(f"[{line_start:.1f}s-{line_end:.1f}s] {' '.join(current_line)}")
        current_line = []
        current_start = w['end']

if current_line:
    transcript_lines.append(f"[{current_start:.1f}s-{words[-1]['end']:.1f}s] {' '.join(current_line)}")

transcript_text = '\n'.join(transcript_lines)
total_duration  = words[-1]['end'] if words else 0

PROMPT = f"""{context}

VIDEO TITLE: {title}
TOTAL DURATION: {total_duration:.0f}s

TRANSCRIPT:
{transcript_text}

Analyse this transcript and identify moments that would benefit from B-roll visual aids.
For each moment, generate a B-roll spec in JSON.

ART DIRECTION (apply to all clips):
- Dark backgrounds only (#0a0b14, #1a1f2e, #15202b) — never white
- Font: -apple-system SF Pro. Colors: #4B9EFF blue, #4ade80 green (positive), #f87171 red (problems)
- Spring-based motion entries, never linear. Stagger multiple elements 12-18 frames apart.
- position "right" by default. Use "left" only if Josh is on the right side of frame.

AVAILABLE B-ROLL TYPES:
1. "iphone_telegram" — iPhone 17 showing Telegram chat with specific messages
   Use when: mentioning Telegram notifications, task updates, reminders, messages from AOS
   props: {{ "chat_name": "AOS" | "Josh AmalfiAI" | etc, "messages": [{{ "text": "...", "time": "14:32", "is_outgoing": false }}], "show_notification_popup": true, "notification_text": "short preview" }}

2. "iphone_dashboard" — iPhone 17 showing Mission Control dashboard
   Use when: mentioning the dashboard, agent status, client metrics
   props: {{ "page": "Dashboard" | "Tasks" | "Agents" | "Finances", "metric": "3 tasks done today" }}

3. "terminal" — Dark macOS terminal with animated line-by-line output
   Use when: mentioning scripts running, automation, code, LaunchAgents, AI agents doing work
   props: {{ "title": "bash", "lines": ["[task-worker] Picked up task: Update hero section", "[task-worker] Implementing...", "✅ Done — pushed to GitHub"] }}
   Note: first line is the command, subsequent lines are output. Use ✅/❌/→ prefixes for colour.

4. "chat_bubble" — Floating AI chat bubbles
   Use when: showing AI conversation, AOS responding, agent replies
   props: {{ "messages": [{{ "text": "...", "sender": "AOS", "is_ai": true }}] }}

5. "stat_card" — Glowing metric card
   Use when: mentioning specific numbers, metrics, results, cost savings, time saved
   props: {{ "label": "Tasks completed this week", "value": "23", "delta": "+8 vs last week", "color": "#4ade80" }}
   Colors: #4ade80 (green, positive), #f87171 (red, pain/problem), #4B9EFF (blue, neutral)

6. "lower_third" — Animated name/title overlay at bottom-left
   Use when: Josh introduces himself, cites a source or authority, or labels a specific tool/concept
   props: {{ "name": "Josh Burton", "title": "Founder, Amalfi AI", "color": "#4B9EFF" }}
   Keep clips short (4s). position: "left", scale: 0.8

7. "tweet" — Animated dark-mode tweet card
   Use when: showing a testimonial, social proof, viral moment, or quoting someone on X/Twitter
   props: {{ "display_name": "Name", "username": "handle", "content": "tweet text", "timestamp": "Mar 2025", "likes": "247", "retweets": "38" }}

8. "bar_chart" — Animated bar chart, bars grow up with spring easing
   Use when: comparing data across categories, showing before/after, growth over time, multiple metrics
   props: {{ "title": "Revenue by client", "bars": [{{"label": "Ascend", "value": 12000}}, {{"label": "Race Technik", "value": 8500}}], "color": "#4B9EFF", "unit": "$" }}

9. "blender_3d" — Real 3D Blender render with transparent alpha background (floating in space)
   Use when: you want maximum visual impact for a key moment — title reveal, a major number, a punchy ending
   Sub-types via props.blender_type:
   - "text_3d": 3D extruded text with emission glow + spin/rise/zoom entry animation
     props: {{ "blender_type": "text_3d", "text": "23 TASKS", "subtitle": "completed this week", "color": "#4ade80", "style": "spin" }}
     style options: "spin" (Y-axis rotation in) | "rise" (rise from below) | "zoom" (scale in from large)
   - "particle_burst": 3D number that explodes with particles when revealed
     props: {{ "blender_type": "particle_burst", "value": "£12,400", "label": "REVENUE THIS MONTH", "color": "#4ade80" }}
   Use blender_3d sparingly — once per video max, for the most impactful stat or title moment.
   Clip duration: 5-7s. scale: 0.6-0.8 (these are large, impactful visuals). position: "right" or "left".

RULES:
- Only add B-roll where it genuinely amplifies a concrete claim, process, or number
- Clip duration: minimum 4s, maximum 8s (sweet spot is 5-6s)
- Don't overlap clips (check start/end times)
- Content must match EXACTLY what Josh is saying — be specific, not generic
- Aim for 3-6 clips per video (quality over quantity)
- Leave at least 2s gap between clips
- Don't start B-roll in first 3s or last 5s of video
- lower_third: great for the opening 10s when Josh first appears, or when he introduces a tool/person
- terminal: show real AOS agent names like [task-worker], [alex-outreach], [sophia-csm], [meet-notes-poller]
- stat_card: use red (#f87171) for pain points, green (#4ade80) for results, blue for neutral info

Respond with ONLY a valid JSON object:
{{
  "clips": [
    {{
      "type": "lower_third",
      "start": 1.5,
      "end": 5.5,
      "position": "left",
      "scale": 0.8,
      "props": {{ "name": "Josh Burton", "title": "Founder, Amalfi AI", "color": "#4B9EFF" }}
    }},
    {{
      "type": "terminal",
      "start": 22.0,
      "end": 28.0,
      "position": "right",
      "scale": 0.55,
      "props": {{ "title": "bash", "lines": ["[task-worker] Picking up task...", "→ Implementing feature", "✅ Committed and pushed"] }}
    }}
  ]
}}

If no B-roll would help, respond with: {{"clips": []}}
"""

# Write prompt to temp file (claude --print reads from stdin)
tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.txt', prefix='/tmp/broll-prompt-', delete=False)
tmp.write(PROMPT)
tmp.close()

print(f'[broll-specs] Sending transcript ({len(words)} words, {total_duration:.0f}s) to Claude...')

env = os.environ.copy()
env.pop('CLAUDECODE', None)

result = subprocess.run(
    ['claude', '--print', '--model', 'claude-sonnet-4-6'],
    stdin=open(tmp.name),
    capture_output=True, text=True, env=env, timeout=60
)
os.unlink(tmp.name)

if result.returncode != 0:
    print(f'[broll-specs] Claude failed: {result.stderr[:500]}', file=sys.stderr)
    # Emit empty specs so pipeline continues
    with open(output_file, 'w') as f:
        json.dump({"clips": []}, f)
    sys.exit(0)

raw = result.stdout.strip()

# Extract JSON from Claude's response
import re
json_match = re.search(r'\{[\s\S]*\}', raw)
if not json_match:
    print(f'[broll-specs] No JSON in Claude response, skipping B-roll', file=sys.stderr)
    with open(output_file, 'w') as f:
        json.dump({"clips": []}, f)
    sys.exit(0)

try:
    specs = json.loads(json_match.group(0))
    # Validate structure
    clips = specs.get('clips', [])
    print(f'[broll-specs] {len(clips)} B-roll clips planned:')
    for c in clips:
        print(f'  [{c["start"]:.1f}s-{c["end"]:.1f}s] {c["type"]} — {c.get("props", {}).get("chat_name", c.get("props", {}).get("label", c.get("props", {}).get("title", "")))}')
    with open(output_file, 'w') as f:
        json.dump(specs, f, indent=2)
except json.JSONDecodeError as e:
    print(f'[broll-specs] JSON parse error: {e}', file=sys.stderr)
    with open(output_file, 'w') as f:
        json.dump({"clips": []}, f)
PY

echo "[broll-specs] Done → $BROLL_JSON"
