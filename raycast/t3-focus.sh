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
# goes to the one you used most recently.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
. "$BIN_DIR/../config.sh"

personal=false
work=false
if instance_running personal; then personal=true; fi
if instance_running work; then work=true; fi

if ! $personal && ! $work; then
  echo personal >"$STATE_DIR/last"
  /usr/bin/open "$(instance_app personal)" "$(instance_app work)"
  exit 0
fi

fallback=personal
if [ -s "$STATE_DIR/last" ]; then
  fallback="$(<"$STATE_DIR/last")"
fi
case "$fallback" in
  personal | work) ;;
  *) fallback=personal ;;
esac

args=(--fallback "$fallback")
if $personal; then args+=(--personal "$(instance_pid personal)"); fi
if $work; then args+=(--work "$(instance_pid work)"); fi

# focus.py picks the instance and activates it by pid. A non-zero exit means it
# printed the name but could not activate it — the instance is still starting up
# and has no NSRunningApplication yet, while the app bundle reaches it anyway.
if ! target="$(python3 -E -S -B "$BIN_DIR/focus.py" "${args[@]}")"; then
  /usr/bin/open "$(instance_app "${target:-$fallback}")"
fi
printf '%s\n' "${target:-$fallback}" >"$STATE_DIR/last"
