# Custom Shell Command Keybindings

## Context

cmux's keybinding system only supports built-in actions (toggleSidebar, splitRight, etc.). Ghostty also has no shell execution from keybindings. Users want to bind key combos to arbitrary shell commands that run in the background using the focused pane's CWD — e.g., `shift+alt+p` → `plannotator view` in the current pane directory.

All infrastructure exists: JSON keybinding config, shortcut string parsing, pane CWD tracking (`panelDirectories[focusedPanelId]`), key dispatch chain, `Process` spawning patterns, and socket/CLI command patterns.

## JSON Config Format

Extend `~/.config/cmux/keybindings.json` with a `custom_commands` array:

```json
{
  "version": 1,
  "keybindings": { "toggleSidebar": "cmd+b" },
  "custom_commands": [
    {
      "id": "plannotator-view",
      "shortcut": "shift+alt+p",
      "command": "plannotator view",
      "label": "Open Plannotator",
      "cwd": "pane"
    }
  ]
}
```

Fields: `id` (required, unique), `shortcut` (required, same format as built-in), `command` (required, shell string), `label` (optional), `cwd` (optional: `"pane"` default, `"workspace"`, or absolute path).

## Implementation

### Phase 1: Data Model
**File: `Sources/KeybindingsConfigFile.swift`**

1. Add `CustomCommandBinding` struct (Codable, Equatable, Identifiable) with fields: id, shortcut, command, label?, cwd?
2. Add `custom_commands: [CustomCommandBinding]?` to `Schema` (optional for backward compat — no version bump needed)
3. Add computed `resolvedShortcut` property that calls existing `stringToShortcut()`

### Phase 2: In-Memory Store + Executor
**New file: `Sources/CustomCommandStore.swift`**

Singleton holding parsed custom commands + resolved shortcuts for fast matching.

- `reload()` — loads from config file, parses shortcuts
- `matchingCommand(for: NSEvent) -> CustomCommandBinding?` — reuses same flag normalization as `AppDelegate.matchShortcut` (line 10462-10464): strip numericPad/function/capsLock, compare flags, then match key character
- `addCommand()` / `removeCommand()` — mutate in-memory + persist to config file

**New file: `Sources/ShellCommandExecutor.swift`**

Fire-and-forget executor:
- Runs `/bin/sh -c <command>` on `DispatchQueue.global(qos: .userInitiated)` (off-main per socket threading policy)
- Sets `currentDirectoryURL` based on cwd mode:
  - `"pane"` → `workspace.panelDirectories[focusedPanelId]`
  - `"workspace"` → `workspace.currentDirectory`
  - absolute path → as-is
  - fallback → home directory
- Exposes context as env vars: `CMUX_PANE_CWD`, `CMUX_WORKSPACE_CWD`, `CMUX_PANEL_ID`, `CMUX_WORKSPACE_ID`
- stdout/stderr → `/dev/null` (user can redirect in their command)
- Errors logged via `dlog()` in DEBUG builds only

### Phase 3: Key Dispatch Integration
**File: `Sources/AppDelegate.swift`**

Insert custom command check at **line ~9257** — after fast-path returns (empty flags, browser omnibar bypass) but **before** built-in action matching. This lets custom commands override built-in shortcuts.

```swift
// ~line 9257, before "Primary UI shortcuts" section
if let cmd = CustomCommandStore.shared.matchingCommand(for: event) {
    #if DEBUG
    dlog("shortcut.customCommand id=\(cmd.id) cmd=\(cmd.command)")
    #endif
    ShellCommandExecutor.execute(binding: cmd, context: customCommandContext())
    return true
}
```

Add `customCommandContext()` helper that reads `tabManager?.selectedWorkspace` to get `focusedPanelId`, `panelDirectories`, and `currentDirectory`.

Load custom commands on app launch via `CustomCommandStore.shared.reload()`.

### Phase 4: Socket Commands
**File: `Sources/TerminalController.swift`**

Add v2 socket commands following the existing `keybindings.*` pattern:

- `custom_commands.list` — returns all custom commands
- `custom_commands.add` — add/update a custom command (params: id, shortcut, command, label?, cwd?)
- `custom_commands.remove` — remove by id
- `custom_commands.reload` — reload from config file

### Phase 5: CLI Commands
**File: `CLI/cmux.swift`**

Add `custom-commands` subcommand following the `keybindings` pattern:

```
cmux custom-commands list [--json]
cmux custom-commands add <id> <shortcut> <command> [--label X] [--cwd pane|workspace|/path]
cmux custom-commands remove <id>
cmux custom-commands reload
```

## Key Files

| File | Changes |
|------|---------|
| `Sources/KeybindingsConfigFile.swift` | Add `CustomCommandBinding` struct, extend `Schema` |
| `Sources/CustomCommandStore.swift` | **New** — singleton store + shortcut matching |
| `Sources/ShellCommandExecutor.swift` | **New** — background `/bin/sh -c` executor |
| `Sources/AppDelegate.swift` | Wire into `handleCustomShortcut` at ~line 9257, add context helper |
| `Sources/TerminalController.swift` | Add `custom_commands.*` socket commands |
| `CLI/cmux.swift` | Add `custom-commands` CLI subcommand |

## Design Decisions

- **Custom commands checked before built-in actions** — users who bind `cmd+n` to a custom command know what they're doing
- **No settings UI for v1** — JSON + CLI only; UI can come later reading from `CustomCommandStore`
- **No version bump** — `custom_commands` is optional in Schema, existing v1 files decode fine
- **No file watching** — reload via CLI/socket; matches current keybindings behavior
- **Invalid shortcuts in config silently skipped** with `dlog()` warning

## Verification

1. Create `~/.config/cmux/keybindings.json` with a test custom command
2. Run `cmux custom-commands reload` (or restart app)
3. Press the bound shortcut in a terminal pane
4. Verify the command ran in the background at the correct CWD
5. Verify built-in shortcuts still work
6. Verify the shortcut doesn't reach the terminal (event consumed)
7. Test via CLI: `cmux custom-commands list`, `add`, `remove`
