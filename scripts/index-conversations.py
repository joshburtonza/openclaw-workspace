#!/usr/bin/env python3
"""
index-conversations.py
Converts Claude Code .jsonl conversation files to searchable markdown,
then adds them as a qmd collection for on-demand querying.

Usage:
  python3 index-conversations.py [--rebuild]
"""

import json
import os
import sys
import subprocess
import hashlib
from datetime import datetime, timezone
from pathlib import Path

PROJECTS_DIR = Path.home() / ".claude/projects/-Users-henryburton"
ARCHIVE_DIR  = PROJECTS_DIR / "archive"
OUTPUT_DIR   = Path.home() / ".claude/conversations-md"
COLLECTION   = "claude-conversations"

OUTPUT_DIR.mkdir(exist_ok=True)


def extract_conversation(jsonl_path: Path) -> dict:
    """Extract human/assistant text turns from a JSONL conversation file."""
    turns = []
    session_id = jsonl_path.stem
    cwd = ""
    ts_first = None

    try:
        with open(jsonl_path, encoding="utf-8", errors="ignore") as f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    d = json.loads(raw)
                except json.JSONDecodeError:
                    continue

                t = d.get("type")
                if t not in ("user", "assistant"):
                    continue

                msg = d.get("message", {})
                if not isinstance(msg, dict):
                    continue

                role = msg.get("role", t)
                content = msg.get("content", [])

                # Extract text from content blocks
                text = ""
                if isinstance(content, str):
                    text = content
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict):
                            if block.get("type") == "text":
                                text += block.get("text", "")
                        elif isinstance(block, str):
                            text += block

                # Clean up system injection tags
                text = text.strip()
                if not text or text.startswith("<system-reminder>") or text.startswith("<local-command"):
                    # Try to get the actual user text after tags
                    import re
                    clean = re.sub(r"<[^>]+>.*?</[^>]+>", "", text, flags=re.DOTALL).strip()
                    if not clean:
                        continue
                    text = clean

                # Skip empty or very short noise
                if len(text) < 10:
                    continue

                # Get timestamp
                ts_raw = d.get("timestamp")
                if ts_raw and not ts_first:
                    try:
                        ts_first = datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
                    except Exception:
                        pass

                if not cwd:
                    cwd = d.get("cwd", "")

                turns.append({"role": role, "text": text[:2000]})  # cap per turn

    except Exception as e:
        print(f"  Error reading {jsonl_path.name}: {e}", file=sys.stderr)

    return {
        "session_id": session_id,
        "turns": turns,
        "cwd": cwd,
        "ts": ts_first,
    }


def to_markdown(conv: dict) -> str:
    """Convert extracted conversation to markdown for indexing."""
    lines = []

    date_str = conv["ts"].strftime("%Y-%m-%d %H:%M SAST") if conv["ts"] else "Unknown date"
    lines.append(f"# Conversation {conv['session_id'][:8]}")
    lines.append(f"**Date:** {date_str}")
    if conv["cwd"]:
        lines.append(f"**Working dir:** `{conv['cwd']}`")
    lines.append("")

    for turn in conv["turns"]:
        prefix = "**Josh:**" if turn["role"] == "user" else "**Claude:**"
        # Truncate very long turns
        text = turn["text"]
        if len(text) > 1500:
            text = text[:1500] + "…"
        lines.append(f"{prefix} {text}")
        lines.append("")

    return "\n".join(lines)


def process_jsonl_files():
    """Find all jsonl files (active + archive) and convert them."""
    jsonl_files = list(PROJECTS_DIR.glob("*.jsonl")) + list(ARCHIVE_DIR.glob("*.jsonl"))
    print(f"Found {len(jsonl_files)} conversation files")

    converted = 0
    skipped = 0

    for jf in sorted(jsonl_files):
        out_path = OUTPUT_DIR / (jf.stem + ".md")

        # Skip already converted (unless --rebuild)
        if "--rebuild" not in sys.argv and out_path.exists():
            skipped += 1
            continue

        conv = extract_conversation(jf)

        if not conv["turns"]:
            skipped += 1
            continue

        md = to_markdown(conv)
        out_path.write_text(md, encoding="utf-8")
        converted += 1
        print(f"  Converted: {jf.name} ({len(conv['turns'])} turns)")

    print(f"\nDone: {converted} converted, {skipped} skipped")
    return converted


def setup_qmd_collection():
    """Add or update the qmd collection for conversations."""
    # Check if collection exists
    result = subprocess.run(["qmd", "collection", "list"], capture_output=True, text=True)
    if COLLECTION in result.stdout:
        print(f"Collection '{COLLECTION}' already exists — updating index")
        subprocess.run(["qmd", "update"], check=False)
    else:
        print(f"Adding collection '{COLLECTION}'")
        subprocess.run([
            "qmd", "collection", "add", str(OUTPUT_DIR),
            "--name", COLLECTION,
            "--mask", "**/*.md",
        ], check=False)
        subprocess.run(["qmd", "context", "add", str(OUTPUT_DIR),
                        "Claude Code conversation history — searchable on demand"], check=False)
        subprocess.run(["qmd", "update"], check=False)


if __name__ == "__main__":
    print(f"Output dir: {OUTPUT_DIR}")
    converted = process_jsonl_files()
    if converted > 0 or "--rebuild" in sys.argv:
        print("\nIndexing into qmd...")
        setup_qmd_collection()
        print("\nDone. Query with: qmd query \"your question\"")
        # Run embed in background so new docs get vectors
        subprocess.Popen(["qmd", "embed"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print("Embedding queued in background.")
    else:
        print("Nothing new to index. Use --rebuild to reindex all.")
