#!/usr/bin/env bash
# detect-data-mentions.sh — Use Claude to find data points in transcript
# that warrant a visual animation overlay.
#
# Usage: detect-data-mentions.sh <words.json> <title> <out_mentions.json>

WORDS_JSON="$1"
TITLE="${2:-Video}"
OUT_JSON="${3:-/tmp/data_mentions.json}"

WORKSPACE="$(cd "$(dirname "$0")/../.." && pwd)"
source "$WORKSPACE/.env.scheduler" 2>/dev/null || true

if [ ! -f "$WORDS_JSON" ]; then
  echo "[detect-data] ERROR: words.json not found: $WORDS_JSON"
  echo '{"mentions":[]}' > "$OUT_JSON"
  exit 0
fi

export _DM_WORDS="$WORDS_JSON"
TRANSCRIPT=$(python3 - <<'PY'
import json, os
words = json.load(open(os.environ['_DM_WORDS']))
lines = []
chunk = []
for w in words:
    chunk.append(w)
    if len(chunk) >= 10 or (chunk and w['word'].endswith(('.', '!', '?', ','))):
        t_start = chunk[0]['start']
        t_end   = chunk[-1]['end']
        text    = ' '.join(x['word'] for x in chunk)
        lines.append(f"[{t_start:.1f}s-{t_end:.1f}s] {text}")
        chunk = []
if chunk:
    t_start = chunk[0]['start']
    t_end   = chunk[-1]['end']
    text    = ' '.join(x['word'] for x in chunk)
    lines.append(f"[{t_start:.1f}s-{t_end:.1f}s] {text}")
print('\n'.join(lines))
PY
)

# Write prompt to temp file (claude --print requires file input on this setup)
PROMPT_FILE=$(mktemp /tmp/dm-prompt-XXXXXX)
cat > "$PROMPT_FILE" <<PROMPT
You are a video production AI. Analyze this video transcript and identify every moment where a DATA VISUALIZATION would enhance the viewer's understanding.

VIDEO TITLE: ${TITLE}

TRANSCRIPT WITH TIMESTAMPS:
${TRANSCRIPT}

Find ALL mentions of:
- Percentages / growth rates (e.g. "grew 43%", "up 20%", "down by half")
- Monetary values / currencies (e.g. "$2.3 million", "R5 billion", "200k revenue")
- Comparisons (e.g. "3x more", "doubled", "10 times faster")
- Statistics / counts (e.g. "10,000 users", "50 clients", "3 locations")
- Time-based metrics (e.g. "in 6 months", "year over year", "Q3 results")
- Any number that tells a story the viewer should SEE not just hear

For each mention, return a JSON object. Choose the best animation type:
- "counter"       — single value counting up (good for: money, users, any single big number)
- "growth_arrow"  — percentage with up/down arrow (good for: % growth, % increase/decrease)
- "bar_chart"     — side-by-side bars (good for: comparisons, before/after, multiple values)
- "progress_ring" — donut showing a percentage (good for: 0-100% achievements, market share)
- "comparison"    — two values side by side (good for: before vs after, this year vs last year)
- "timeline"      — horizontal bars over time (good for: milestones, 6-month/12-month progress)

Return ONLY valid JSON. No explanation. Format:
{
  "mentions": [
    {
      "type": "counter",
      "timestamp_start": 4.2,
      "timestamp_end": 7.0,
      "overlay_start": 4.0,
      "overlay_duration": 3.0,
      "position": "lower_right",
      "data": {
        "value": 2300000,
        "display": "$2.3M",
        "label": "Annual Revenue",
        "currency": "USD",
        "trend": "up"
      },
      "context": "exact quote from transcript that triggered this"
    }
  ]
}

For bar_chart, data should be:
  "bars": [{"label": "2023", "value": 2.3}, {"label": "2024", "value": 4.1}]
  "unit": "$M"  "title": "Revenue Growth"

For growth_arrow:
  "value": 43, "unit": "%", "direction": "up", "label": "Revenue Growth", "period": "YoY"

For comparison:
  "before": {"value": 1.2, "label": "Last Year"}, "after": {"value": 2.8, "label": "This Year"}, "unit": "$M"

For progress_ring:
  "value": 78, "label": "Market Share", "unit": "%"

Only include genuinely impactful data moments — quality over quantity. Max 8 per video.
PROMPT

echo "[detect-data] Analyzing transcript for data mentions..."
unset CLAUDECODE
RESULT=$(claude --print < "$PROMPT_FILE" 2>/dev/null)
rm -f "$PROMPT_FILE"
export _DM_RESULT="$RESULT"
export _DM_OUT_JSON="$OUT_JSON"

# Extract JSON from Claude's response
python3 - <<'PY'
import json, re, sys, os

result   = os.environ.get('_DM_RESULT', '')
out_json = os.environ.get('_DM_OUT_JSON', '/tmp/data_mentions.json')

# Try to extract JSON block
patterns = [
    r'\{[\s\S]*"mentions"[\s\S]*\}',
    r'\{[\s\S]*\}',
]
extracted = None
for pat in patterns:
    m = re.search(pat, result, re.DOTALL)
    if m:
        try:
            extracted = json.loads(m.group(0))
            break
        except json.JSONDecodeError:
            continue

if not extracted:
    print("[detect-data] WARNING: Could not parse Claude response, using empty mentions", file=sys.stderr)
    extracted = {"mentions": []}

n = len(extracted.get("mentions", []))
print(f"[detect-data] Found {n} data mention(s)", file=sys.stderr)
for i, m in enumerate(extracted.get("mentions", [])):
    print(f"  {i+1}. [{m.get('type','?')}] @{m.get('overlay_start',0):.1f}s — {m.get('context','')[:60]}", file=sys.stderr)

with open(out_json, "w") as f:
    json.dump(extracted, f, indent=2)

print(f"[detect-data] Saved: {out_json}", file=sys.stderr)
PY

echo "[detect-data] Done: $OUT_JSON"
