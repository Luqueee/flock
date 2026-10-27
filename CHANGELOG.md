# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/) (while below 1.0, minor versions may change behaviour).

## [Unreleased]

### Added
- **+ Workspace** button in the sidebar header: creates a new session with a terminal and switches to it.
- Clicking a project's name goes to its persistent terminal, creating it only the first time. It keeps its project and
  name when its shell changes directory.
- **×** on a project closes its sessions after a confirmation; locked sessions block it.
- **×** on every agent card (after a confirmation) and terminal (immediately) closes that pane.
- Icon buttons (**▾/▸**, **×**, **+**) are fixed-size squares with the glyph centred.

### Changed
- Projects are no longer native collapsible sections: a **▾/▸** button collapses them, so the name can open a terminal.

## [0.6.0] - 2026-10-21

### Changed
- **Renamed to Flock.** The plugin id is now `flock` (it was `native-agents`), so Tern stores its data in
  `plugin-data/flock/` and its actions are `plugin.flock.*`. CSS roles use the `flock.` prefix.
- Code moved to `lib/` and split into small modules: the sidebar lifecycle, navigation, project launcher,
  VS Code integration and the Tern snapshot adapter no longer live in one 650-line file.
- Large functions in the model and the view were broken into named helpers, and canvas actions are
  dispatched through a table.
- README rewritten in English.
- The view now shows up to 30 projects, 40 sessions, 40 agent cards and 40 terminals (it was 80, 120, 100 and 100),
  with "omitted" rows for the rest, so a redraw stays well inside Tern's 50 ms budget.

### Added
- StyLua configuration, `scripts/check.sh` (format, tests, strict type check) and a CI workflow.
- MIT license.
- A warning in the Tern log when a sidebar update takes more than 25 ms, since window handlers are disabled
  by Tern after 50 ms.

### Fixed
- With around 100 projects open, a refresh could exceed Tern's 50 ms budget for window handlers. Tern then disables
  the plugin's timers until reload, so the sidebar silently stopped updating. A full redraw now costs 18 to 23 ms
  with 106 panes (it was over 44 ms), and a refresh that finds nothing changed costs 2 to 8 ms instead of about
  28 ms, because the view is only rebuilt when a fingerprint of the window state changes.
- A style rule used a `rem` unit, which Tern's CSS does not accept; Tern logged a parse error and ignored it.

### Migration
- Hide the sidebar of the old plugin, then `tern plugin unlink native-agents` and `tern plugin link .`.
- Move `plugin-data/native-agents/` (`kv.json`, `vscode.json`) to `plugin-data/flock/`.
- Rename any `plugin.native-agents.*` entries in your `keybinds` to `plugin.flock.*`.

## [0.5.0]

### Added
- A **VS Code** button on every agent card that opens the agent's git worktree. omp keeps the cwd it was
  launched in after `git worktree add`, so the worktree is inferred from the absolute paths of the files the
  agent edited (read from its transcript) and `git worktree list` on the agent's own machine, with symlinks
  resolved. Falls back to the project folder when it cannot be determined.
- Git queries run locally through `sh`, or read-only over `ssh` for remote hosts.

## [0.4.0]

### Added
- A **VS Code** button per project, and the *Open the focused project in VS Code* command. Remote projects
  open through Remote - SSH on the same path.
- Optional `vscode.json` to choose the launcher command and map Tern host names to SSH aliases.

## [0.3.0]

### Added
- Existing terminal blocks are listed under their project and session, with native state (running, ready,
  exited) and one-click focus. Global terminal count in the header.

## [0.2.0]

### Added
- Two-line agent cards (title, then state and model), compact paths with full tooltips.
- An attention section for agents waiting for an answer, and per-state counters.
- A launcher on each project to start a new omp or a terminal in its directory.
- A projects-with-agents filter, and next-waiting / last-agent navigation.

## [0.1.0]

### Added
- First version: a native sidebar that groups sessions and omp agents by machine and working directory, shows
  native agent states and focuses the original pane without touching omp's own interface.
