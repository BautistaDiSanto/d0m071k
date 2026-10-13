# Domotic

Controls Tuya / Smart Life bulbs from your computer over your home Wi-Fi.
Pure Godot 4.3+: no Python, no cloud while it runs.

## Setup (once)

1. Get your bulb's **id** and **local_key** from https://platform.tuya.com:
   Cloud > API Explorer > Device Management > Query Device Details, enter the device id,
   copy `local_key` from the result.
2. Copy `lights.example.cfg` to `lights.cfg` in this folder and fill them in:
   ```
   [Bulb]
   id = "your device id"
   local_key = "your local key"
   ```
   Rename `[Bulb]` to whatever you want it called. Add another section per extra bulb.
3. Open the project in Godot and press Play. The first time, Windows asks whether Godot may
   use the network: allow it on **Private networks**, or the app can't find the bulb.

The app finds the bulb's IP address and protocol version by itself. If it can't, add
`ip = "192.168.x.x"` (from your router's device list) to the bulb's section.

## Exported app

The export packs your `lights.cfg` into `Domotic.exe` (Project > Export > Resources lists
it under "Filters to export non-resource files"), so the .exe holds your keys: don't share it.
The first launch asks for network access again (this time for
`Domotic.exe`): allow it on **Private networks**.

`lights.cfg` holds your bulb's key: don't share it or commit it to a public repo.
If you remove and re-add the bulb in Smart Life its key changes; fetch it again.

## Running in the background

Closing the window doesn't quit the app: it keeps running with a bulb icon in the
notification area (next to the clock; Windows may tuck it under the ^ arrow, drag it out
to keep it visible). Click the icon to reopen the window; right-click it and pick **Quit**
to really close it. When run from the editor with the game embedded, closing quits as usual.
