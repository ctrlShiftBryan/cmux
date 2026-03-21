import Foundation

/// Handles reading, writing, and converting keybindings between JSON config files and UserDefaults.
enum KeybindingsConfigFile {

    // MARK: - File Schema

    struct Schema: Codable {
        var version: Int = 1
        var keybindings: [String: String?]

        init(version: Int = 1, keybindings: [String: String?] = [:]) {
            self.version = version
            self.keybindings = keybindings
        }
    }

    // MARK: - File Paths

    /// Primary config file path: `~/.config/cmux/keybindings.json`
    static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/cmux/keybindings.json")
    }

    /// Fallback path: `~/Library/Application Support/cmux/keybindings.json`
    static var fallbackFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("cmux/keybindings.json")
    }

    /// Returns the first config file that exists, or nil.
    static var resolvedFileURL: URL? {
        let candidates = [defaultFileURL, fallbackFileURL]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Human-Readable Shortcut Strings

    /// Converts a `StoredShortcut` to a human-readable string like `"cmd+shift+w"`.
    static func shortcutToString(_ shortcut: StoredShortcut) -> String {
        var parts: [String] = []
        if shortcut.control { parts.append("ctrl") }
        if shortcut.option { parts.append("opt") }
        if shortcut.shift { parts.append("shift") }
        if shortcut.command { parts.append("cmd") }

        let keyName: String
        switch shortcut.key {
        case "←": keyName = "left"
        case "→": keyName = "right"
        case "↑": keyName = "up"
        case "↓": keyName = "down"
        case "\t": keyName = "tab"
        case "\r": keyName = "return"
        default: keyName = shortcut.key
        }
        parts.append(keyName)
        return parts.joined(separator: "+")
    }

    /// Parses a human-readable string like `"cmd+shift+w"` into a `StoredShortcut`.
    static func stringToShortcut(_ string: String) -> StoredShortcut? {
        let components = string.lowercased().split(separator: "+").map { String($0).trimmingCharacters(in: .whitespaces) }
        guard !components.isEmpty else { return nil }

        var command = false
        var shift = false
        var option = false
        var control = false
        var key: String?

        for component in components {
            switch component {
            case "cmd", "command", "super":
                command = true
            case "shift":
                shift = true
            case "opt", "option", "alt":
                option = true
            case "ctrl", "control":
                control = true
            case "left":
                key = "←"
            case "right":
                key = "→"
            case "up":
                key = "↑"
            case "down":
                key = "↓"
            case "tab":
                key = "\t"
            case "return", "enter":
                key = "\r"
            default:
                key = component
            }
        }

        guard let resolvedKey = key else { return nil }
        return StoredShortcut(
            key: resolvedKey,
            command: command,
            shift: shift,
            option: option,
            control: control
        )
    }

    // MARK: - Load / Save

    /// Loads and decodes a keybindings config file.
    static func load(from url: URL? = nil) -> Schema? {
        guard let fileURL = url ?? resolvedFileURL else { return nil }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Schema.self, from: data)
    }

    /// Encodes and writes a keybindings config file (pretty-printed).
    static func save(_ schema: Schema, to url: URL? = nil) throws {
        let fileURL = url ?? defaultFileURL

        // Ensure parent directory exists.
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(schema)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Export / Import

    /// Snapshots all current shortcuts (from UserDefaults + defaults) into a `Schema`.
    static func exportCurrentSettings() -> Schema {
        var bindings: [String: String?] = [:]
        for action in KeyboardShortcutSettings.Action.allCases {
            if let shortcut = KeyboardShortcutSettings.shortcut(for: action) {
                bindings[action.rawValue] = shortcutToString(shortcut)
            } else {
                // Explicitly unbound.
                bindings[action.rawValue] = nil
            }
        }
        return Schema(keybindings: bindings)
    }

    /// Applies a config file schema to UserDefaults.
    /// Unknown action names are silently skipped.
    /// Returns the number of actions applied.
    @discardableResult
    static func importSettings(_ schema: Schema) -> Int {
        var applied = 0
        for (actionName, shortcutString) in schema.keybindings {
            guard let action = KeyboardShortcutSettings.Action(rawValue: actionName) else {
                continue // Skip unknown actions.
            }
            guard let value = shortcutString else {
                // Explicitly unbound.
                KeyboardShortcutSettings.setUnbound(for: action)
                applied += 1
                continue
            }
            if let shortcut = stringToShortcut(value) {
                KeyboardShortcutSettings.setShortcut(shortcut, for: action)
                applied += 1
            }
        }
        return applied
    }
}
