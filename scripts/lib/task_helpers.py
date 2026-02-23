"""
scripts/lib/task_helpers.py
Python task CRUD helpers for Supabase — mirrors task-helpers.sh.

Usage in any agent script:
    import sys
    sys.path.insert(0, '/Users/henryburton/.openclaw/workspace-anthropic/scripts/lib')
    from task_helpers import task_create, task_update, task_complete, task_fail

All functions are no-ops if SUPABASE_SERVICE_ROLE_KEY is not set, so safe to call
unconditionally in every script.
"""

import json
import os
import datetime
import urllib.request
import urllib.parse

_SUPABASE_URL = "https://afmpbtynucpbglwtbfuz.supabase.co"


def _key():
    return os.environ.get("SUPABASE_SERVICE_ROLE_KEY") or os.environ.get("SUPABASE_KEY") or ""


def _headers():
    k = _key()
    return {
        "apikey": k,
        "Authorization": f"Bearer {k}",
        "Content-Type": "application/json",
    }


def _get(path):
    req = urllib.request.Request(
        f"{_SUPABASE_URL}/rest/v1/{path}",
        headers=_headers(),
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def _post(path, body):
    data = json.dumps(body).encode()
    h = {**_headers(), "Prefer": "return=representation"}
    req = urllib.request.Request(
        f"{_SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers=h,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())


def _patch(path, body):
    data = json.dumps(body).encode()
    h = {**_headers(), "Prefer": "return=minimal"}
    req = urllib.request.Request(
        f"{_SUPABASE_URL}/rest/v1/{path}",
        data=data,
        headers=h,
        method="PATCH",
    )
    with urllib.request.urlopen(req, timeout=10)as r:
        return r.read()


def task_create(title, description="", agent="System", priority="normal"):
    """
    Create a task in Supabase and return its UUID string.
    Deduplicates: if an in_progress task with the same title+agent exists, returns its ID.
    Returns "" on failure or if key is not set.
    """
    if not _key():
        return ""

    try:
        encoded_title = urllib.parse.quote(title)
        encoded_agent = urllib.parse.quote(agent)
        existing = _get(
            f"tasks?title=eq.{encoded_title}&assigned_to=eq.{encoded_agent}"
            f"&status=eq.in_progress&select=id&limit=1"
        )
        if existing:
            return existing[0]["id"]

        rows = _post("tasks", {
            "title":       title[:120],
            "description": description,
            "assigned_to": agent,
            "created_by":  agent,
            "priority":    priority,
            "status":      "in_progress",
            "tags":        ["agent-run"],
        })
        return rows[0]["id"] if rows else ""
    except Exception:
        return ""


def task_update(task_id, description):
    """Update a task's description (progress note). No-op if task_id is empty."""
    if not _key() or not task_id:
        return
    try:
        _patch(f"tasks?id=eq.{task_id}", {"description": description})
    except Exception:
        pass


def task_complete(task_id, note=""):
    """Mark a task as done with optional completion note."""
    if not _key() or not task_id:
        return
    body = {
        "status": "done",
        "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    if note:
        body["description"] = note
    try:
        _patch(f"tasks?id=eq.{task_id}", body)
    except Exception:
        pass


def task_fail(task_id, error="Unknown error"):
    """Mark a task as failed."""
    if not _key() or not task_id:
        return
    try:
        _patch(f"tasks?id=eq.{task_id}", {
            "status": "done",
            "description": f"FAILED: {error}",
        })
    except Exception:
        pass
