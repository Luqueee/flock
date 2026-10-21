# Flock

A native sidebar for [Tern](https://stencil.so/tern) that gathers your [omp](https://github.com/can1357/oh-my-pi)
agents, terminals and sessions in one place, grouped by project and machine.

Flock is inspired by Herdr but does not depend on it and does not replace anything: omp keeps drawing its own
transcript and composer, and a click on any entry focuses the **original pane**.

> The interface text is currently in Spanish.

## Features

- **Projects** by machine and working directory, with their sessions, agents and terminals. Projects with the same
  name but a different path or machine are never merged.
- **Live agent states** from Tern: working, waiting for you, idle, finished. A section at the top lists the agents
  that wait for an answer.
- **Terminals** you already have open, with their native state (running, ready, exited).
- **Start work in a project**: a new omp or a terminal in the project's directory, session and machine.
- **Open VS Code** on a project, or on the **git worktree** an agent is working in, locally or over SSH.
- **Navigation**: next agent waiting for you, last visited agent, and a *projects with agents* filter.

Flock never sends prompts, scrapes the terminal or recreates the chat.

## Requirements

- Tern with plugin support (verified on Tern 0.9.4, Linux, with omp 18.12).
- For VS Code: the `code` command on Tern's `PATH`, and the *Remote - SSH* extension for remote projects.
- For worktree detection on a remote machine: `ssh` that works without a password from this machine.

## Install

```sh
tern plugin install github.com/Luqueee/flock
```

Or clone it and use it in place, so Tern reloads it on every save:

```sh
git clone https://github.com/Luqueee/flock
tern plugin link ./flock
```

Open the palette and run **Mostrar u ocultar sidebar** (group **Flock**), or press `Ctrl+Alt+Shift+H`.
The sidebar is hidden at first and remembers your choice afterwards.

| Action                                 | Default key        |
| -------------------------------------- | ------------------ |
| `plugin.flock.toggle`                  | `Ctrl+Alt+Shift+H` |
| `plugin.flock.next_waiting`            | `Ctrl+Alt+Shift+J` |
| `plugin.flock.last_agent`              | `Ctrl+Alt+Shift+L` |
| `plugin.flock.refresh`                 | -                  |
| `plugin.flock.toggle_filter`           | -                  |
| `plugin.flock.open_vscode`             | -                  |

Bind any of them in your own `keybinds`; user keys always win over plugin keys.

## Usage

- Click an **agent** or **terminal** to focus its pane, switching session first if needed.
- Click a project's path to focus its session. A project with several sessions lists them as separate rows.
- **+** on a project offers *new omp*, *terminal* or *cancel*. The new pane opens in a new tab of that project's
  session and machine and never replaces an existing one. `omp` must be on the `PATH` of that machine's shell.
- **VS Code** on a project opens its folder; on an agent card it opens the agent's worktree (see below).
- **Siguiente espera** and **Último agente** move between agents; **Todos los proyectos / Proyectos: con agentes**
  toggles the filter (it hides projects that only have terminals and never changes the global counters).
- **Ocultar** closes only Flock's own panels. It never closes agents, terminals or sessions.

## How the worktree is found

An omp agent that runs `git worktree add` keeps the cwd it was started in, so the session itself does not say
where the agent works. The only trace is the absolute path of each file it touches, which Tern exposes in the
agent's transcript. When you press **VS Code** on an agent:

1. Flock collects the newest file paths from its transcript. Edits and writes weigh more than reads.
2. On the agent's machine it runs `git worktree list --porcelain` and `realpath` (read-only): through `sh`
   locally, or through `ssh` with `BatchMode` for a remote host. `realpath` matters because an agent may use a
   symlinked spelling (`/home/me/work` -> `/data/work`) while git lists the canonical one.
3. It opens the root of the worktree that contains the most recently edited file, using the exact root git
   reports (for example `.worktrees/feature/workspace`, not `.worktrees/feature`). If the folder you started in
   already lies inside that worktree, it keeps yours.

It opens the **project folder** instead when the agent has touched no files, its last edit is in the main checkout
or outside the repository, its worktree was deleted or pruned, or git or `ssh` cannot answer (a toast explains
why). One chat can touch several worktrees; the one with the latest edit wins.

## Configuration

Optional `vscode.json` in the plugin's data folder (`<state>/plugin-data/flock/`; on Linux
`~/.local/state/tern/plugin-data/flock/`):

```json
{
  "command": "code-insiders",
  "hosts": { "buildbox": "buildbox-vpn" }
}
```

- `command` replaces the `code` launcher.
- `hosts` maps a Tern host name (case-insensitive) to an alias from `~/.ssh/config`. It is used both for VS Code
  and for querying git, and it takes priority over the address Tern knows.

Without a mapping, the SSH destination comes from the **address** Tern has for the machine (`user@host[:port]`), not
from its display name: a Tern host called `buildbox` may share its name with an unrelated `~/.ssh/config` alias.
A port other than 22 or an IPv6 address is encoded as a hex JSON `ssh-remote` authority. Aliases with characters
outside `A-Z a-z 0-9 . _ @ -` and launchers containing control characters are ignored; an invalid JSON file shows
a warning and the defaults apply. Launchers always run as an argument vector, never through a shell.

## What it runs

Flock makes no network requests. It runs processes only when you press **VS Code**: the `code` launcher on this
machine and, to find a worktree, `git worktree list` and `realpath` (through `ssh` for remote hosts), read-only.
Visibility and the filter are stored with `tern.kv` in the plugin's data folder.

## Limits

- Only agents and terminals that Tern can tie to a pane, tab and session are listed. Parked panes without a tab are
  not assigned to an invented session. Browsers, files and other native blocks are not shown as terminals.
- The view is bounded to stay inside Tern's 50 ms budget for window handlers: up to 30 projects, 40 sessions, 40
  agent cards, 40 terminals and 12 attention entries, with explicit "omitted" rows (the *projects with agents*
  filter helps when there are more). Counters include everything, not only what is drawn.
- A web client can show the replicated canvas but does not run the plugin, so clicks do nothing there.
- Worktree detection needs omp to publish file paths in the transcript. That was verified for `edit` and `write`;
  an agent that changes files only through `bash` leaves no trace and the project folder opens. It needs `sh` and
  `realpath` on the agent's machine and does not work on Windows.
- Remote support was tested against a real machine over `ssh`, but not through a connected remote Tern host, and
  Remote - SSH itself was not opened. Not verified on macOS, Windows or iOS.

## Development

```sh
tern plugin types .     # writes tern.d.luau for your Tern version (git-ignored)
./scripts/check.sh      # StyLua check, unit tests, strict type check
```

Needs [StyLua](https://github.com/JohnnyMorganz/StyLua), [Luau](https://github.com/luau-lang/luau) and
[luau-lsp](https://github.com/JohnnyMorganz/luau-lsp). CI runs the format check and the tests; the type check needs
Tern's definitions, so it runs locally.

```
plugin.toml        manifest
window.luau        entry point: commands, events, timer, canvas action table
flock.css          styles, scoped to data-role="flock.*"
lib/
  model.luau       pure: projects, sessions, agents and terminals from a snapshot
  view.luau        native node tree for the sidebar and its dock
  vscode.luau      pure: SSH destination and VS Code URIs
  worktree.luau    pure: transcript paths, git query command, worktree choice
  snapshot.luau    adapter: Tern window API -> model snapshot
  sidebar.luau     canvas lifecycle, state and refresh
  navigation.luau  focus agents, panes and sessions
  projects.luau    start omp / terminal in a project
  editor.luau      VS Code launching and worktree resolution
test/              unit tests for the pure modules
scripts/check.sh   format + tests + types
```

The modules that decide things (`model`, `vscode`, `worktree`) are pure and unit tested; everything that touches
Tern lives in the window-facing modules.

Tern window handlers have a 50 ms budget, after which Tern **disables the plugin's timers until it is reloaded**, so
Flock keeps refreshes cheap: it skips all work when nothing changed (about 2 to 8 ms with 100 projects open) and a
full redraw measured 18 to 23 ms with 106 panes. It logs a warning when a refresh takes more than 25 ms.

See [CHANGELOG.md](CHANGELOG.md). Official docs: [Tern plugin SDK](https://docs.stencil.so/tern/),
[window API](https://docs.stencil.so/tern/reference/api-window.md).

## License

[MIT](LICENSE)
