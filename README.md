# macos-multiple-display-tools

Control an external monitor's brightness on macOS — and make it follow the Mac's
built-in display — with a menu bar app and a CLI. The app also shows the opening
angle of your MacBook lid.

Built because macOS exposes no brightness control for third-party monitors, and
F1/F2 only works on the built-in display (or on Apple displays).

```
macos-multiple-display-tools
├── MonitorBar.app   menu bar app that keeps the brightness in sync
└── monitor / brightness / contrast / monitor-info   DDC/CI CLI
```

## How it works

- **External monitor brightness:** [DDC/CI](https://en.wikipedia.org/wiki/Display_Data_Channel)
  through [m1ddc](https://github.com/waydabber/m1ddc), which uses `IOAVService` on Apple Silicon.
  It controls the real backlight, not a software dimming overlay.
- **Built-in display brightness:** the private `DisplayServicesGetBrightness` /
  `DisplayServicesSetBrightness` API
  (`/System/Library/PrivateFrameworks/DisplayServices.framework`), the same one
  Control Center uses. Loaded with `dlopen`, no entitlements.
- **Physical port:** read from `ioreg` (`IOPortTransportStateDisplayPort`) and
  mapped to the actual port position (`port-location` on the `hpm` nodes).
- **Lid angle:** Hall sensor in the hinge, exposed as HID (`usage page 0x20`,
  `usage 0x8A`, feature report 1). The first two bytes are the angle in degrees.

## Requirements

- Apple Silicon (built and tested on M4; should work on M1/M2/M3)
- macOS 12+
- [m1ddc](https://github.com/waydabber/m1ddc): `brew install m1ddc`
- Swift/Command Line Tools to build the app: `xcode-select --install`
- A monitor that supports DDC/CI (most desktop monitors do; cheap portable
  monitors sometimes don't)

## One-shot setup

```bash
git clone <this-repo> macos-multiple-display-tools
cd macos-multiple-display-tools
./setup.sh
```

It checks and installs everything in order:

| Step | What it does |
|---|---|
| 1 | checks macOS and CPU architecture |
| 2 | installs the Command Line Tools if `swiftc` is missing (opens the macOS dialog) |
| 3 | installs Homebrew if missing (asks first) |
| 4 | installs `m1ddc` if missing |
| 5 | runs `install.sh` (CLI symlinks, app build, LaunchAgent) |

`./setup.sh -y` skips the prompts. It is idempotent: running it again only
rebuilds and reloads what is already there.

## Manual install

```bash
git clone <this-repo> macos-multiple-display-tools
cd macos-multiple-display-tools
./install.sh
```

`install.sh` will:

1. create symlinks in `~/.local/bin` (`monitor`, `brightness`, `contrast`,
   `monitor-info`, plus the `brilho`/`contraste` aliases);
2. build and install `MonitorBar.app` in `~/Applications`;
3. register a LaunchAgent (`com.paulonahes.monitorbar`) to start it at login.

If `~/.local/bin` is not in your `PATH`, the script tells you. To uninstall:

```bash
./uninstall.sh
```

## CLI

```bash
brightness             # print current brightness (0-100)
brightness 60          # set 60%
brightness +10         # increase by 10 points
brightness -10         # decrease by 10 points
brightness max         # 100

contrast 75
monitor volume 40
monitor info           # displays, physical port, link and current values
monitor list           # displays as seen by m1ddc
```

Sample `monitor info`:

```
Displays:
  [1] Unknown Display (37D8832A-...)
  [2] ARZOPA (7EC3C4DC-...)

Monitor:    ARZOPA
Connection: USB-C 2 (left, rear)
Link:       2.7 Gbps (HBR), 4 lanes

Brightness: 100
Contrast: 50
Volume: 50
```

Commands print just the number, so they are script-friendly:

```bash
if [ "$(brightness)" -lt 30 ]; then brightness 30; fi
```

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `MONITOR_NAME` | `ARZOPA` | name fragment of the display in the m1ddc list |
| `MONITOR_ID` | — | fixed display index; ignores the name |
| `M1DDC_BIN` | `m1ddc` in PATH | path to the m1ddc binary |
| `MONITORBAR_DEBUG` | — | `1` makes the app log brightness and angle to stderr |

## MonitorBar (menu bar)

Sun icon in the menu bar. The menu adapts to the sync state:

**Sync on** — one slider, `Mac brightness`, that moves the built-in display and
makes the external monitor follow.

**Sync off** — one slider per connected display (`Built-in display`, `ARZOPA`,
...), each controlling only its own brightness. Displays that don't answer a DDC
read get no slider.

The rest of the menu:

- **Follow Mac brightness** — turns sync on/off (persisted)
- **Sync now** — forces a sync (only enabled with sync on)
- **Monitor: ARZOPA (2)** — display in use
- **Lid: 112°** — lid opening angle, live
- **Show angle in menu bar** — shows the angle next to the icon (persisted)

With sync on, **F1/F2 and Control Center control both monitors at once**,
including automatic ambient-light changes. Just use the Mac normally.

Implementation details:

- reads the internal brightness every 0.4 s;
- rebuilds the menu on every open, so the display list and values are current;
- waits 150 ms for stability before writing (an F1/F2 ramp changes the value
  several times per second, and one write per step saturates the DDC bus);
- only writes when the difference is ≥ 1%;
- reads the lid angle on the same interval, straight from the sensor's feature
  report.

The angle shows up as `Lid: 112°` in the menu. If the model has no sensor (Mac
mini, Studio, iMac), the item says "sensor unavailable" and everything else keeps
working.

### Keyboard shortcuts

Not required, but if you want dedicated keys for the external monitor:

```bash
# skhd (~/.config/skhd/skhdrc)
cmd + alt - down : brightness -10
cmd + alt - up   : brightness +10
```

In Raycast/Karabiner, use the same commands.

## Finding the monitor's port

macOS shows this nowhere. The CLI reads it from `ioreg`:

```bash
ioreg -r -c IOPortTransportStateDisplayPort -l | grep -E "TransportDescription|Active|LinkRate"
```

Output on a 14" MacBook Pro (the internal numbering does not follow the visual
order):

```
"TransportDescription" = "Port-HDMI@3/DisplayPort"      "Active" = No
"TransportDescription" = "Port-USB-C@2/DisplayPort"     "Active" = Yes   2.7 Gbps (HBR)
```

`port-label` cross-references `Port-USB-C@N` with the `port-location` of the
`hpmN` node:

| Port | `port-location` | `port-number` |
|---|---|---|
| USB-C 1 | `left-front` | 1 |
| USB-C 2 | `left-rear` | 2 |
| USB-C 4 | `right` | 4 |

This is MacBook-specific; on a Mac mini/Studio the map may not exist and the CLI
just prints `USB-C N`.

## Limitations

- The monitor must support DDC/CI. If `brightness` fails, try `contrast`: some
  monitors answer one but not the other.
- USB-C hubs and docks sometimes block DDC. A direct cable is more reliable.
- `DisplayServices` is a private API: macOS updates can break it. If the menu
  shows "Mac brightness: API unavailable", that's what happened.
- With sync on, changes made through the CLI (`brightness 80`) are overwritten on
  the next change of the Mac's brightness. For independent control, turn off
  "Follow Mac brightness" in the menu.
- macOS auto-brightness (ambient light sensor) stays active and makes small
  adjustments; sync reproduces them on the external monitor.
- The lid angle only exists on MacBooks with the sensor (M1 and later; some
  2019/2020 Intel models too). There is no public API: it's undocumented HID, so
  future models may differ.

## Troubleshooting

**`monitor: no display named "ARZOPA"`**
Run `monitor list` and adjust `MONITOR_NAME`, or pass the index:
`MONITOR_ID=2 brightness 50`.

**The display disappears from the m1ddc list**
Unplug and replug the cable. The index can change — MonitorBar re-resolves it
every 5 s.

**DDC does not respond**
Try a cable straight into the Mac's USB-C/HDMI port, without a hub. Confirm the
monitor accepts DDC (some require enabling it in the OSD).

**The icon does not appear in the menu bar**
`pgrep -fl MonitorBar` to check it is running, and
`launchctl print gui/$(id -u)/com.paulonahes.monitorbar` for the agent state.
Logs in `~/Library/Logs/MonitorBar.log`.

## Tested on

- MacBook Pro 14" (Mac16,1, Apple M4), macOS 26.6.2
- ARZOPA 16" (2560x1600, EDID `GWD`), USB-C → DisplayPort Alt Mode, 4 lanes HBR
- Lid angle: HID sensor present, stable readings in whole degrees (0-180)

It works with other monitors; `MONITOR_NAME` is what changes.

## Layout

```
bin/monitor      CLI (one script, several names)
app/main.swift   menu bar app
app/Info.plist   bundle (LSUIElement)
app/build.sh     builds with swiftc, no Xcode
setup.sh         one-shot setup (dependencies + install.sh)
install.sh       CLI + app + LaunchAgent
uninstall.sh     removes everything
```

## License

MIT.
