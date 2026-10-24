# Privacy

Remoto does not collect, send or share any data. There are no accounts, analytics, ads or crash reporters, and the app makes no connections to the internet.

Everything happens between your Mac and the phones you pair, on your local network:

- **On the Mac**, Remoto stores the list of paired devices (name, model, last address, and a hash of each device's token), your deck, per-device settings and its local certificate authority. They live in `~/Library/Application Support/Remoto` and you can remove them by forgetting devices in Settings or deleting that folder.
- **On the phone**, the browser keeps the device token and your local settings in its own storage for the Mac's address.
- **Typing, clipboard and dictation** go straight from the phone to the Mac and are not stored or logged. Speech recognition runs on the Mac with Apple's on-device recognizer; if a language has no on-device model, dictation is unavailable rather than sent to a server.

The permissions Remoto asks for and why:

- **Accessibility**: to move the pointer and press keys.
- **Speech recognition**: only when you dictate.
- **Automation (Apple Events)**: only when a deck button controls another app.
- **Local network**: to talk to your phone.
- **Notifications** (optional): to ask you to approve a new phone.
