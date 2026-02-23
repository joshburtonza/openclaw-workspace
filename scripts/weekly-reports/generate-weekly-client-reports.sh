#!/usr/bin/env bash
set -euo pipefail

# Weekly client reports → Gamma PDF (Chimney Smoke) → drafts in Supabase email_queue
# MVP: stores PDF paths + Gamma URLs in email_queue.analysis (attachments column not yet deployed)

ROOT="/Users/henryburton/.openclaw/workspace-anthropic"
SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
SUPABASE_ANON_KEY="eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFmbXBidHludWNwYmdsd3RiZnV6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzE0MDk3ODksImV4cCI6MjA4Njk4NTc4OX0.Xc8wFxQOtv90G1MO4iLQIQJPCx1Z598o1GloU0bAlOQ"

THEME_ID="chimney-smoke"
NUM_CARDS="18"

# load Gamma key
set -a
source "/Users/henryburton/.openclaw/secrets/gamma.env"
set +a

if [[ -z "${GAMMA_API_KEY:-}" ]]; then
  echo "Missing GAMMA_API_KEY (expected in ~/.openclaw/secrets/gamma.env)" >&2
  exit 2
fi

WEEK_ENDING="$(date -I)"
OUT_DIR="$HOME/.openclaw/reports/weekly/$WEEK_ENDING"
mkdir -p "$OUT_DIR"

summarize_repo() {
  local repo_dir="$1"
  local since="${2:-7 days ago}"
  if [[ ! -d "$repo_dir/.git" ]]; then
    echo "(repo missing: $repo_dir)"
    return 0
  fi
  (cd "$repo_dir" && git fetch --all --prune >/dev/null 2>&1 || true)
  (cd "$repo_dir" && git log --since="$since" --pretty=format:'- %ad %s' --date=short --no-merges | head -n 40)
}

make_md() {
  local title="$1"
  local shipped="$2"
  local next="$3"
  local risks="$4"
  local decisions="$5"

  cat <<EOF
# $title

## What we shipped last week
$shipped

## What we are doing next week
$next

## Risks or blockers
$risks

## Decisions needed
$decisions
EOF
}

gamma_pdf() {
  local md_file="$1"
  local pdf_out="$2"
  local title="$3"

  # returns JSON on stdout
  node "$ROOT/scripts/gamma/gamma-generate-pdf.mjs" \
    --title "$title" \
    --themeId "$THEME_ID" \
    --numCards "$NUM_CARDS" \
    --in "$md_file" \
    --out "$pdf_out"
}

insert_draft() {
  local client_key="$1"     # ascend_lc | race_technik | favorite_logistics
  local to_email="$2"
  local subject="$3"
  local body="$4"
  local analysis_json="$5"

  curl -sS -X POST "$SUPABASE_URL/rest/v1/email_queue" \
    -H "apikey: $SUPABASE_ANON_KEY" \
    -H "Authorization: Bearer $SUPABASE_ANON_KEY" \
    -H 'Content-Type: application/json' \
    -H 'Prefer: return=representation' \
    -d "{\"from_email\":\"sophia@amalfiai.com\",\"to_email\":\"$to_email\",\"subject\":\"$subject\",\"body\":\"$body\",\"client\":\"$client_key\",\"status\":\"awaiting_approval\",\"requires_approval\":true,\"analysis\":$analysis_json}"
}

make_report_for_client() {
  local client_key="$1"
  local client_name="$2"
  local repo_dir="$3"
  local to_email="$4"
  local relationship_type="${5:-retainer}"  # retainer | bd_partner | prospect

  local commits
  commits="$(summarize_repo "$repo_dir")"
  [[ -z "$commits" ]] && commits="- No code changes committed this week"

  local shipped next risks decisions title md_file pdf_file

  title="$client_name Weekly Progress Report"
  shipped="$commits"

  if [[ "$relationship_type" == "bd_partner" ]]; then
    # Collaborative/peer language for BD partners — we're building together, not vendor→client
    next="- Continue building out our shared pipeline and address any blockers together\n- Align on priorities for the coming week"
    risks="- Any dependencies or open items we need to resolve together\n- If anything in our shared workflow needs clarification, let us surface it now"
    decisions="- Confirm our joint priorities and any urgent items to co-ordinate on first"
  else
    next="- Continue feature delivery and bug fixes based on feedback\n- Confirm priorities for this week"
    risks="- Waiting on any feedback or clarification needed from your team\n- If anything is unclear in the workflow, we want to simplify it"
    decisions="- Confirm next priorities and any urgent items to address first"
  fi

  md_file="$OUT_DIR/${client_key}.md"
  pdf_file="$OUT_DIR/${client_key}.pdf"

  make_md "$title" "$shipped" "$next" "$risks" "$decisions" > "$md_file"

  echo "Generating Gamma PDF for $client_key..." >&2
  local result_json
  result_json="$(gamma_pdf "$md_file" "$pdf_file" "$title")"

  local gamma_url export_url generation_id
  gamma_url="$(echo "$result_json" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("gammaUrl",""))')"
  export_url="$(echo "$result_json" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("exportUrl",""))')"
  generation_id="$(echo "$result_json" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("generationId",""))')"

  local subject body analysis
  subject="$client_name weekly progress report (week ending $WEEK_ENDING)"
  if [[ "$relationship_type" == "bd_partner" ]]; then
    body="Hi — here is our joint progress update for the week ending $WEEK_ENDING. The attached report covers what we shipped together and what we are co-ordinating on next.\n\nLet us know if anything needs to move up in our shared pipeline.\n\nRegards\nSophia"
  else
    body="Hi. Please see the attached weekly progress report PDF for $client_name (week ending $WEEK_ENDING).\n\nRegards\nSophia"
  fi

  # Store PDF path + Gamma URLs in analysis until attachments column exists
  analysis="{\"type\":\"weekly_report\",\"week_ending\":\"$WEEK_ENDING\",\"pdf_path\":\"$pdf_file\",\"gamma_url\":\"$gamma_url\",\"export_url\":\"$export_url\",\"generation_id\":\"$generation_id\",\"relationship_type\":\"$relationship_type\"}"

  echo "Creating email_queue draft for $client_key..." >&2
  insert_draft "$client_key" "$to_email" "$subject" "$body" "$analysis" >/dev/null
  echo "Done: $client_key → $pdf_file" >&2
}

# One PDF per client, no bleed
# relationship_type: retainer | bd_partner | prospect (matches data/client-projects.json)
make_report_for_client "ascend_lc"          "Ascend LC (QMS Guard)"        "$ROOT/qms-guard"              "riaan@ascendlc.co.za"        "bd_partner"
make_report_for_client "race_technik"       "Race Technik"                  "$ROOT/chrome-auto-care"       "racetechnik010@gmail.com"    "retainer"
make_report_for_client "favorite_logistics" "Favorite Logistics (FLAIR)"   "$ROOT/favorite-flow-9637aff2" "rapizo92@gmail.com"          "retainer"

echo "All weekly reports generated in: $OUT_DIR" >&2
