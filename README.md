# cmds

Native macOS terminal workspace for coding agents (Swift + AppKit + libghostty). GPL-3.0.

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Keeping the Mac awake

While cmds runs, the Mac does not go to sleep when idle (cmds › Prevent Idle Sleep, on by default, no password).
Closing the lid still sleeps it. To keep agents running with the lid closed, choose cmds › Keep Awake With Lid
Closed…: after a warning, macOS asks for your administrator password and cmds runs `pmset -a disablesleep 1`; it
runs `pmset -a disablesleep 0` when you turn it off or quit cmds. If cmds crashes, sleep stays disabled until cmds
starts again (it offers to restore it) or you run `sudo pmset -a disablesleep 0`. Don't put a closed Mac that never
sleeps in a bag. Details: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#keeping-the-mac-awake).
