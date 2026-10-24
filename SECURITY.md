# Security

Remoto lets a paired phone control your Mac, so it treats the local network as untrusted.

## Model

- Only paired devices can send input. Pairing needs something only you can see: the QR code or PIN on the Mac, or your approval on the Mac.
- QR codes are single use and expire after 10 minutes. PIN entry is only open while the PIN is on screen (and for 3 minutes after). Wrong PINs lock the sending address with growing delays (30 s doubling up to 15 min), and there is also a global limit on failures.
- Device tokens are 32 random bytes, stored only as SHA-256 hashes and compared in constant time.
- Requests must use a Host that belongs to this Mac (its `.local` name, local addresses, `localhost`); others get `421`. WebSocket upgrades must come from the same origin.
- Responses carry a strict Content-Security-Policy and the usual hardening headers.
- The local certificate authority is limited by X.509 name constraints to `.local`, `localhost` and private IPv4 ranges. Its private key never leaves the Mac and is stored with `0600` permissions.
- Shell commands and `file:` links in deck buttons are off until you turn them on in Settings.
- Logs never contain typed text, clipboard contents or tokens.

## Known limits

- **A paired phone has full control.** It can type anywhere, including Terminal, so pair only devices you own and forget the ones you no longer use. Turning shell commands off limits deck buttons, not what a paired phone can type.
- **Plain HTTP on the local network.** The QR code opens `http://`, so someone who can capture traffic on your Wi-Fi (an open network, or anyone who knows its password) could read a device token and reuse it. On networks you don't trust, install the local certificate on the phone and use the `https://` address, or don't use Remoto there.
- **PIN pairing can be held closed.** Someone on the network who keeps sending wrong PINs triggers the global limit and keeps PIN pairing locked. Pairing with the QR code is not affected by that limit.

## Reporting a vulnerability

Please do not open a public issue. Use GitHub's private vulnerability reporting on this repository (Security > Report a vulnerability). Include steps to reproduce and the version you tested. I will reply as soon as I can.
