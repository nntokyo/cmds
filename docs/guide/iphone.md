# iPhone and iPad companion

> Pairing the iOS/iPadOS companion with the Mac, what it shows, the three ways it connects (local network, Bluetooth,
> SSH relay) and how to fix connection problems.

The companion mirrors the Mac's workspaces and terminal screens, lets you type into panes, and posts a notification
when a pane needs attention. Everything travels in a TLS 1.3 session pinned to your Mac's own certificate, whichever
path it takes ([internals/sync-protocol.md](../internals/sync-protocol.md)).

## Requirements

- iPhone or iPad with iOS/iPadOS 17 or later. The app is not on the App Store; build and install it from source
  (scheme `CmdsCompanion`, see the [README](../../README.md#build-from-source)).
- The Mac app with **cmds › Enable iOS Sync** on (the default). The Mac listens on port 47823 (or a free port if that
  one is taken) and advertises itself with Bonjour.
- For the first pairing, the phone and the Mac must reach each other directly (same network, or Bluetooth).

## Pairing

On the Mac choose **cmds › Pair iPhone/iPad…**. The window shows a QR code, a 6-digit code, the Mac's identity (a
short fingerprint like `A1B2-C3D4-E5F6`) and the paired devices. The code works only while this window is open; it
changes every 10 minutes, after each pairing and after 5 wrong tries.

### With the camera (recommended)

On the phone tap **Scan Pairing Code** and scan the QR code. The phone pins the Mac's full certificate fingerprint
from the code before it sends anything, connects and pairs. Close the pairing window afterwards.

### Without the camera

1. On the phone, pick the Mac under **On this network**, or enter its address under **Manual** (`host` or
   `host:port`).
2. Tap **Pair Without Camera**. The phone shows the identity the Mac presented; compare it with "Mac identity" in the
   pairing window and tap **It Matches** only if it is exactly the same.
3. Enter the 6-digit code.

The comparison checks 48 bits of the fingerprint, the QR code all 256; prefer the QR code on networks you do not
trust ([why](../internals/sync-protocol.md#not-protected)).

### Managing paired devices

- Mac, pairing window: **Revoke All Devices…** disconnects and unpairs every phone; **Reset Sync Identity…** creates a
  new certificate (every phone must pair again); **New Code** rotates the code.
- Phone, ⋯ menu of a Mac: **Unpair This Mac**, **Switch Mac…**, **Remote Access via SSH…**.

If a phone is lost, revoke it on the Mac: a paired phone can type into every terminal.

## What the companion shows

- **Workspaces**: the same list as the Mac's sidebar with directory, branch, attention, CPU and memory, and the coding
  agent of each workspace. The bottom bar shows the Mac's CPU, memory and memory pressure and each agent's account
  limits. **Show on Mac** selects the workspace on the Mac.
- **Panes**: each terminal's live screen (no scrollback), with pinch to zoom; it follows the cursor row. The key bar
  has esc, tab, a ctrl latch, arrows, home/end, ^C, ^D, delete and return. Two input modes: *Direct* sends every
  keystroke at once; *Line* lets you compose a line and send it with return (or **Send without Enter**). An iPad with a
  hardware keyboard types straight into the pane. **Focus Pane on Mac** focuses it on the Mac.
- **Preview panes**: images (with zoom) and PDFs are fetched from the Mac (up to 10 MB); other files show their name
  and **Open on Mac**.
- **Notifications**: when a pane lights up on the Mac (agent waiting, finished, OSC 9/777, bell, `cmds notify`), the
  phone posts a notification while the app is connected.
- **Try with demo data** on the connect screen runs the app without a Mac.

## How it connects

The phone tries the paths below and keeps the first one whose TLS handshake matches the pinned identity. The status
badge shows which one is in use.

### Local network

Wi‑Fi or Ethernet: the phone finds the Mac by Bonjour (`_cmds._tcp`), or uses the address you entered. Both sides
allow Apple's peer-to-peer Wi‑Fi (AWDL), so a Mac and phone with Wi‑Fi on can also connect when they are not on the
same access point. iOS asks once for **Local Network** access.

### Bluetooth

When the Mac cannot be reached over IP (for example Wi‑Fi is off) the phone connects over Bluetooth LE after 3 s.
On the Mac, **cmds › Allow Bluetooth Sync** must be on (the default) and cmds must be allowed to use Bluetooth; the
phone asks for Bluetooth access the first time. There is no Bluetooth pairing prompt: the same pinned TLS session runs
over the Bluetooth link. Screens update up to 4 times a second, and only while the app is in the foreground.

### Remote access via SSH (away from home)

Away from your network, the phone can reach the Mac through an SSH server you already use (the *relay host*). The
Mac keeps an `ssh -R` forward to the relay; the phone logs in to the relay with its own key and connects to that
forward. The relay only passes encrypted bytes. Pair on the local network first: pairing codes are refused over SSH.

1. **Mac**: **cmds › Remote Access via SSH…** → turn on **Allow remote access via SSH**, enter the relay host (a `Host`
   alias from `~/.ssh/config` or `user@host`) and a relay port (1024–65535, default 47824), **Apply**. The Mac's
   `ssh` uses your keys and `known_hosts` and never prompts, so connect to the relay once in a terminal first.
2. **Phone**: ⋯ › **Remote Access via SSH…** for that Mac → relay host, SSH port, user and the same relay port.
3. Copy the line shown under **This Device's Key** into `~/.ssh/authorized_keys` of that user on the relay. It only
   allows forwarding to the relay port (no shell); the private key never leaves the phone.
4. **Check Connection**, compare the relay's host key fingerprint with
   `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` on the relay, and tap **It Matches — Trust This Host**.

The phone then uses SSH when the local network and Bluetooth fail (or at once when it has no Wi‑Fi). The relay needs
OpenSSH with TCP forwarding allowed: [relay host requirements](../internals/sync-protocol.md#remote-access-via-ssh).

## Troubleshooting

| Symptom | What to check |
|---|---|
| "Connecting…" forever, or "The Mac did not answer" | The Mac's firewall (System Settings › Network › Firewall) must allow incoming connections for cmds. macOS asks once per app signature: a rebuilt app signed differently (or moved) may be blocked again until you allow it. Also check that cmds runs and **Enable iOS Sync** is on. |
| The Mac does not appear under "On this network" | On the phone: Settings › Privacy & Security › Local Network › cmds. Bonjour does not cross routers or guest-network isolation; enter the address under **Manual** instead. |
| Works at home but not with a VPN on | A VPN that routes all traffic (on the phone or the Mac) can hide the local network. Allow local network access in the VPN app or turn it off for pairing; Bluetooth and remote access via SSH still work. |
| "This Mac's identity changed — re-pair" | The Mac's sync identity was reset (or something else answered at its address). The phone never connects to a different identity; scan the new QR code. |
| Pairing code rejected | The pairing window must be open; the code changes every 10 minutes and after use. After 5 wrong tries the phone is locked out for 5 minutes. |
| No Bluetooth fallback | **Allow Bluetooth Sync** on the Mac; Bluetooth permission for cmds on both devices (Mac: System Settings › Privacy & Security › Bluetooth). `cmds sync` shows `authorization` and `advertising`. |
| Remote access fails | `cmds sync` (line `ssh relay`) and the status in **cmds › Remote Access via SSH…** show the Mac's side; **Check Connection** on the phone shows whether the relay login and the Mac's forward work. |

`cmds sync` prints the Mac's view: listener, Bonjour, Bluetooth, SSH relay and every connected phone with its path.
Deeper diagnostics: [internals/testing.md](../internals/testing.md#testing-sync-on-a-device).
