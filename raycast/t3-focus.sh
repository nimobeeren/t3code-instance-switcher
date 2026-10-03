#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title T3 Code Focus
# @raycast.mode silent
# @raycast.packageName T3 Code
# @raycast.description Focus a running T3 Code instance, or start both
#
# Bind this to Cmd+1 in Raycast. With no instance running it starts both. With
# one running it focuses it. With both running it switches to the other one when
# one of them is already focused — or owns the frontmost window — and otherwise
# goes to the one you used most recently. bin/focus decides and activates by
# pid; the first press leaves a warm helper behind so later presses are quick.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
. "$BIN_DIR/../config.sh"

if [ ! -x "$BIN_DIR/focus" ] || [ "$BIN_DIR/focus.m" -nt "$BIN_DIR/focus" ]; then
  "$BIN_DIR/build" || true
fi

BUNDLE="$(t3_bundle)"
export T3_FOCUS_STATE_DIR="$STATE_DIR"
export T3_FOCUS_APP_PERSONAL="$(instance_app personal)"
export T3_FOCUS_APP_WORK="$(instance_app work)"
export T3_FOCUS_EXEC="$BUNDLE/Contents/MacOS/$(t3_executable "$BUNDLE")"

exec "$BIN_DIR/focus"
