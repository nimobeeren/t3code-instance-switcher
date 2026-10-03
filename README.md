# T3 Code instances

Run several T3 Code desktop instances on one Mac at the same time, each with its own projects, threads, providers and secrets. One hotkey switches between them.

The point of this repo is the switching. T3 Code itself only knows how to run one copy, so this adds a launcher per instance and a switcher that knows which instance to bring forward when you press the hotkey.

## Prerequisites

Everything here is macOS. The launchers and the switcher use AppKit and the window server, so none of it runs on Linux or Windows.

You need:

- T3 Code installed in `/Applications`, any of the usual bundles. The scripts look for `T3 Code (Alpha).app`, `T3 Code.app` and `T3 Code (Nightly).app`.
- Xcode Command Line Tools, to compile the switcher: `xcode-select --install`

And you need to know two things about how T3 Code stores its state, because that is all an "instance" is:

- It keeps everything it owns in one directory, named by `T3CODE_HOME`. Run the standard way, that is `~/.t3`. Projects, threads, settings, secrets, caches, all of it.
- It runs one embedded server, on the port named by `T3CODE_PORT`.

Two instances are therefore just two of those directories on two ports. The one complication is that the desktop app allows only one running copy per Electron user data directory, and macOS derives that from your home directory. So each instance runs with its own home directory. That is not a second account and not a copy of your files. It is a small directory that holds the app's own user data, with everything else in your real home symlinked in at the same paths, so git, ssh, your dotfiles and your code resolve exactly as they do today.

## Setup from a standard single instance

If you run T3 Code the normal way today, you have one instance and its data lives in `~/.t3`.

1. Quit T3 Code.
2. Edit `config.sh`. Pick a name, a data directory and a port per instance. Names are lowercase letters, digits and dashes. Ports must be unique per instance.

   ```sh
   INSTANCES=(personal work)

   personal_T3CODE_HOME="$HOME/.t3-personal"
   personal_T3CODE_PORT=3773
   work_T3CODE_HOME="$HOME/.t3-work"
   work_T3CODE_PORT=3774
   ```

3. Give each instance its data. Move the directory you already have to the instance that should keep it: `mv ~/.t3 ~/.t3-personal`. The other instances start with no data directory and fill theirs in on first launch. Copy instead of move if you want a backup.
4. Run `./bin/install`. It compiles the switcher and writes one launcher app per instance into `~/Applications`.
5. Open the launcher apps. Each instance creates its own data directory contents on first run.
6. Point providers at your real home. The app runs with the instance home as `HOME`, and provider processes inherit it, so add `HOME` set to your real home directory in each provider's environment in the instance's `settings.json`. Otherwise new files that agent work creates at `~/something` land in the instance home instead of your real one.
7. Optionally give each instance its own theme, which is the easiest way to tell the windows apart: `npx t3@latest theme set --base-dir <data directory> <theme>`.
8. Bind `bin/t3-focus` to a hotkey. Any launcher that can run a script on a hotkey works: Raycast, Alfred, Shortcuts, Keyboard Maestro, Hammerspoon.

`./bin/status` shows what is configured and what is running.

## What is shared and what is separate

Shared by every instance:

- The T3 Code app in `/Applications`. One install, one auto-update, one keychain identity (`safeStorage`). Each instance stores its own secrets file, but the shared identity means one instance could decrypt another's.
- Your real home directory. Each instance home symlinks it in, so `.ssh`, `.gitconfig`, `.config` and your code are at their usual paths. Top level files and directories added later appear in an instance after its next start.
- OpenCode config and skills under `~/.config/opencode` and `~/.agents`.

Separate per instance:

- `T3CODE_HOME`: projects, threads (`state.sqlite`), `settings.json`, client and desktop settings, keybindings, `userdata/secrets`, logs, caches, worktrees.
- The embedded server, on its own port.
- The instance home: the app's own user data, so theme, layout, drafts and window state differ too.
- The OpenCode profile the instance runs, config and session database included.
- Theme and account sign-in state.

## Layout

```
~/Applications/T3 Code <Name>.app    launcher app, runs bin/launch <name>
~/.local/share/t3-instances/homes/   one instance home per instance
~/.local/share/t3-instances/state/   main-process pids, last focused instance
```

## Switching

`bin/t3-focus` picks which instance to bring forward:

- Nothing running: starts all of them.
- One running: focuses it.
- Several running: switches away from the instance you are in when you are in one of them, and otherwise goes to the most recently used one overall, then to the one you last focused here.

"Most recently used" is read from the window order at the moment you press, so clicks, Cmd-Tab and the switcher itself keep it right without recording anything along the way. The switcher prints the name of the instance it picked. `./bin/t3-focus --dry-run` prints the same name without activating anything.

Each launcher app is the plain version of this for one instance: it starts that instance or focuses it when it already runs.

## Gotchas

- `t3code://` links reach one running instance and which one is up to LaunchServices, so start OAuth and similar flows in the instance you are using.
- Launching T3 Code from Spotlight or `open -a "T3 Code"` bypasses the launchers and starts a stock instance with the default data directory. Use the launcher apps or the hotkey.
- The first read of secrets and account tokens waits for macOS to authorize the app's keychain entry. Allow the dialog once and later reads are instant.
- Paths inside the app can show the instance home instead of your real home, since the app reports `os.homedir()`. The contents are the same through the symlinks.

## Removing

`./bin/uninstall` removes the launcher apps. `./bin/uninstall --runtime` also removes the instance homes and their state, UI state included. The data directories named by `T3CODE_HOME` are never touched.
