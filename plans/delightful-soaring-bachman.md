# Pushover Notification Forwarding for CMUX

## Context

Bryan previously had a Claude Code hook in dotfiles (`generate-session-url.js`, removed March 8 in commit `0764338`) that sent Pushover notifications when Claude completed tasks. Rather than restoring a standalone Claude hook, we'll integrate Pushover directly into CMUX's notification system — this is more powerful because CMUX's `TerminalNotificationStore` already has enriched notification content (title/subtitle/body), and forwarding at this layer catches ALL notifications, not just Claude events.

## Approach

Add a `PushoverSettings` enum + settings UI that forwards any CMUX notification to Pushover via HTTPS POST. Inject at the same two delivery points where `runCustomCommand` is already called.

## Files to Modify

| File | What |
|------|------|
| `Sources/TerminalNotificationStore.swift` | Add `PushoverSettings` enum; inject `sendNotification` calls at 2 delivery points |
| `Sources/cmuxApp.swift` | Add 3 `@AppStorage` properties + settings UI rows |
| `Resources/Localizable.xcstrings` | Localization keys for new UI strings |

## Implementation

### 1. `PushoverSettings` enum in `TerminalNotificationStore.swift`

Add after `NotificationPaneFlashSettings` (line ~579), following the same pattern:

```swift
enum PushoverSettings {
    static let enabledKey = "pushoverEnabled"
    static let defaultEnabled = false
    static let apiTokenKey = "pushoverApiToken"
    static let defaultApiToken = ""
    static let userKeyKey = "pushoverUserKey"
    static let defaultUserKey = ""

    private static let pushoverQueue = DispatchQueue(
        label: "com.cmuxterm.pushover",
        qos: .utility
    )

    static func sendNotification(
        title: String,
        message: String,
        defaults: UserDefaults = .standard
    ) {
        guard isEnabled(defaults: defaults) else { return }
        let token = resolveCredential(key: apiTokenKey, envVar: "PUSHOVER_API_TOKEN", defaults: defaults)
        let user = resolveCredential(key: userKeyKey, envVar: "PUSHOVER_USER_KEY", defaults: defaults)
        guard !token.isEmpty, !user.isEmpty else { return }

        pushoverQueue.async {
            var request = URLRequest(url: URL(string: "https://api.pushover.net/1/messages.json")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let params = ["token": token, "user": user, "title": title, "message": message]
            request.httpBody = params
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
                .joined(separator: "&")
                .data(using: .utf8)

            URLSession.shared.dataTask(with: request) { _, response, error in
                if let error { NSLog("Pushover failed: \(error)") }
                else if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    NSLog("Pushover returned status \(http.statusCode)")
                }
            }.resume()
        }
    }

    static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    private static func resolveCredential(key: String, envVar: String, defaults: UserDefaults) -> String {
        let stored = (defaults.string(forKey: key) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !stored.isEmpty { return stored }
        return ProcessInfo.processInfo.environment[envVar]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
```

Key design:
- Same `DispatchQueue` pattern as `customCommandQueue` (line 523)
- Fire-and-forget with NSLog on failure
- **Env var fallback**: reads `PUSHOVER_API_TOKEN`/`PUSHOVER_USER_KEY` from env if UserDefaults empty — works immediately with Bryan's existing env vars
- `URLSession.shared` — no new dependencies

### 2. Inject at notification delivery points

**Location A** — `scheduleUserNotification` (line ~1084), after `runCustomCommand`:
```swift
PushoverSettings.sendNotification(
    title: content.title,
    message: content.body.isEmpty ? content.subtitle : content.body
)
```

**Location B** — `playSuppressedNotificationFeedback` (line ~1096), after `runCustomCommand`:
```swift
PushoverSettings.sendNotification(
    title: resolvedNotificationTitle(for: notification),
    message: notification.body.isEmpty ? notification.subtitle : notification.body
)
```

### 3. Settings UI in `cmuxApp.swift`

**3a. @AppStorage properties** — add after line ~3809 (after `notificationPaneFlashEnabled`):
```swift
@AppStorage(PushoverSettings.enabledKey) private var pushoverEnabled = PushoverSettings.defaultEnabled
@AppStorage(PushoverSettings.apiTokenKey) private var pushoverApiToken = PushoverSettings.defaultApiToken
@AppStorage(PushoverSettings.userKeyKey) private var pushoverUserKey = PushoverSettings.defaultUserKey
```

**3b. Settings rows** — add after the Notification Command row (line ~4575), before the telemetry divider:
```swift
SettingsCardDivider()

SettingsCardRow(
    "Pushover Notifications",
    subtitle: "Forward notifications to your phone via Pushover. Falls back to PUSHOVER_API_TOKEN / PUSHOVER_USER_KEY env vars."
) {
    Toggle("", isOn: $pushoverEnabled)
        .labelsHidden()
        .controlSize(.small)
}

if pushoverEnabled {
    SettingsCardDivider()
    SettingsCardRow("Pushover API Token", subtitle: "From your Pushover application.") {
        SecureField("API Token", text: $pushoverApiToken)
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
    }
    SettingsCardDivider()
    SettingsCardRow("Pushover User Key", subtitle: "Your Pushover user/group key.") {
        SecureField("User Key", text: $pushoverUserKey)
            .textFieldStyle(.roundedBorder)
            .frame(width: 200)
    }
    SettingsCardDivider()
    SettingsCardRow("Test Pushover", subtitle: "Send a test notification.") {
        Button("Send Test") {
            PushoverSettings.sendNotification(title: "cmux", message: "Pushover is working!")
        }
        .controlSize(.small)
        .disabled(pushoverApiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && pushoverUserKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (ProcessInfo.processInfo.environment["PUSHOVER_API_TOKEN"] ?? "").isEmpty)
    }
}
```

Credential fields only appear when toggle is on. "Send Test" disabled when no credentials available.

### 4. Localization

Add keys to `Resources/Localizable.xcstrings` for all user-facing strings using the `String(localized:defaultValue:)` pattern.

### 5. Reset handler

Add to the settings reset function (line ~5573) alongside existing resets:
```swift
pushoverEnabled = PushoverSettings.defaultEnabled
pushoverApiToken = PushoverSettings.defaultApiToken
pushoverUserKey = PushoverSettings.defaultUserKey
```

## Verification

1. `./scripts/reload.sh --tag pushover` — build and launch
2. Open Settings → find Pushover section after Notification Command
3. Toggle on → verify credential fields appear
4. Enter credentials (or rely on env vars) → click "Send Test" → confirm push on phone
5. Trigger a real notification: run a Claude Code session in CMUX, let it stop → confirm Pushover fires
6. Toggle off → confirm no Pushover on next notification
7. Clear credentials, set env vars only → confirm fallback works
