# T3 Code instances

Two separate T3 Code desktop instances on this Mac — **personal** and **work** — each with its own projects, threads, providers, secrets and connection catalog. Each one starts from its own app in `~/Applications`, and Raycast Cmd+1 focuses whichever is running.

## How it works

Both instances are the real `T3 Code (Alpha).app` binary (one shared install, one auto-update, one keychain identity) started with different `T3CODE_HOME` and `T3CODE_PORT`. Because Electron scopes its single-instance lock to its userData directory, which the app derives from `os.homedir()`, each instance also gets its own shadow `HOME` under `~/.local/share/t3-instances/homes/<name>`: a real `Library/` that owns userData and the lock, plus a symlink farm of every other top-level entry of the real home so git, ssh and dotfiles resolve as usual. Provider subprocesses additionally get `HOME=/Users/nimo.beeren` in their provider env (seeded into `settings.json`) so agent work never lands in a shadow home.

```
~/Applications/T3 Code Personal.app    launcher -> bin/launch personal
~/Applications/T3 Code Work.app        launcher -> bin/launch work
~/.local/share/t3-instances/homes/     shadow HOME per instance
~/.local/share/t3-instances/state/     main-process pids, last touched
```

Opening an app focuses that instance when it already runs, and starts it otherwise. The focus targets the instance's main process by pid; helper and backend processes cannot be activated, which is why a pid recorded at `exec` time is the reliable handle.

## Try it (trial)

Trial data is a disposable copy of the live homes, on ports `3783`/`3784`, so the current setup keeps running untouched.

```sh
cd ~/Development/t3-instances
./bin/install          # writes both apps into ~/Applications
./bin/seed-trial       # copies ~/.t3 and ~/.t3-work into ~/.t3-trial (sources read-only)
open ~/Applications/T3\ Code\ Personal.app
open ~/Applications/T3\ Code\ Work.app
./bin/status
```

Bind `raycast/t3-focus.sh` to Cmd+1: in Raycast, Settings → Extensions → Script Commands → add the `raycast/` directory here, search "T3 Code Focus", then assign the hotkey. Cmd+1 starts both when none runs, focuses the running one when only one does, and with both running switches to the other one when one of them is already focused — or owns the frontmost window — and otherwise it goes to the one you used most recently, read from window order at press time (`bin/focus.py`).

`seed-trial` snapshots each live `state.sqlite` with `VACUUM INTO` and copies the rest of `userdata`, including `settings.json`, `secrets` and the connection catalog, so providers carry over. If a provider key does not decrypt in the trial, re-enter it once. The trial's agents share the live OpenCode session databases (`OPENCODE_DB`), so avoid running turns in a live instance and its trial copy at the same moment.

To start over: `./bin/uninstall --trial && ./bin/seed-trial`.

## Cutover

Daily layout: `~/.t3-personal` (moved from `~/.t3`) and `~/.t3-work`, ports `3773`/`3774`, both shadow homes. Work keeps its home and port — only who runs the server changes.

1. Quit both trial instances and the current T3 Code. Stop the work service: `launchctl bootout gui/$(id -u)/com.t3tools.t3code.service` (keep the plist for rollback).
2. Disable T3 Code's own login item in System Settings, otherwise it recreates `~/.t3`.
3. `lsof +D ~/.t3` — nothing may hold it. Then `mv ~/.t3 ~/.t3-personal`.
4. Set `MODE=daily` in `config.sh`, then `./bin/install` and relaunch both apps.
5. Personal instance: Settings → Connections → remove the work-side entries (MAC0133 work, devbox work). Work instance: pair devbox work with `ssh devbox '~/.local/bin/t3 pair --base-dir ~/.t3-work --label devbox-work'` and paste it under Settings → Connections. The devbox personal pairing lives in the personal catalog and survives the rename.
6. Rebind Cmd+1 to `raycast/t3-focus.sh` if Raycast was pointing at the old tooling.
7. Verify a turn in each instance, `curl http://100.109.52.7:3773/.well-known/t3/environment` and `:3774`, and `./bin/status`.
8. `./bin/uninstall --trial` and update `~/.claude/skills/agent-setup/SKILL.md` (environments table, Mac startup, connection catalog).

## Rollback

`mv ~/.t3-personal ~/.t3`, re-enable the launchd service and the T3 Code login item, set `MODE=trial` back if you want the trial apps again. Nothing else is modified.

## Quirks

- **First decrypt can stall for a while.** Each instance's first read of the connection catalog and Clerk tokens waits on macOS authorizing T3 Code's keychain entry; allow the dialog if one appears. Later reads are instant.
- **Dock tiles show "T3 Code (Alpha)".** The launcher execs the real binary, so the tile comes from the shared bundle; two running instances mean two identical tiles. Distinguish them by window content or per-instance theme.
- **A stray `open -a "T3 Code (Alpha)"` launches a stock instance** with `T3CODE_HOME=~/.t3` and a scanned port. Launch from the two apps; `./bin/status` shows what runs.
- **`t3code://` links reach one instance.** With both running, OAuth handoffs may land in the other one — start those flows in the instance you are using.
- **Working directories may show the shadow-home path** (`os.homedir()`). Cosmetic; the farm makes the contents identical to the real home.
- **New dotfiles appear in an instance after its next launch.** The farm is rebuilt when an app starts.
