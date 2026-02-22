#!/usr/bin/env python3

"""Roll up activity-log.jsonl into daily active minutes.

Heuristic (default): active if idle_seconds < 300 OR repo dirty_count > 0.
Sessionisation: we just count active ticks; each tick ~= 5 minutes.

Outputs:
- prints JSON summary to stdout
- (optional) writes to Supabase work_daily_rollups if env SUPABASE_URL + SUPABASE_KEY present
"""

import json
import os
import sys
from datetime import datetime, timezone, timedelta
from collections import defaultdict

LOG_FILE = os.environ.get(
    "ACTIVITY_LOG_FILE",
    "/Users/henryburton/.openclaw/workspace-anthropic/memory/activity-log.jsonl",
)

IDLE_THRESHOLD_SECONDS = float(os.environ.get("IDLE_THRESHOLD_SECONDS", "300"))
TICK_MINUTES = int(os.environ.get("TICK_MINUTES", "5"))

# SAST
SAST = timezone(timedelta(hours=2))


def classify_tick(obj):
    idle = obj.get("idle_seconds")
    repos = obj.get("repos") or []

    dirty_any = any((r.get("dirty_count") or 0) > 0 for r in repos if not r.get("missing"))

    active = False
    if isinstance(idle, (int, float)) and idle < IDLE_THRESHOLD_SECONDS:
        active = True
    if dirty_any:
        active = True

    # Category heuristic (very rough)
    category = "ops_monitoring"
    if dirty_any:
        category = "development"

    return active, category


def main():
    by_day_active = defaultdict(int)
    by_day_cat = defaultdict(lambda: defaultdict(int))

    try:
        with open(LOG_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                obj = json.loads(line)
                ts = obj.get("ts")
                if not ts:
                    continue
                dt = datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone(SAST)
                day = dt.date().isoformat()

                active, cat = classify_tick(obj)
                if active:
                    by_day_active[day] += TICK_MINUTES
                    by_day_cat[day][cat] += TICK_MINUTES

    except FileNotFoundError:
        print(json.dumps({"ok": False, "error": "missing_log_file", "path": LOG_FILE}))
        return

    out = {"ok": True, "idle_threshold_seconds": IDLE_THRESHOLD_SECONDS, "tick_minutes": TICK_MINUTES, "days": {}}
    for day in sorted(by_day_active.keys()):
        out["days"][day] = {
            "active_minutes": by_day_active[day],
            "by_category_minutes": dict(by_day_cat[day]),
        }

    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
