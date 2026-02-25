#!/usr/bin/env bash
# data-os-sync.sh — Data OS nightly aggregation (single source of truth)
# Runs at 02:00 SAST via LaunchAgent, before morning-brief (07:30 SAST).
# Aggregates: retainer MRR, email pipeline, alex-outreach conversions, repo velocity.
# Writes: data/dashboard.md and data/dashboard.json

set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

WORKSPACE="/Users/henryburton/.openclaw/workspace-anthropic"
ENV_FILE="$WORKSPACE/.env.scheduler"
[[ -f "$ENV_FILE" ]] && source "$ENV_FILE"
source "$WORKSPACE/scripts/lib/task-helpers.sh"

unset CLAUDECODE

SUPABASE_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
KEY="${SUPABASE_SERVICE_ROLE_KEY:-}"
DASHBOARD_MD="$WORKSPACE/data/dashboard.md"
DASHBOARD_JSON="$WORKSPACE/data/dashboard.json"

echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") data-os-sync starting"
TASK_ID=$(task_create "Data OS Sync" "Nightly dashboard aggregation: MRR, pipeline, outreach, delivery" "data-os-sync" "normal")

mkdir -p "$WORKSPACE/data"

export _DS_URL="$SUPABASE_URL" _DS_KEY="$KEY" _DS_WS="$WORKSPACE" \
       _DS_MD="$DASHBOARD_MD" _DS_JSON="$DASHBOARD_JSON"

python3 - <<'PYEOF'
import json, urllib.request, subprocess, datetime, collections, os, sys

URL  = os.environ['_DS_URL']
KEY  = os.environ['_DS_KEY']
WS   = os.environ['_DS_WS']
MD   = os.environ['_DS_MD']
JSN  = os.environ['_DS_JSON']

def supa_get(path):
    req = urllib.request.Request(
        URL + "/rest/v1/" + path,
        headers={"apikey": KEY, "Authorization": "Bearer " + KEY},
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.loads(r.read())
    except Exception as e:
        print(f"  supa_get error ({path}): {e}", file=sys.stderr)
        return []

now_utc  = datetime.datetime.now(datetime.timezone.utc)
SAST     = datetime.timezone(datetime.timedelta(hours=2))
now_sast = now_utc.astimezone(SAST)

curr_month = now_sast.strftime('%Y-%m')
seven_ago  = (now_utc - datetime.timedelta(days=7)).strftime('%Y-%m-%dT%H:%M:%SZ')
thirty_ago = (now_utc - datetime.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ')

# ── 1. RETAINER / MRR ────────────────────────────────────────────────────────
print("  [1] Fetching retainer data...")
active_clients = supa_get("clients?status=eq.active&select=id,name,slug")
income_entries = supa_get(f"income_entries?month=eq.{curr_month}&select=client,amount,status")

paid_amounts  = {e['client']: float(e.get('amount') or 0)
                 for e in income_entries if e.get('status') in ('paid', 'invoiced')}
paid_names    = list(paid_amounts.keys())
missing_names = [c['name'] for c in active_clients if c['name'] not in paid_names]
mrr           = sum(paid_amounts.values())
active_count  = len(active_clients)
paid_count    = len([c for c in active_clients if c['name'] in paid_names])

retainer = {
    "mrr":             mrr,
    "active_clients":  active_count,
    "paid_this_month": paid_count,
    "missing_count":   len(missing_names),
    "missing":         missing_names,
    "month":           curr_month,
}
print(f"     MRR=R{int(mrr):,}, {active_count} active, {paid_count} paid, {len(missing_names)} missing")

# ── 2. EMAIL PIPELINE ────────────────────────────────────────────────────────
print("  [2] Fetching email pipeline stats...")
email_7d  = supa_get("email_queue?select=status&created_at=gte." + seven_ago)
email_30d = supa_get("email_queue?select=status&created_at=gte." + thirty_ago)
ec7  = collections.Counter(r.get('status', '') for r in email_7d)
ec30 = collections.Counter(r.get('status', '') for r in email_30d)

pipeline = {
    "last_7d": {
        "sent":    ec7.get('sent', 0),
        "rejected": ec7.get('rejected', 0),
        "awaiting": ec7.get('awaiting_approval', 0),
    },
    "last_30d": {
        "sent":    ec30.get('sent', 0),
        "rejected": ec30.get('rejected', 0),
        "awaiting": ec30.get('awaiting_approval', 0),
    },
}
print(f"     7d: {ec7.get('sent',0)} sent, {ec7.get('awaiting_approval',0)} awaiting")

# ── 3. ALEX OUTREACH CONVERSION ──────────────────────────────────────────────
print("  [3] Fetching outreach conversion data...")
lead_rows = supa_get("leads?select=status&limit=2000")
lc        = collections.Counter(r.get('status', '') for r in lead_rows)
total_leads  = len(lead_rows)
replied      = lc.get('replied', 0)
meeting      = lc.get('meeting_booked', 0) + lc.get('meeting', 0)
outreached   = sum(lc.get(s, 0) for s in ('contacted', 'sequence_complete', 'replied', 'meeting_booked', 'meeting'))
reply_rate   = round(replied / outreached * 100, 1) if outreached > 0 else 0.0
meeting_rate = round(meeting / outreached * 100, 1) if outreached > 0 else 0.0

outreach = {
    "total_leads":       total_leads,
    "outreached":        outreached,
    "replied":           replied,
    "meetings":          meeting,
    "reply_rate_pct":    reply_rate,
    "meeting_rate_pct":  meeting_rate,
}
print(f"     {total_leads} leads, {outreached} contacted, {replied} replied ({reply_rate}%), {meeting} meetings ({meeting_rate}%)")

# ── 4. REPO COMMIT VELOCITY ──────────────────────────────────────────────────
print("  [4] Calculating repo commit velocity...")
repos = [
    ("qms-guard",              "Ascend LC",           "ascend_lc"),
    ("favorite-flow-9637aff2", "Favorite Logistics",  "favorite_logistics"),
]
commit_velocity = {}
for (d, name, slug) in repos:
    path   = WS + "/clients/" + d
    counts = {}
    for period, since in [("24h", "24 hours ago"), ("7d", "7 days ago"), ("30d", "30 days ago")]:
        try:
            r = subprocess.run(
                ["git", "-C", path, "log", "--oneline", f"--since={since}"],
                capture_output=True, text=True, timeout=10,
            )
            counts[period] = len([l for l in r.stdout.strip().split("\n") if l.strip()])
        except Exception:
            counts[period] = 0
    commit_velocity[slug] = {"name": name, **counts}
    print(f"     {name}: {counts['24h']}(24h) / {counts['7d']}(7d) / {counts['30d']}(30d)")

# ── 5. DELIVERY HEALTH SCORE ─────────────────────────────────────────────────
total_commits_7d = sum(v["7d"] for v in commit_velocity.values())
avg_commits      = round(total_commits_7d / len(repos), 1)
health_status    = "green" if avg_commits >= 3 else ("amber" if avg_commits >= 1 else "red")

delivery = {
    "repos":                      commit_velocity,
    "total_commits_7d":           total_commits_7d,
    "avg_commits_per_client_7d":  avg_commits,
    "health_status":              health_status,
}
print(f"     Delivery: {health_status.upper()} (avg {avg_commits} commits/client/7d)")

# ── Assemble snapshot ────────────────────────────────────────────────────────
snapshot = {
    "generated_at": now_utc.isoformat(),
    "retainer":     retainer,
    "pipeline":     pipeline,
    "outreach":     outreach,
    "delivery":     delivery,
}

# Write JSON
with open(JSN, "w") as f:
    json.dump(snapshot, f, indent=2)
print(f"  ✅ JSON written to {JSN}")

# Write Markdown
def h(n, t):
    return "#" * n + " " + t

lines = [
    h(1, "Amalfi AI — Data OS Dashboard"),
    f"_Generated: {now_sast.strftime('%Y-%m-%d %H:%M')} SAST_",
    "",
    h(2, "MRR & Retainer"),
    f"- **MRR invoiced/paid ({curr_month}):** R{int(mrr):,}",
    f"- **Active clients:** {active_count}",
    f"- **Paid / invoiced:** {paid_count}/{active_count}",
    f"- **Missing payment:** {', '.join(missing_names) if missing_names else 'none'}",
    "",
    h(2, "Email Pipeline"),
    f"- **Last 7d:** {pipeline['last_7d']['sent']} sent, {pipeline['last_7d']['awaiting']} awaiting approval, {pipeline['last_7d']['rejected']} rejected",
    f"- **Last 30d:** {pipeline['last_30d']['sent']} sent, {pipeline['last_30d']['awaiting']} awaiting, {pipeline['last_30d']['rejected']} rejected",
    "",
    h(2, "Alex Outreach"),
    f"- **Total leads:** {total_leads}",
    f"- **Outreached:** {outreached}",
    f"- **Replied:** {replied} ({reply_rate}%)",
    f"- **Meetings booked:** {meeting} ({meeting_rate}%)",
    "",
    h(2, "Delivery Health"),
    f"- **Overall status:** {health_status.upper()}",
    f"- **Total commits (7d):** {total_commits_7d}",
    f"- **Avg commits/client (7d):** {avg_commits}",
    "",
    h(3, "Per-client commit velocity"),
]
for slug, v in commit_velocity.items():
    lines.append(f"- **{v['name']}:** {v['24h']} (24h) / {v['7d']} (7d) / {v['30d']} (30d)")

with open(MD, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"  ✅ Markdown written to {MD}")
PYEOF

task_complete "$TASK_ID" "Dashboard written: data/dashboard.json and data/dashboard.md"
echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") data-os-sync complete"
