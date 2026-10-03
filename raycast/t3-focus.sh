#!/bin/bash
# @raycast.schemaVersion 1
# @raycast.title T3 Code Focus
# @raycast.mode silent
# @raycast.packageName T3 Code
# @raycast.description Focus a running T3 Code instance, or start both
#
# Bind this to Cmd+1 in Raycast. With no instance running it starts both. With
# one running it focuses it. With both running it switches when one of them is
# already focused, and otherwise goes to the one you used most recently.
set -euo pipefail

BIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)"
. "$BIN_DIR/../config.sh"

personal=false
work=false
if instance_running personal; then personal=true; fi
if instance_running work; then work=true; fi

if $personal && $work; then
  personal_pid="$(instance_pid personal)"
  work_pid="$(instance_pid work)"
  read -r front mru <<<"$(python3 "$BIN_DIR/zorder.py" "$personal_pid" "$work_pid")"
  if [ "$front" = "$personal_pid" ]; then
    target=work
  elif [ "$front" = "$work_pid" ]; then
    target=personal
  elif [ "$mru" = "$personal_pid" ]; then
    target=personal
  elif [ "$mru" = "$work_pid" ]; then
    target=work
  else
    target="$(cat "$STATE_DIR/last" 2>/dev/null || echo personal)"
    case "$target" in
      personal | work) ;;
      *) target=personal ;;
    esac
  fi
elif $personal; then
  target=personal
elif $work; then
  target=work
else
  echo personal >"$STATE_DIR/last"
  /usr/bin/open "$(instance_app personal)" "$(instance_app work)"
  exit 0
fi

echo "$target" >"$STATE_DIR/last"
/usr/bin/open "$(instance_app "$target")"
