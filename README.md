[English](README.md) · [简体中文](README.zh-CN.md)

<p align="center">
  <img src="Resources/app_icon.png" width="128" height="128" alt="CellDock icon">
</p>

<h1 align="center">CellDock</h1>

Local automation: the optional [local call API](docs/LOCAL_CALL_API.md) lets
programs on this Mac query status, dial, answer, and hang up using CellDock's
existing call and audio pipeline. It is disabled by default and requires a token.

<p align="center">
  Use cellular network, SMS, and calls on your Mac.
</p>

<p align="center">
  <sub>Screenshots · click to view full size</sub>
</p>

| SMS | Calls |
| :---: | :---: |
| <a href="screenshot/1. sms.png"><img src="screenshot/1. sms.png" width="320" alt="SMS"></a> | <a href="screenshot/2. call.png"><img src="screenshot/2. call.png" width="320" alt="Calls"></a> |

| In-Call | In-Call |
| :---: | :---: |
| <a href="screenshot/2.1 calling.png"><img src="screenshot/2.1 calling.png" width="320" alt="In-Call"></a> | <a href="screenshot/2.2 calling.png"><img src="screenshot/2.2 calling.png" width="320" alt="In-Call"></a> |

| Recordings | Proxy |
| :---: | :---: |
| <a href="screenshot/3.records.png"><img src="screenshot/3.records.png" width="320" alt="Recordings"></a> | <a href="screenshot/4. proxy.png"><img src="screenshot/4. proxy.png" width="320" alt="Proxy"></a> |

| Device | Settings |
| :---: | :---: |
| <a href="screenshot/5. device.png"><img src="screenshot/5. device.png" width="320" alt="Device"></a> | <a href="screenshot/6. settings.png"><img src="screenshot/6. settings.png" width="320" alt="Settings"></a> |

| SMS Forwarding |
| :---: |
| <a href="screenshot/7. forwarding.png"><img src="screenshot/7. forwarding.png" width="320" alt="SMS Forwarding"></a> |

CellDock is a native macOS menu bar app that works with the QDC507 cellular module.
Plug in the module and you can use the cellular network directly on your Mac — send and
receive SMS, manage contacts, make calls, save call recordings, or share a module's
cellular connection as a SOCKS5 proxy — no browser-based service or extra communication
software required.

## Features

### Multi-Module & Cellular Network

- Discovers and monitors multiple supported USB cellular modules at the same time.
- Choose a separate module for calls and for data; only one module serves as the system's
  cellular-first egress at a time.
- Set each module to **Cellular First**, **Keep Connected**, or **Off**. Modules kept
  connected remain usable by bound SOCKS5 proxies but are not used as macOS's default
  network egress.
- Enabling automatically gives cellular priority over Wi-Fi.
- Disabling restores the previous network order without affecting SMS or incoming calls.
- Each module remembers its cellular switch state; reconnecting a module restores its
  previous choice.
- Bounded automatic recovery when the ECM link, DHCP, or module restart misbehaves.
- Live display of carrier, network mode, signal strength, IP address, and connection stage.
- Optional real-time download/upload speeds in the menu bar (fixed width, two lines),
  off by default.

### SOCKS5 Proxy

- Create a separate SOCKS5 proxy per module so apps or LAN devices can select a specific
  cellular egress.
- Listen on localhost only or on the LAN; ports are auto-assigned from `1080` and can be
  changed.
- Supports no-auth and username/password authentication; LAN listeners require authentication.
- Each proxy starts and stops independently and reports connection count and status such as
  module offline, cellular off, link down, or port in use.
- Proxies bind to a stable module identity and re-resolve the network interface after the
  module is reinserted. Auth passwords are stored in the macOS Keychain.

> A LAN proxy exposes the cellular egress to other devices on the same network. Use a
> strong password and make sure your firewall and network are trustworthy.

### SMS

- Receive SMS in the background with macOS notifications.
- View full threads by conversation; copy text, reply, or compose new messages.
- Send Chinese text and long (concatenated) messages.
- Auto-detects verification codes; click to copy and mark as read.
- Messages are tagged with their source module; choose which available module sends each
  message.
- Deleted messages no longer appear in CellDock; if a message is still stored on the module,
  CellDock also tries to clear it.
- Optionally auto-delete verification-code messages 30 minutes after they are read.
- Forward incoming SMS to Bark, a Feishu custom bot, or a DingTalk custom bot (Settings →
  Cellular & Communications → SMS Forwarding), with per-channel enable toggles and a
  "Send Test" button. Endpoints and signing secrets are stored in the macOS Keychain.

### Calls & Recording

- Dial, answer, reject, mute, and hang up.
- Incoming calls show a notification and floating window with Answer and Decline buttons.
- In-call keypad for navigating automated phone menus.
- Use your Mac's microphone and speakers for calls.
- Keeps recent and missed calls, noting which module was used.
- Manual and user-confirmed automatic recording captures both parties and saves as M4A.
- The recording library offers waveforms, playback, seeking, speed control, volume, rename,
  export, and Reveal in Finder.

> Before recording a call, get consent from all participants and follow local laws.

### SIM, eSIM & Contacts

- View SIM status, ICCID, IMSI, own number, carrier, network mode, and signal information.
- Configure per module whether it accepts incoming calls; operations that require a module
  restart are clearly flagged.
- Auto-detects physical SIM and eUICC.
- On supported eUICCs, view the EID and profiles; download, enable, disable, rename, or
  delete eSIM profiles.
- Reads the macOS Contacts database to match names on SMS and calls.
- Create, edit, delete contacts and manage contact groups in CellDock.

### Menu Bar, Sound & Interface

- Hot-plug modules without restarting the app.
- The menu bar icon shows calls, missed calls, unread SMS, the current data module, or
  callable-module status.
- The menu bar panel lists unread SMS and missed calls per module and automatically hides
  empty sections.
- Customizable SMS sound and ringtone; defaults are `bleeps.wav` and `ring.mp3`.
- Simplified Chinese, English, 日本語, and Français, switchable instantly in Settings.
- Follows system, light, and dark themes.
- Presentation privacy mode hides contacts, numbers, message bodies, verification codes,
  and recording titles.
- Open a standard main window; closing it keeps the app running in the menu bar.
- Optionally hide the menu bar icon when no module is connected.
- Optionally launch at login, off by default.
- Built-in stable and beta update channels with automatic or manual update checks.

## Acknowledgments

Special thanks to the [moluncn/mavo](https://github.com/moluncn/mavo) project. CellDock
draws on mavo for its interface and feature design; we are grateful for the original
author's open-source work.

## Disclaimer

- CellDock is provided "as is", without any express or implied warranty. The author makes
  no guarantees about its suitability or performance for any particular purpose.
- The app modifies macOS network configuration (for example, making cellular the priority
  egress and installing a network helper), which may affect existing network connections.
  Make sure you understand these features before use.
- The availability of cellular data, SMS, calls, and eSIM features depends on module
  firmware, SIM card, carrier, and local network conditions. The author does not guarantee
  their availability or performance in every environment.
- Sharing a cellular connection to LAN devices through the SOCKS5 proxy exposes that egress
  to other devices on the same network. Assess the security risks yourself and configure
  authentication properly.
- Get consent from call participants before recording and follow local laws; also follow
  your carrier's terms of service when using features such as connection sharing.
- The author is not liable for any direct or indirect loss caused by using or being unable
  to use this software.

## License

CellDock's application code is licensed under a [non-commercial license](LICENSE): free to
use, modify, and distribute for personal and non-commercial purposes. **Any form of
commercial use is prohibited**; commercial use requires separate written authorization from
the author. Third-party components and their licenses are listed in
[THIRD_PARTY_NOTICES.md](docs/THIRD_PARTY_NOTICES.md).
