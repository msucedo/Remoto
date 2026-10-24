# Conformance (SPEC Appendix C)

Status of each checklist item for `RemotoCore`. **Done** = implemented and covered by the test named; **N/A** = belongs to another part (input engine, macOS app or web client); **Pending** = not done.

Test names are swift-testing functions in `Tests/RemotoCoreTests/` (`Suite.test`). `e2e` means `tools/ws-e2e.mjs` against `remoto-dev --approve` (`--slow` for the watchdog cases).

## HTTP server

| # | Item | Status | Covered by |
|---|---|---|---|
| 1 | `POST /` → 405; `GET /` with `Content-Length: 5` → 400 | Done | `HTTPRulesTests.precheckOrder`, `IntegrationTests.httpChecks`, e2e |
| 2 | Host acceptance (`evil.example.com` 421; `.local`, IP, `[::1]`, `.home.arpa`, single label OK; `local` rejected) | Done | `HostRulesTests.accepted`, `.rejected`, `IntegrationTests.httpChecks` |
| 3 | `/ws` foreign Origin 403, no Origin upgrades, no Upgrade 426, version 12 → 400 + `Sec-WebSocket-Version: 13` | Done | `HTTPRulesTests.websocketChecks`, `IntegrationTests.httpChecks`, e2e |
| 4 | Security headers and exact CSP on every response | Done | `HTTPRulesTests.responseHeaderOrder`, `IntegrationTests.httpChecks`, e2e |
| 5 | `/api/info` keys in order, `protocol: 1`, `no-store` | Done | `IntegrationTests.httpChecks`, e2e |
| 6 | `/api/icon`: 403 without key, 100 → 128, 300 → 512, cached | Done | `IntegrationTests.iconsNeedASessionKeyAndAreCached`, `HTTPRulesTests.iconBuckets` |
| 7 | `/assets/*` immutable + ETag, 304; SPA fallback `no-cache`; `.js` 404; `/.git/config` 404 | Done | `StaticFilesTests.servingRules` |
| 8 | ClientHello on the HTTP port served as HTTPS; closed silently without identity | Done | `IntegrationTests.httpsOnTheSamePortVerifiesAgainstTheCA` (the no-identity branch is code-reviewed, not tested) |
| 9 | 17th simultaneous connection from one IP closed | Done | `IntegrationTests.seventeenthConnectionFromOneAddressIsClosed`, `HardeningTests.connectionLimitGroupsIPv6By64` (IPv6 counted per /64) |
| 10 | Taken preferred port → next one, `preferredPortTaken = true` | Done | `IntegrationTests.takenPreferredPortMovesOn` |

## TLS

| # | Item | Status | Covered by |
|---|---|---|---|
| 11 | CA NameConstraints with the 8 subtrees, 3650 days; leaf ≤ 397 days, never past the CA | Done, with a deviation (below) | `TLSTests.createsCAWithConstraintsAndLeafWithSAN` |
| 12 | SAN without IPv6 or foreign names, sorted, unique | Done | `TLSTests.serverNamesAreFilteredSortedUnique`, `.createsCAWithConstraintsAndLeafWithSAN` |
| 13 | Restart keeps CA and leaf; new IP renews only the leaf; CA < 30 days is replaced | Done | `TLSTests.reusesThenRenewsOnlyWhatChanged`, `.caNearExpiryIsReplaced`, `.missingKeyRegenerates`, `HardeningTests.identityRenewalIsDueNearExpiry` (housekeeping also renews when the CA or leaf is within 30 days of expiry) |
| 14 | `caFingerprint` 95 chars, uppercase hex with `:` | Done | `TLSTests.createsCAWithConstraintsAndLeafWithSAN`, `.fingerprintFormat` |

## Pairing

| # | Item | Status | Covered by |
|---|---|---|---|
| 15 | Link `http://<host>:<port>/#pair=<24 base64url>` | Done | `LinkTests.pairingLinkShape`, `LinkTests.modes` |
| 16 | PIN never `000000`/`123456`/`654321`-like, 6 digits | Done | `SecretsTests.pinsAreNeverGuessable` |
| 17 | Used code → `expiredCode`; also rotates the PIN | Done | `PairingTests.codeIsSingleUseAndRotatesPin`, `IntegrationTests.codeIsSingleUse` |
| 18 | Hidden > 180 s → `pinClosed`; at 100 s accepted | Done | `PairingTests.pinWindowAndGrace` |
| 19 | 5 wrong PINs → 6th `blocked` ≈ 30; next lockout 60 s; PIN changed | Done | `PairingTests.wrongPinsLockOutAndRetirePin`, `IntegrationTests.wrongPinLocksOutWithRetryAfter` |
| 20 | 20 failures from different IPs in 60 s block a new IP | Done | `PairingTests.globalBlockHitsNewAddresses`, `RateLimiterTests.globalWindow` |
| 21 | `approve`: `pending`, reject → `rejected`, 3 rejections → `blocked`, same IP → `busy`, 120 s → `rejected` + `ApprovalEnded` | Done | `IntegrationTests.approvalFlow`, `PairingTests.approvals` (the 120 s timeout is not run in tests) |
| 22 | `allowPin = false` / `allowApproval = false` → `rejected` | Done | `IntegrationTests.pinPairingWorksAndCanBeDisabled` |
| 23 | `v:2`, id with space or 129 bytes → `incompatible`; first message `ping` → `bye{reconnect:false}` | Done | `IntegrationTests.incompatibleHellos`, e2e |
| 24 | `retryAfter` never 0, absent without a block | Done | `ServerMessageTests.everyMessageSpelling`, `IntegrationTests.wrongPinLocksOutWithRetryAfter` |

## Trust and session

| # | Item | Status | Covered by |
|---|---|---|---|
| 25 | `remember:true` → 43-char token; `remember:false` → `null`, no `trusted.json` | Done | `IntegrationTests.pairWelcomeTokenAndReconnect`, `.codeIsSingleUse` |
| 26 | `tokenHash` lowercase hex 64, never the token | Done | `TrustTests.issueVerifyAndNeverStoreToken`, `IntegrationTests.pairWelcomeTokenAndReconnect` |
| 27 | Valid token with another `device.id` → `unknown` | Done | `IntegrationTests.pairWelcomeTokenAndReconnect`, `TrustTests.issueVerifyAndNeverStoreToken`, e2e |
| 28 | Name renamed on the Mac survives reconnects | Done | `TrustTests.renamedNameSticks` |
| 29 | 65th device evicts the oldest `lastSeen` | Done | `TrustTests.sixtyFifthDeviceEvictsOldest` |
| 30 | `welcome` field order, `os == "macOS"`, omitted fields, `features.permission` | Done | `ServerMessageTests.welcomeFieldOrderAndOmissions`, `IntegrationTests.pairWelcomeTokenAndReconnect`, e2e |
| 31 | `Paired` → `DevicesChanged` → `SessionsChanged` | Done | `IntegrationTests.pairWelcomeTokenAndReconnect` |
| 32 | 9 s silent → closed without `bye`; ping every 2 s keeps it open | Done | `IntegrationTests.silentSessionIsClosedWithoutBye`, e2e `--slow` |
| 33 | `stop()` → `bye{reconnect:true}`; `forgetDevice` → `bye{reconnect:false}` and settings deleted | Done | `IntegrationTests.stopSaysByeWithReconnect`, `.forgetDeviceSaysByeAndDropsSettings`, `MoreSessionTests.settingsRulesForSessionsThatArentRemembered` |
| 34 | Malformed JSON keeps the session and releases keys | Done | `IntegrationTests.sessionMessages`, e2e |
| 35 | `ping{id:"x"}` → `pong{id:"x"}` | Done | `IntegrationTests.sessionMessages`, e2e |

## Protocol and input

| # | Item | Status | Covered by |
|---|---|---|---|
| 36 | Wrong-length or NaN binary frames ignored but keep the session alive | Done | `ClientMessageTests.binaryFrames`, `IntegrationTests.sessionMessages`, e2e |
| 37 | `Move` clamp to ±4000, (0,0) no event | N/A | Input engine (the core forwards the deltas unchanged) |
| 38 | Double click `clickState` 1, 2 | N/A | Input engine |
| 39 | Scroll Changed without Began; 300 ms auto-end | N/A | Input engine |
| 40 | Fling thresholds and `Touch` | N/A | Input engine |
| 41 | Key repeat timing and silence release | N/A | Input engine |
| 42 | Duplicate key down; CapsLock toggle | N/A | Input engine |
| 43 | `tap{code:300}` and `tap{mods:0x20}` ignored | Done | `IntegrationTests.sessionMessages` (filtered in the core) |
| 44 | `media volumeUp` posts NX_KEYTYPE 0 | N/A | Input engine |
| 45 | `notice permission` at most once per 4 s | N/A | Rate limit is in the input engine; the core relays the notice and `HostEvent.notice` (`RemotoHost`, no dedicated test) |
| 46 | Password field → `notice secureInput` | N/A | Detected by the input engine; relayed by the core |
| 47 | Pause: no input, running `delay` ends `ok:false`, `paused` broadcast | Done | `IntegrationTests.pauseStopsDelayAndIsBroadcast` |

## Text

| # | Item | Status | Covered by |
|---|---|---|---|
| 48 | 65537 B `text` → `notice tooLong` | Done | `IntegrationTests.sessionMessages`, e2e |
| 49 | Segmentation of `"a\r\nb\tc"` and 16-unit chunks | N/A | Input engine |
| 50 | Keystrokes mode types `A` as Shift+0x00 | N/A | Input engine |
| 51 | `edit{delete:3, insert:"x"}` | N/A | Input engine (the core clamps `delete` to 4096 and forwards) |
| 52 | Paste: `pasteBegin`, ⌘V, ~450 ms, `pasteEnd` | Done | `MoreSessionTests.pasteUsesClipboardAndCommandV` (restoring the clipboard is the app's job) |

## Deck and actions

| # | Item | Status | Covered by |
|---|---|---|---|
| 53 | `deckSave` with 9 columns → `notice deck`, unchanged; valid one broadcast and saved | Done | `DeckTests.pageAndTileLimits`, `.storeFallsBackAndPersists`, e2e |
| 54 | `#12` invalid, `#1234` valid | Done | `DeckTests.colors` |
| 55 | 4-level `sequence` or 65 steps → immediate `ok:false` | Done | `DeckTests.actionValidation`, e2e |
| 56 | No `id` + success → no `actionResult`; with `id` always | Done | e2e, `IntegrationTests.sessionMessages` |
| 57 | 33rd waiting action → `ok:false` | Done | `MoreSessionTests.thirtyThirdWaitingActionIsRefused` |
| 58 | `javascript:`/`JavaScript:`/`data:` fail; `file:` fails without shell; `https:` opens | Done | `ActionTests.urlPolicy`, e2e |
| 59 | `shell` refused when off; when on, ok at once and pause kills it (TERM, then KILL) | Done | e2e (refused), `ActionTests.shellRunsInItsOwnGroupAndIsKilledOnStop` |
| 60 | `system copy` uses the layout's `c`; `spotlight` is Cmd+Space | Done (core part) | `ActionTests.systemTable`, `IntegrationTests.sessionMessages` (the core sends `tapChar("c")`; layout lookup is in the engine) |
| 61 | `keys{code:0x100}` and `keys{mods:0x100}` invalid | Done | `DeckTests.actionValidation`, e2e |

## Per-device settings

| # | Item | Status | Covered by |
|---|---|---|---|
| 62 | `settingsSave` from a session that isn't remembered writes nothing | Done | `MoreSessionTests.settingsRulesForSessionsThatArentRemembered` |
| 63 | Not an object or > 131072 B → `notice error`; older `updatedAt` → no-op | Done | `SettingsStoreTests.saveRulesAndPurge`, e2e |
| 64 | `welcome.settings` returns the last blob | Done | `IntegrationTests.settingsComeBackInWelcome`, e2e |
| 65 | `settingsList` excludes self, newest first | Done | `MoreSessionTests.settingsRulesForSessionsThatArentRemembered` |
| 66 | `settingsCopy` not remembered / unknown source → `notice settings` | Done | `MoreSessionTests.settingsRulesForSessionsThatArentRemembered`, e2e |

## Host app

| # | Item | Status | Covered by |
|---|---|---|---|
| 67 | `appsChanged` reaches phones ≤ 0.4 s after an app change | N/A (app) | Core broadcast: `MoreSessionTests.voiceOffAndBroadcasts` |
| 68 | `appAction toggle` hides / launches | N/A (app) | Core forwards `performApp`; error notice when it returns false |
| 69 | Input source change → `layout` with 51 keys | N/A (app) | Core broadcast on `setLayout` |
| 70 | Volume change → `volume`; no volume → `volumeUnavailable` | N/A (app) | Core part: `IntegrationTests.sessionMessages` |
| 71 | Dictation phrases, `stopped`, `voiceAvailable=false` → `unavailable` | N/A (app) | Core part: `MoreSessionTests.voiceOffAndBroadcasts` |

## Web client

| # | Item | Status |
|---|---|---|
| 72–77 | Reconnect backoff, token removal, binary ordering, send rules, `#pair=` cleanup, natural scroll | N/A (web client) |

## Deviations from the SPEC (security review)

These go beyond or against the SPEC on purpose, to protect against unauthenticated clients.

| Area | SPEC | RemotoCore | Test |
|---|---|---|---|
| WebSocket frame size (§4.8, App. A) | 16 MiB | 512 KiB; larger frames are closed by the frame decoder (1009) | `HardeningTests.messageLimitsAfterHello` |
| WebSocket message size (§4.8, App. A) | 64 MiB | 8 KiB until `welcome`, then 1 MiB; above that the socket is closed with 1009 | `HardeningTests.bigMessageBeforeHelloCloses`, `.messageLimitsAfterHello` |
| HTTP pipelining | not specified | No socket reads while a request is being answered; at most 4 queued requests, counted with `served` against the 200 limit; on overflow the queued ones are answered and the socket closes | `HardeningTests.pipelinedFloodIsCutOff` |
| Requests with a body (§4.5) | 400 after the request | 400/405 as soon as the head arrives (no waiting for the body); the header timer (30 s / 10 s) runs until the whole request is in | `HardeningTests.bodiesAreRefusedAtTheHead` |
| Connections per IP (§4.2) | per IP | IPv6 grouped by /64, like the pairing limiter | `HardeningTests.connectionLimitGroupsIPv6By64` |
| CA NameConstraints (§5.2) | 8 permitted, no excluded | Same 8 permitted, plus excluded `::/0` (all IPv6) and URI `""`. No rfc822Name exclusion: swift-certificates (and possibly other verifiers) rejects any chain whose CA constrains e-mail names. OpenSSL, macOS SecTrust and curl accept the CA | `TLSTests.createsCAWithConstraintsAndLeafWithSAN` |
| `settingsList` (§14.3) | any session | Only remembered sessions; others get `notice{warning, settings}` like `settingsCopy` | `HardeningTests.settingsListNeedsARememberedSession` |
| `url` actions (§13.2) | blocks `javascript`, `data`, `file` | Also always blocks `smb`, `afp`, `nfs`, `cifs`, `ftp`, `ftps` (still a block list, so third-party app schemes work) | `ActionTests.urlPolicy` |
| `shell` (§13.2) | ends on pause/disconnect | Also ends when `allowShell` is turned off with `updateConfig` | `HardeningTests.turningShellOffEndsRunningCommands` |
| Persistence (§7.5) | atomic writes | Also `fsync` of the folder after `rename`, `0700` re-applied to existing folders, and a bad entry in `trusted.json` is skipped instead of quarantining the file | `HardeningTests.persistenceHardening` |
| Approval (§6.4) | `ApprovalRequest{id, deviceName, model, address}` | Adds `nameMatchesTrustedDevice` so the app can warn about lookalike names | `HardeningTests.approvalFlagsLookalikeNames` |

## Pending

Nothing in the core's scope. Two behaviors are implemented but have no automated test: closing a TLS connection silently when no identity exists (8), and the 120 s approval timeout (21).
