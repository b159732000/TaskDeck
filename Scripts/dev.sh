#!/bin/zsh
# Dev loop: rebuild + relaunch the GUI only.
# taskdeckd (and every live terminal session) is untouched — restarting the
# GUI is always safe.
set -euo pipefail
cd "$(dirname "$0")/.."

Scripts/bundle.sh "${1:-debug}"
pkill -x TaskDeck 2>/dev/null || true
sleep 0.3
open dist/TaskDeck.app
echo "Relaunched TaskDeck"
