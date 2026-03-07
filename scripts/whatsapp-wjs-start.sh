#!/usr/bin/env bash
# Wrapper for whatsapp-wjs-gateway — clears Chrome locks before starting
SESSION_DIR="/Users/henryburton/.openclaw/workspace-anthropic/tmp/wjs-session/session"
rm -f "$SESSION_DIR/SingletonLock" "$SESSION_DIR/SingletonCookie" 2>/dev/null
exec /opt/homebrew/bin/node /Users/henryburton/.openclaw/workspace-anthropic/scripts/whatsapp-wjs-gateway.cjs
