#!/usr/bin/env bash
# content-news-fetcher.sh
# Fetches trending AI, startup, and business headlines for content inspiration.
# Runs daily before content-creator (04:45 SAST).
# Output: $WS/tmp/content-news-today.md
# Uses: curl + RSS/JSON feeds (no API key needed)

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

WS="${AOS_ROOT:-/Users/henryburton/.openclaw/workspace-anthropic}"
OUTPUT="$WS/tmp/content-news-today.md"
mkdir -p "$WS/tmp"

log() { echo "[$(date '+%H:%M:%S')] [news-fetcher] $*"; }

fetch_rss_titles() {
  local url="$1"
  local label="$2"
  local count="${3:-5}"
  local titles
  titles=$(curl -sL --max-time 15 "$url" 2>/dev/null | \
    python3 -c "
import sys, re
content = sys.stdin.read()
titles = re.findall(r'<title[^>]*>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</title>', content)
# Skip feed-level title (first one)
for t in titles[1:$((count+1))]:
    t = t.strip()
    if t and len(t) > 10:
        print(f'- {t}')
" 2>/dev/null)
  if [[ -n "$titles" ]]; then
    echo "### $label"
    echo "$titles"
    echo ""
  fi
}

fetch_hn_top() {
  local count="${1:-5}"
  # Hacker News top stories via Algolia API (no key needed)
  local ids
  ids=$(curl -sL --max-time 15 "https://hacker-news.firebaseio.com/v0/topstories.json" 2>/dev/null | \
    python3 -c "import json,sys; ids=json.load(sys.stdin)[:$count]; print(' '.join(str(i) for i in ids))" 2>/dev/null)
  if [[ -n "$ids" ]]; then
    echo "### Hacker News (top stories)"
    for id in $ids; do
      local title
      title=$(curl -sL --max-time 10 "https://hacker-news.firebaseio.com/v0/item/${id}.json" 2>/dev/null | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('title',''))" 2>/dev/null)
      [[ -n "$title" ]] && echo "- $title"
    done
    echo ""
  fi
}

log "Fetching news..."

{
  echo "AI, tech, startup, and business news — $(date '+%d %B %Y')"
  echo ""

  # AI / ML specific
  fetch_rss_titles "https://techcrunch.com/category/artificial-intelligence/feed/" "TechCrunch AI" 5

  # Startup / Business
  fetch_rss_titles "https://feeds.feedburner.com/venturebeat/SZYF" "VentureBeat" 5

  # Hacker News top (tech/startup community pulse)
  fetch_hn_top 5

  # The Verge AI
  fetch_rss_titles "https://www.theverge.com/rss/ai-artificial-intelligence/index.xml" "The Verge AI" 5

  # South Africa Business (for local relevance)
  fetch_rss_titles "https://www.news24.com/fin24/rss" "Fin24 SA Business" 3

  echo "---"
  echo "Use these headlines as jumping-off points. React to them, disagree with them, connect them to what you are actually building. Do not just summarise — add your take."

} > "$OUTPUT" 2>/dev/null

LINES=$(wc -l < "$OUTPUT" 2>/dev/null || echo "0")
log "Done — $LINES lines written to $OUTPUT"
