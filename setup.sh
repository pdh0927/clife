#!/bin/bash
# One-shot install: builds the app and installs it into /Applications.
# Runs build.sh as a separate step (still usable on its own) rather than
# duplicating its logic.
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

./build.sh

pkill -f "Clife.app/Contents/MacOS/Clife" 2>/dev/null || true
sleep 1
rm -r -f /Applications/Clife.app
ditto Clife.app /Applications/Clife.app
open /Applications/Clife.app

cat <<'EOF'

Installed to /Applications/Clife.app and launched.

If macOS blocked the launch with an "unidentified developer" warning:
Right-click Clife.app in /Applications > Open > Open, once.

The first refresh may ask for permission to read the "Claude Code-credentials"
keychain item. Choose "Always Allow" -- the app reads that token to call the
same usage endpoint Claude's own menu bar popup uses.

Usage numbers only exist for Pro/Max accounts, and only once you've logged in
with `claude` at least once.
EOF
