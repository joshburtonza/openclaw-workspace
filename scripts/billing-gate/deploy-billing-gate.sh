#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# scripts/billing-gate/deploy-billing-gate.sh
# Installs BillingGate.tsx into a client React app and wires it into App.tsx.
#
# Usage:
#   deploy-billing-gate.sh <repo_path> <client_slug>
#
# Example:
#   deploy-billing-gate.sh /path/to/qms-guard ascend_lc
#   deploy-billing-gate.sh /path/to/chrome-auto-care race_technik
#   deploy-billing-gate.sh /path/to/favorite-flow-9637aff2 favorite_logistics
# ─────────────────────────────────────────────────────────────────────────────

set -uo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

REPO_PATH="$1"
CLIENT_SLUG="$2"

WS="$(cd "$(dirname "$0")/../.." && pwd)"
[[ -f "$WS/.env.scheduler" ]] && set -a && source "$WS/.env.scheduler" && set +a

AOS_URL="https://afmpbtynucpbglwtbfuz.supabase.co"
AOS_ANON_KEY="${SUPABASE_ANON_KEY:-}"

log() { echo "[billing-gate-deploy] $*"; }

if [[ ! -d "$REPO_PATH" ]]; then
  log "ERROR: Repo path not found: $REPO_PATH"
  exit 1
fi

# ── Find src/components dir ───────────────────────────────────────────────────
COMPONENTS_DIR=""
for candidate in "$REPO_PATH/src/components" "$REPO_PATH/components" "$REPO_PATH/src"; do
  if [[ -d "$candidate" ]]; then
    COMPONENTS_DIR="$candidate"
    break
  fi
done

if [[ -z "$COMPONENTS_DIR" ]]; then
  log "ERROR: Cannot find components directory in $REPO_PATH"
  exit 1
fi

log "Installing BillingGate into $COMPONENTS_DIR"

# ── Copy BillingGate.tsx ──────────────────────────────────────────────────────
cp "$WS/scripts/billing-gate/BillingGate.tsx" "$COMPONENTS_DIR/BillingGate.tsx"
log "Copied BillingGate.tsx"

# ── Update .env (local dev vars) ──────────────────────────────────────────────
ENV_FILE="$REPO_PATH/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  ENV_FILE="$REPO_PATH/.env.local"
fi

# Add AOS vars if not already present
for line in \
  "VITE_AOS_SUPABASE_URL=$AOS_URL" \
  "VITE_AOS_ANON_KEY=$AOS_ANON_KEY" \
  "VITE_CLIENT_SLUG=$CLIENT_SLUG"; do
  KEY_NAME="${line%%=*}"
  if grep -q "^${KEY_NAME}=" "$ENV_FILE" 2>/dev/null; then
    log "  $KEY_NAME already in .env — skipping"
  else
    echo "$line" >> "$ENV_FILE"
    log "  Added $KEY_NAME to .env"
  fi
done

# ── Patch App.tsx ─────────────────────────────────────────────────────────────
APP_TSX=""
for candidate in "$REPO_PATH/src/App.tsx" "$REPO_PATH/src/app.tsx" "$REPO_PATH/App.tsx"; do
  if [[ -f "$candidate" ]]; then
    APP_TSX="$candidate"
    break
  fi
done

if [[ -z "$APP_TSX" ]]; then
  log "WARNING: Could not find App.tsx — add BillingGate manually"
  log "  import BillingGate from './components/BillingGate'"
  log "  Wrap your root component: <BillingGate><YourApp /></BillingGate>"
  exit 0
fi

# Check if BillingGate already imported
if grep -q "BillingGate" "$APP_TSX"; then
  log "BillingGate already present in App.tsx — skipping patch"
  exit 0
fi

# Find the first import line and add BillingGate import after it
# Then find the return statement and wrap with BillingGate
python3 - <<PY
import re, sys

app_path = """$APP_TSX"""
components_relative = "./components/BillingGate"

with open(app_path, 'r') as f:
    content = f.read()

# Add import after the last existing import
import_insert = "import BillingGate from '" + components_relative + "'\n"
# Find position after all imports
last_import_match = None
for m in re.finditer(r'^import .+$', content, re.MULTILINE):
    last_import_match = m
if last_import_match:
    pos = last_import_match.end()
    content = content[:pos] + "\n" + import_insert + content[pos:]
    print("Added import")
else:
    content = import_insert + "\n" + content
    print("Added import at top")

# Wrap the root JSX element in the return statement
# Look for: return ( ... )  or  return <...>
# Strategy: find 'return (' and add BillingGate wrapper
content = re.sub(
    r'(return\s*\()\s*\n',
    r'\1\n    <BillingGate>\n',
    content,
    count=1
)
# Find the matching closing ) and add </BillingGate> before it
# Simple approach: find last ')' before 'export default' or end of function
# More robust: use a simple heuristic
lines = content.split('\n')
found_return = False
paren_depth = 0
for i, line in enumerate(lines):
    if not found_return and 'return (' in line and '<BillingGate>' in lines[i+1] if i+1 < len(lines) else False:
        found_return = True
        continue
    if found_return:
        paren_depth += line.count('(') - line.count(')')
        if paren_depth < 0:
            lines.insert(i, '    </BillingGate>')
            break

content = '\n'.join(lines)
with open(app_path, 'w') as f:
    f.write(content)
print("Patched App.tsx with BillingGate wrapper")
PY

log "Done. BillingGate installed for $CLIENT_SLUG"
log "Commit the changes and deploy to take effect."
