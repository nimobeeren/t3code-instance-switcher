# Shared configuration for the two T3 Code desktop instances.
# Sourced by every script in bin/; never executed on its own.
#
# MODE=trial  disposable data copies on free ports, live setup untouched
# MODE=daily  the cutover layout: ~/.t3-personal and ~/.t3-work on 3773/3774

MODE=daily

REAL_HOME="$HOME"
RUNTIME_DIR="$HOME/.local/share/t3-instances"
SHADOW_ROOT="$RUNTIME_DIR/homes"
STATE_DIR="$RUNTIME_DIR/state"
APPS_DIR="$HOME/Applications"

# Live homes the trial copies are seeded from. Read-only sources.
personal_SEED_SOURCE="$HOME/.t3"
work_SEED_SOURCE="$HOME/.t3-work"

if [ "$MODE" = trial ]; then
  personal_T3CODE_HOME="$HOME/.t3-trial/personal"
  personal_T3CODE_PORT=3783
  work_T3CODE_HOME="$HOME/.t3-trial/work"
  work_T3CODE_PORT=3784
else
  personal_T3CODE_HOME="$HOME/.t3-personal"
  personal_T3CODE_PORT=3773
  work_T3CODE_HOME="$HOME/.t3-work"
  work_T3CODE_PORT=3774
fi

instance_label() {
  case "$1" in
    personal) echo "T3 Code Personal" ;;
    work) echo "T3 Code Work" ;;
  esac
}

instance_app() {
  echo "$APPS_DIR/$(instance_label "$1").app"
}

instance_home() {
  local var="${1}_T3CODE_HOME"
  echo "${!var}"
}

instance_port() {
  local var="${1}_T3CODE_PORT"
  echo "${!var}"
}

# The shared T3 Code install. Both instances run this one binary so a single
# auto-update covers both and safeStorage keeps its keychain identity.
t3_bundle() {
  local candidate
  for candidate in "/Applications/T3 Code (Alpha).app" "/Applications/T3 Code.app" "/Applications/T3 Code (Nightly).app"; do
    if [ -d "$candidate" ]; then
      echo "$candidate"
      return 0
    fi
  done
  echo "no T3 Code bundle found in /Applications" >&2
  return 1
}

t3_executable() {
  local bundle="$1" dir="$1/Contents/MacOS" base
  local names=("$dir"/*)
  if [ -e "${names[0]}" ] && [ "${#names[@]}" -eq 1 ]; then
    printf '%s\n' "${names[0]##*/}"
    return 0
  fi
  base="${bundle##*/}"
  printf '%s\n' "${base%.app}"
}

# A pid file holds the instance's main process: written just before `exec`, so
# the pid survives into the Electron app. Backend and helper processes have
# other pids and NSRunningApplication cannot activate them — matching those is
# what makes a "focus" silently do nothing.
instance_pid() {
  local file="$STATE_DIR/$1.pid"
  [ -s "$file" ] || return 0
  printf '%s\n' "$(<"$file")"
}

instance_running() {
  local pid exe bundle args
  pid="$(instance_pid "$1")"
  [ -n "$pid" ] || return 1
  bundle="$(t3_bundle)" || return 1
  exe="$bundle/Contents/MacOS/$(t3_executable "$bundle")"
  args="$(/bin/ps -p "$pid" -o args= 2>/dev/null)" || return 1
  [[ "$args" == *"$exe"* ]]
}

focus_pid() {
  /usr/bin/osascript -l JavaScript \
    -e "ObjC.import('AppKit');" \
    -e "const app = \$.NSRunningApplication.runningApplicationWithProcessIdentifier($1);" \
    -e "app.activateWithOptions(\$.NSApplicationActivateIgnoringOtherApps | \$.NSApplicationActivateAllWindows);" \
    >/dev/null 2>&1
}
