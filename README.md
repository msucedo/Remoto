# Remoto

Remoto via your iPhone allows you to use it as a trackpad, keyboard, button deck, media remote and dictation mic for your Mac. It runs in the menu bar and talks to your phone over your local network. There is nothing to install on the phone: it opens a web page served by the Mac.

## What it does

- **Trackpad**: move, click, drag, two-finger scroll with inertia, right click.
- **Keyboard**: a Mac keyboard that follows the layout your Mac is using, a text composer for longer typing, and keyboards you design yourself.
- **Deck**: pages of buttons that run shortcuts, type text, open apps or links, control media, run Shortcuts, or chain several steps.
- **Media and volume**: play, pause, skip and the system volume.
- **Apps**: see what is running and switch, hide or quit apps.
- **Dictation**: speak into the phone and the text is typed on the Mac. Speech recognition runs on the Mac.

## Install

1. Download the latest `Remoto-<version>.dmg` from [Releases](https://github.com/msucedo/remoto/releases), open it and drag Remoto to Applications.
2. Open Remoto. It lives in the menu bar.
3. Allow Accessibility when asked (System Settings > Privacy & Security > Accessibility). macOS requires it for any app that moves the pointer or types.
4. Scan the QR code with your phone, or open the address shown and enter the PIN.

Requires macOS 14 or later. The phone needs a recent browser and the same Wi-Fi network as the Mac.

## How pairing and security work

- The phone pairs once, with the QR code, a 6 digit PIN, or by asking you to approve it on the Mac. After that it reconnects with a token.
- QR codes are single use and expire after 10 minutes. Wrong PINs lock out the address that sent them, with growing delays.
- Tokens are random 32 byte values. The Mac stores only their SHA-256 hash. You can see and forget paired devices in Settings.
- The server only answers requests addressed to this Mac's local names and addresses, which blocks DNS rebinding. WebSocket connections from other web origins are rejected.
- HTTPS is available on the same port with a certificate from a local authority that Remoto creates. That authority is name constrained to `.local` names and private addresses, so it cannot vouch for any site on the internet. Install it on the phone only if you need HTTPS (dictation needs it on most browsers).
- Shell commands in deck buttons are off by default.

More detail in [SECURITY.md](SECURITY.md) and [PRIVACY.md](PRIVACY.md).

## Build from source

You need Xcode 26 (Swift 6.2) and Node 22.

```sh
scripts/build.sh            # builds web/, the Swift app, and build/Remoto.app
open build/Remoto.app
```

Other useful commands:

```sh
swift test                  # core and input engine tests
cd web && npm test          # phone client tests
swift run remoto-dev --web web/dist --approve   # the server in a terminal, input only logged
node tools/ws-e2e.mjs       # protocol end to end tests against remoto-dev
```

`build.sh` signs with your "Apple Development" identity if you have one. With ad-hoc signing macOS forgets the Accessibility permission on every rebuild. `scripts/package.sh` makes the notarized DMG and needs a Developer ID.

## Project layout

| Path | What it is |
|---|---|
| `Sources/RemotoCore` | The server: HTTP and WebSocket (SwiftNIO), TLS, pairing, protocol, deck, actions |
| `Sources/RemotoInput` | The input engine that posts pointer and keyboard events |
| `Sources/Remoto` | The SwiftUI menu bar app |
| `Sources/remoto-dev` | Runs the server in a terminal for development |
| `web/` | The phone client (TypeScript, Vite) |
| `docs/` | Behavior spec (`SPEC.md`, in Spanish; code comments cite its sections), core API, design guide, conformance notes |

## License

MIT. See [LICENSE](LICENSE). Icons in the phone client come from [Lucide](https://lucide.dev) (ISC).
