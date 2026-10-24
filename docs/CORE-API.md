# RemotoCore API

`RemotoCore` is the headless service behind Remoto. It serves the web client, runs the WebSocket protocol, handles TLS, pairing and trusted devices, runs deck actions and stores everything in `dataDir`. Anything that needs Apple APIs (apps, clipboard, volume, speech, native commands) is asked of the app through `HostDelegate`.

`import RemotoCore` also re-exports `RemotoInput` (`KeyboardLayout`, `KeyCap`, `MediaKey`, `MouseButton`, `InputSinkKind`, `EventLog`).

## Setup

```swift
let config = HostConfig(
    port: 8740,                                   // 0 = ephemeral
    dataDir: appSupport.appending(path: "Remoto"),
    webRoot: Bundle.main.url(forResource: "web", withExtension: nil),
    hostName: "Studio.local",                     // LocalHostName + ".local"
    computerName: "Studio",
    appVersion: "1.0.0",
    linkHost: .hostName,                          // .ipAddress, .custom("host[:port]")
    allowLocalProxy: false, allowPin: true, allowApproval: true,
    allowShell: false, voiceAvailable: true)

let host = RemotoHost(config: config, delegate: model)   // input: .engine(.system) by default
let port = try await host.start()                         // throws HostError(message)
```

- The host holds the delegate **weakly**. Keep your delegate alive.
- `RemotoHost` is `Sendable`; call it from any actor. Most methods are `async`.
- `init` loads trusted devices, per-device settings and the deck, and starts the input engine.
- `input: .engine(.log(EventLog()))` records events instead of posting them; `.discard` drops them.

## Lifecycle

| Call | Notes |
|---|---|
| `start() async throws -> UInt16` | Tries `port`, `port+1` … `port+19`. Emits `.started(port:preferredPortTaken:)` or `.failed(message)`. Idempotent while running. |
| `stop() async` | Phones get `bye{reconnect:true}`, all input is released, server closes. Emits `.sessionsChanged`, `.stopped`. Can `start()` again. |
| `shutdown() async` | `stop()` plus stopping the input engine for good. Call on quit. |
| `isRunning`, `port`, `config` | Synchronous reads. |
| `updateConfig(_:) async` | Replace the config. Shell/voice changes are pushed to phones; host name or link mode changes emit `.pairingChanged`. A new `port` needs `stop()` + `start()`. |

## Pairing card

| Call | Notes |
|---|---|
| `pairingInfo() async -> PairingInfo` | `link` (the QR), `pin`, `expiresInSecs`, `address`, `secureAddress`, `addresses`, `vpnAddresses`, `caFingerprint`. Refresh on `.pairingChanged`. |
| `setPinVisible(_:) async` | `true` while the card with the PIN is on screen, `false` when hidden. The PIN works while visible and for 180 s after. |
| `renewPairing() async` | New code and PIN. |
| `caCertificate() -> Data` | DER of the local CA (empty if TLS failed). Phones can also download it at `<address>/remoto.crt`. |

## Approvals

On `.approvalRequested(ApprovalRequest)` show Allow / Deny and call `respondApproval(id:allow:) async`. Close your UI on `.approvalEnded(id)` (it also fires on timeout after 120 s or when the phone leaves).

`deviceName` and `model` are chosen by the phone: show `address` on its own line, and warn when `nameMatchesTrustedDevice` is true (a trusted device already has that name).

## Devices

| Call | Notes |
|---|---|
| `connectedDevices() async -> [ConnectedDevice]` | Sorted by `connectedAt`. Refresh on `.sessionsChanged`. |
| `trustedDevices() async -> [TrustedDevice]` | Most recently seen first. Refresh on `.devicesChanged`. |
| `disconnect(session:) async` | Ends that connection. |
| `renameDevice(id:name:) async` | A name set on the Mac is never overwritten by the phone. |
| `forgetDevice(id:) async`, `forgetAllDevices() async` | Also deletes their settings and disconnects them. |

## Control and deck

| Call | Notes |
|---|---|
| `setPaused(_:) async`, `isPaused` | Global pause: input is dropped, running actions and shell commands stop. |
| `deckJSON() async -> String` | Export (pretty JSON). |
| `setDeckJSON(_:) async throws` | Import; throws `HostError` with a readable message if invalid. |
| `resetDeck() async` | Back to the default deck. |

## Things the app reports

| Call | When |
|---|---|
| `appsChanged() async` | Apps launched, quit, activated, hidden or shown (debounce ~0.4 s). Clears the icon cache. |
| `permissionChanged() async` | Accessibility permission changed (poll every 2 s). |
| `setLayout(_ layout: KeyboardLayout) async` | At start and whenever the input source changes. |
| `setInputTiming(repeatDelayMs:repeatIntervalMs:doubleClickMs:)` | At start and every 30 s. |
| `setVolumeState(value:muted:) async` / `clearVolumeState() async` | Output volume changed / no adjustable volume. |
| `voiceUpdate(session:_:)` | Dictation progress for `voiceBegin`. Synchronous; delivered in call order. A state other than `.listening` ends the session's dictation. |

## HostDelegate

All methods are called **off the main thread**, on background threads where blocking is fine. Hop to the main actor yourself when needed. At most 8 delegate calls run at once per phone connection.

| Method | Return / notes |
|---|---|
| `event(_ event: HostEvent)` | Delivered in order on one serial queue. |
| `apps() -> [AppEntry]` | Installed plus running apps. |
| `appIcon(id:sizePx:) -> Data?` | PNG, `sizePx` is 64, 128, 256 or 512. Cached by the core until `appsChanged()`. |
| `performApp(id:op:) -> Bool` | `op`: `.open`, `.toggle`, `.hide`, `.quit`. |
| `runNative(_:) -> Bool` | `.missionControl`, `.launchpad`, `.lockScreen`, `.sleepDisplay`, `.sleep`. |
| `openURL(_:) -> Bool` | The core already refused `javascript:`, `data:` and (unless `allowShell`) `file:`. |
| `runShortcut(name:) -> Bool` | |
| `readClipboard() -> String?`, `writeClipboard(_:)` | |
| `pasteBegin(_:) -> Bool`, `pasteEnd()` | Snapshot + set clipboard; the core then presses ⌘V and calls `pasteEnd` 450 ms later. |
| `setVolume(value:muted:)` | Either may be nil. Report the result back with `setVolumeState`. |
| `voiceBegin(session:locale:) -> Bool` | `locale` is the phone's, like `es-MX`. |
| `voiceFeed(session:pcm:)` | PCM Int16 LE, mono, 16 kHz. In order per session. |
| `voiceEnd(session:cancel:)` | |

### HostEvent

`.started(port:preferredPortTaken:)`, `.stopped`, `.failed(String)`, `.sessionsChanged`, `.devicesChanged`, `.pairingChanged`, `.approvalRequested(ApprovalRequest)`, `.approvalEnded(UInt64)`, `.paired(String)` (a new phone paired, show its name), `.notice(String)` (for example missing Accessibility permission).

## Logging

`RemotoHost.initLogging("info")` sets the level (`debug`, `info`, `warning`, `error`). Logs go to `os.Logger`, subsystem `io.github.msucedo.remoto`. They never contain typed text or clipboard contents.

## Files in `dataDir`

`trusted.json`, `deck.json`, `device-settings/*.json`, `identity.json`, `ca.key.pem`, `ca.cert.der`, `leaf.key.pem`, `leaf.cert.der`. Files are written atomically with mode `0600`. Unreadable JSON is moved aside as `*.corrupt`.

## Development

`swift run remoto-dev [--web <dir>] [--data <dir>] [--port 7979] [--approve] [--app-version <v>]` runs the core in a terminal with a logging input sink and a fake delegate, and prints the pairing link, PIN and CA fingerprint. `node tools/ws-e2e.mjs [--slow]` checks the protocol against it (needs `--approve`).
