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

## What is shared and what is separate

One copy, used by both instances:

- **The T3 Code app.** Both instances launch the same bundle in `/Applications`, so one install and one auto-update cover both, and both keep the same keychain identity (`safeStorage`). Each instance's `userdata/secrets` is its own file, but that shared identity means either instance could decrypt the other's.
- **The real home.** Each shadow home is a symlink farm of the real home's top-level entries, so `.ssh`, `.gitconfig`, `.config`, `~/Development`, fnm/node and the rest resolve at their usual paths. Dotfiles added later show up in an instance after its next launch.
- **OpenCode assets.** `~/.config/opencode/{agents,commands,skills}` and `~/.agents/skills` serve both profiles.
- **macOS.** One user session, one keychain, one Raycast script. Each shadow home's `Library/Keychains` links to the real home's keychains so macOS can find the login keychain and the shared `t3code Key`.

One copy per instance:

- **`T3CODE_HOME`.** Projects, threads (`state.sqlite`), provider instances and model selection (`settings.json`), UI settings (`client-settings.json`), window state and server exposure (`desktop-settings.json`), `keybindings.json`, `userdata/secrets`, the connection catalog, published `themes/`, logs, caches, worktrees.
- **The server.** Each app embeds its own on its own port: `3773` personal, `3774` work.
- **The shadow HOME.** Its own Electron user data and single-instance lock. UI state that lives in localStorage — theme selection, layout, drafts — is per instance too; `bin/seed-ui` carries it over from the current T3 Code once, and the instances diverge from there.
- **The OpenCode profile.** Config and session database: personal runs `opencode.personal.jsonc` against `opencode.personal.db`, work runs `opencode.work.jsonc` against `opencode.work.db`.
- **The theme.** Set per environment and picked up by whatever client connects: personal is Iris (purple), work is Yew (`themes/yew.json`, the built-in Grove palette as `appearance: dark`, so it is dark green whatever the system appearance is). `npx t3@latest theme show --base-dir <home>` reads it, `theme set`/`theme clear` change it.
- **The connection catalog.** Each instance pairs its own environments; the devbox personal pairing lives in personal, the devbox work pairing in work.
- **T3 account sign-in.** `clerk-tokens.json` is seeded per instance by `bin/seed-ui` and then independent.

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

`seed-trial` snapshots each live `state.sqlite` with `VACUUM INTO` and copies the rest of `userdata`, including `settings.json`, `secrets` and the connection catalog, so providers carry over. `bin/seed-ui` then brings over what does not live in `userdata`: the client settings files a server-only home lacks, `HOME` for provider subprocesses, and the UI state (theme among it) from the current T3 Code's Electron user data. If a provider key does not decrypt in the trial, re-enter it once. The trial's agents share the live OpenCode session databases (`OPENCODE_DB`), so avoid running turns in a live instance and its trial copy at the same moment.

To start over: `./bin/uninstall --trial && ./bin/seed-trial`.

## Cutover

Daily layout: `~/.t3-personal` (moved from `~/.t3`) and `~/.t3-work`, ports `3773`/`3774`, both shadow homes. Work keeps its home and port — only who runs the server changes.

Run `./bin/cutover` from Terminal — not from inside T3 Code, because it quits the app. It performs steps 1–5 and the relaunch in step 8 as one sequence, and prints the devbox work pairing URL for step 6. The steps below are what it does, in order.

1. Quit both trial instances and the current T3 Code. Stop the work service: `launchctl bootout gui/$(id -u)/com.t3tools.t3code.service` (keep the plist for rollback).
2. Disable T3 Code's own login item in System Settings, otherwise it recreates `~/.t3`.
3. `lsof +D ~/.t3` — nothing may hold it. Then `mv ~/.t3 ~/.t3-personal` and `./bin/repair-paths ~/.t3-personal ~/.t3` (thread rows and git worktree links still point into `~/.t3`).
4. Set `MODE=daily` in `config.sh`, then `./bin/install` and `./bin/seed-ui` (carries the current T3 Code's UI state and client settings into both homes).
5. Set the themes: `npx t3@latest theme set --base-dir ~/.t3-personal iris` and `npx t3@latest theme set --base-dir ~/.t3-work themes/yew.json`.
6. Personal instance: Settings → Connections → remove the work-side entries (MAC0133 work, devbox work). Work instance: pair devbox work with `ssh devbox '~/.local/bin/t3 pair --base-dir ~/.t3-work --label devbox-work'` and paste it under Settings → Connections. The devbox personal pairing lives in the personal catalog and survives the rename.
7. Rebind Cmd+1 to `raycast/t3-focus.sh` if Raycast was pointing at the old tooling.
8. Relaunch both apps, then verify a turn in each, `curl http://100.109.52.7:3773/.well-known/t3/environment` and `:3774`, and `./bin/status`.
9. `./bin/uninstall --trial` and update `~/.claude/skills/agent-setup/SKILL.md` (environments table, Mac startup, connection catalog).

## Rollback

`mv ~/.t3-personal ~/.t3` and `./bin/repair-paths ~/.t3 ~/.t3-personal`, re-enable the launchd service and the T3 Code login item, set `MODE=trial` back if you want the trial apps again. The environment themes stay in the homes' `settings.json` until `npx t3@latest theme clear --base-dir <home>` removes them; nothing else is modified.

## Quirks

- **First decrypt can stall for a while.** Each instance's first read of the connection catalog and Clerk tokens waits on macOS authorizing T3 Code's keychain entry; allow the dialog if one appears. Later reads are instant.
- **Dock tiles show "T3 Code (Alpha)".** The launcher execs the real binary, so the tile comes from the shared bundle; two running instances mean two identical tiles. Distinguish them by window content or per-instance theme.
- **A stray `open -a "T3 Code (Alpha)"` launches a stock instance** with `T3CODE_HOME=~/.t3` and a scanned port. Launch from the two apps; `./bin/status` shows what runs.
- **`t3code://` links reach one instance.** With both running, OAuth handoffs may land in the other one — start those flows in the instance you are using.
- **Working directories may show the shadow-home path** (`os.homedir()`). Cosmetic; the farm makes the contents identical to the real home.
- **New dotfiles appear in an instance after its next launch.** The farm is rebuilt when an app starts.
