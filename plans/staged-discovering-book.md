# JSON Config File for cmux Keybindings

## Context

GitHub issue [#1486](https://github.com/manaflow-ai/cmux/issues/1486) requests:
1. A config file for keybindings (`~/.config/cmux/keybindings.json`) for dotfile portability and bulk editing
2. Ability to unbind shortcuts so keys pass through to the terminal

Currently all shortcuts are stored in UserDefaults with no file-based alternative. `StoredShortcut` is already `Codable`. No config file infrastructure exists for cmux-level settings (only Ghostty's text config at `~/.config/ghostty/config`).

**Approach:** Import/export model — UserDefaults stays source of truth, JSON file is for portability/backup. Human-readable shortcut strings (`"cmd+b"`, `"ctrl+shift+w"`). Single PR.

## JSON Schema

```json
{
  "version": 1,
  "keybindings": {
    "toggleSidebar": "cmd+b",
    "newTab": "cmd+n",
    "closeWindow": null,
    "focusLeft": "cmd+opt+left",
    "splitRight": "cmd+d",
    "leaderKey": "ctrl+b"
  }
}
```

- Keys = `Action.rawValue` strings (e.g. `"toggleSidebar"`, `"focusLeft"`)
- Values = human-readable shortcut strings: modifiers (`cmd`, `shift`, `opt`, `ctrl`) joined with `+`, then the key
- Special keys: `left`, `right`, `up`, `down`, `tab`, `return`
- `null` = unbound (key passes through to terminal)
- Omitted actions = unchanged (keep current UserDefaults or default)

## Implementation Steps

### Step 1: "Unbound" shortcut support

**`Sources/KeyboardShortcutSettings.swift`**
- Add sentinel for "unbound" state — store a special JSON value in UserDefaults (e.g. `{"unbound": true}`)
- Add `isUnbound(for:) -> Bool`
- Add `setUnbound(for:)` that stores sentinel + posts notification
- Change `shortcut(for:)` to return `StoredShortcut?` — returns `nil` when unbound
- Update `StoredShortcut.displayString` to handle nil/unbound display

**`Sources/AppDelegate.swift`**
- In `handleCustomShortcut(event:)`, skip `matchShortcut` for actions where shortcut is `nil` (unbound)
- This lets the key pass through to the terminal

**`Sources/cmuxApp.swift`**
- Add "Clear" button to `ShortcutSettingRow` to unbind a shortcut
- Display "None" when shortcut is unbound
- Localize new strings

### Step 2: Human-readable shortcut string parser/formatter

**New file: `Sources/KeybindingsConfigFile.swift`**
- `shortcutToString(_ shortcut: StoredShortcut) -> String` — e.g. `StoredShortcut(key: "b", command: true, ...) -> "cmd+b"`
- `stringToShortcut(_ string: String) -> StoredShortcut?` — e.g. `"cmd+shift+w" -> StoredShortcut(...)`
- Handle modifier aliases: `opt`/`option`, `ctrl`/`control`, `cmd`/`command`
- Handle special keys: `left`→`"←"`, `right`→`"→"`, `up`→`"↑"`, `down`→`"↓"`, `tab`→`"\t"`, `return`→`"\r"`

### Step 3: Config file read/write

**In `Sources/KeybindingsConfigFile.swift`**
- `KeybindingsFileSchema` Codable struct: `version: Int`, `keybindings: [String: String?]`
- Custom decoding to handle `null` values (unbound)
- File path: `~/.config/cmux/keybindings.json`
- `load(from url: URL?) -> KeybindingsFileSchema?` — read + decode + validate
- `save(_ schema: KeybindingsFileSchema, to url: URL?)` — encode + write (pretty printed)
- `exportCurrentSettings() -> KeybindingsFileSchema` — snapshot all actions from UserDefaults
- `importSettings(_ schema: KeybindingsFileSchema)` — apply to UserDefaults, post notification
- Validation: warn on unknown action names, malformed shortcut strings

### Step 4: CLI commands

**`CLI/cmux.swift`**
- Add `cmux keybindings export [--file <path>]` — exports current shortcuts to JSON (defaults to `~/.config/cmux/keybindings.json`)
- `cmux keybindings import <file>` — imports from JSON file
- `cmux keybindings list [--json]` — lists all current bindings
- `cmux keybindings set <action> <shortcut|none>` — set a single binding
- `cmux keybindings reset [<action>|--all]` — reset to defaults

**`Sources/TerminalController.swift`**
- Add socket v2 methods: `keybindings.list`, `keybindings.set`, `keybindings.reset`, `keybindings.export`, `keybindings.import`

### Step 5: Settings UI import/export

**`Sources/cmuxApp.swift`**
- Add "Export Keybindings" button — saves to `~/.config/cmux/keybindings.json` (NSSavePanel for custom path)
- Add "Import Keybindings" button — NSOpenPanel to select file, validate, apply
- Status feedback after import/export

### Step 6: Localization

**`Resources/Localizable.xcstrings`**
- Add English + Japanese strings for: "None" (unbound display), "Clear" (unbind button), "Export Keybindings", "Import Keybindings", success/error messages

## Critical Files

| File | Change |
|------|--------|
| `Sources/KeyboardShortcutSettings.swift` | Unbound support, optional return type |
| `Sources/AppDelegate.swift` | Skip unbound in routing |
| `Sources/cmuxApp.swift` | Clear button, import/export UI |
| `Sources/KeybindingsConfigFile.swift` | **NEW** — parser, formatter, file I/O |
| `CLI/cmux.swift` | `keybindings` subcommands |
| `Sources/TerminalController.swift` | Socket v2 methods |
| `Resources/Localizable.xcstrings` | New localized strings |

## Existing Code to Reuse

- `StoredShortcut` Codable struct — already has all modifier fields and key mapping (`Sources/KeyboardShortcutSettings.swift:286-441`)
- `SessionPersistence` JSON write pattern — atomic writes with `JSONEncoder` + `.sortedKeys` (`Sources/SessionPersistence.swift`)
- `DispatchSource.makeFileSystemObjectSource` file watching pattern (from `MarkdownPanel.swift`) — if we add file watching later
- Socket v2 method registration pattern in `TerminalController.swift`

## Verification

1. **Unbound:** Clear a shortcut in Settings, verify the key passes through to terminal
2. **Export:** Run `cmux keybindings export`, verify JSON at `~/.config/cmux/keybindings.json` is valid and human-readable
3. **Import:** Edit the JSON file, run `cmux keybindings import`, verify Settings UI reflects changes
4. **Round-trip:** Export → edit file → import → verify shortcuts match edits
5. **Null handling:** Set an action to `null` in JSON, import, verify it shows "None" in UI and key passes through
6. **Unknown actions:** Add a bogus key to JSON, import, verify it's ignored gracefully
7. **CLI list:** Run `cmux keybindings list --json`, verify output matches current settings
