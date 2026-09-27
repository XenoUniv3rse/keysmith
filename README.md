# Keysmith

**A GUI for your Hyprland keyboard shortcuts on Omarchy.**

Keysmith is an Omarchy shell panel for viewing, adding, editing and removing
the shortcuts in `~/.config/hypr/bindings.lua`, without hand-writing Lua.

## Install

```bash
omarchy plugin add https://github.com/XenoUniv3rse/keysmith.git --enable --yes
```

Optional launcher entry (so it shows up under **Super + Space › Keysmith**):

```bash
cp ~/.config/omarchy/plugins/ebirkhoff.keysmith/keysmith.desktop ~/.local/share/applications/
```

## Remove

```bash
omarchy plugin remove ebirkhoff.keysmith --yes
rm -f ~/.local/share/applications/keysmith.desktop
```

Your shortcuts stay: they are plain Lua in `~/.config/hypr/bindings.lua`.
Backups Keysmith made are next to it as `bindings.lua.bak.keysmith.*`, and
you can delete them whenever you like.

## Open it

- **Super + Space**, type *Keysmith* (with the launcher entry installed), or
- `omarchy-shell shell toggle ebirkhoff.keysmith`, or
- bind it to a key — from inside Keysmith: *New shortcut › Toggle a shell plugin / panel › Keysmith*.

## What it does

- **My shortcuts** — everything in `bindings.lua`, with which Omarchy default
  each one replaces.
- **Omarchy defaults** — every default binding, with *Override*, *Disable* and
  *Re-enable*.
- **Editor** — record the shortcut by pressing it, or pick modifiers + a key
  from a searchable list, or type it (`SUPER + SHIFT + E`). Conflicts are shown
  before you save, and the needed `hl.unbind` is added for you.

### Actions

| Action | Writes |
|---|---|
| Open an app (optionally focus if running) | `{ launch = "app.desktop" }` |
| Open a web app | `{ webapp = "https://…" }` |
| Open a link, file or folder | `xdg-open …` |
| Run a command (background / terminal / as app) | `"cmd"`, `{ tui = … }`, `{ launch = … }` |
| Type text | `wtype -s <delay> -- '…'` |
| Window & workspace | `hl.dsp.window.*`, `hl.dsp.focus(…)` |
| Media, volume & brightness | Omarchy audio/brightness commands |
| Screenshot & capture | Omarchy capture commands |
| System & notifications | lock, suspend, reboot, notifications… |
| Toggle a shell plugin / panel | `omarchy-shell shell toggle <id>` |
| Open an Omarchy menu | `omarchy-menu toggle <menu>` |
| Omarchy toggle | `omarchy-toggle-<name>` |
| Do nothing (block the key) | `"true"` |
| Custom Lua dispatcher | any `hl.dsp.…` expression |

Options: works on lock screen, repeat while held, fire on release.

### Keys

| | |
|---|---|
| `↑` `↓` / `j` `k` | select |
| `Enter` | edit |
| `Del` | remove |
| `N` | new shortcut |
| `Tab` | switch list |
| `/` | search |
| `Ctrl+Z` | undo |
| `Esc` | close |

## How it works

- **Reading.** `scan.lua` runs your real `hyprland.lua` against recording
  stubs for `hl` and `o`. Loops, `require`s and helpers resolve exactly as in
  Hyprland, so the list matches what Hyprland registers.
- **Writing.** Keysmith rewrites only the exact source lines of plain
  top-level `o.bind` / `hl.bind` / `hl.unbind` calls. It shows bindings built
  in loops, functions or other files, but leaves those for hand-editing.
- **Safety.**
  - It backs up `bindings.lua` (`bindings.lua.bak.keysmith.<timestamp>`) before
    its first write in each session.
  - After every save it runs `hyprctl reload` and `hyprctl configerrors`. If
    the change introduces a new error, the file is reverted automatically.
  - There's an Undo button.
- **Typing text.** A key you're still holding (like Super) merges into text
  that `wtype` injects, so typing waits a short, configurable delay first.
- **Recording.** Combos Hyprland already uses are caught by Hyprland before
  they reach the panel. Pick those from the key list instead.

Needs `lua` (a Hyprland dependency). *Type text* needs `wtype`.

Tests: `node test/run.js <scan.json>`, where the scan comes from
`lua scan.lua ~/.config/hypr/hyprland.lua ~/.config/hypr/bindings.lua`.

## License

MIT
