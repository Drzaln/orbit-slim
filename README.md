# OrbitSlim

**A native macOS menu bar launcher for iOS Simulators and Android emulators — built around [simslim](https://github.com/MobAI-App/simslim) and [avdslim](https://github.com/kdbhalala/avdslim).**

<p>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-black">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-orange">
  <img alt="MIT" src="https://img.shields.io/badge/license-MIT-blue">
</p>

Expo Orbit is a great menu bar launcher, but it launches Android emulators with
`@AVD` and never passes `-lowram`/`-memory`, so avdslim's host-memory savings are
skipped. It also has no concept of simslim state. OrbitSlim is a slim-native
alternative: every boot, install and slim/restore action explicitly composes the
right simslim/avdslim command.

## Features

| | iOS Simulators | Android Emulators |
|---|---|---|
| List + live state | `simctl list` | AVDs + `adb devices` |
| Boot | `simslim on <udid>` when stock, `simctl boot` otherwise | `avdslim start <avd>` (golden snapshot, `-lowram`, GPU host) |
| Slim / restore | `simslim on` / `simslim off` | `avdslim on <serial>` / `avdslim off <serial>` |
| Install & launch | `.app` → `simctl install` + `simctl launch` | `.apk` → `adb install -r` + launcher activity |
| Installed apps | user apps via `simctl listapps` | third-party packages via `pm list packages -3` |
| Uninstall | `simctl uninstall` | `adb uninstall` |
| Slim status | live CLI + persisted launchd overrides | disabled package count |

Extras:

- Drag-and-drop `.app` / `.apk` onto the Manager window.
- Per-device **Installed Apps…** sheet with confirmation before uninstall.
- Menu bar popover for quick boot/stop, plus a full Manager window.
- Settings: slim on boot, launch after install, show shutdown simulators.
- Host memory for running Android emulators (qemu RSS).
- Xcode 26/27 **DeviceHub.app** support, with `Simulator.app` fallback.
- `orbitslimctl` CLI for scripts and diagnostics.

## Requirements

- macOS 14 or newer
- Xcode with at least one simulator runtime
- Android SDK + `adb` + at least one AVD
- [simslim](https://github.com/MobAI-App/simslim) for iOS slimming
- [avdslim](https://github.com/kdbhalala/avdslim) for Android slimming

```sh
brew install mobai-app/tap/simslim
brew tap kdbhalala/avdslim https://github.com/kdbhalala/avdslim.git
brew install avdslim
```

OrbitSlim works without the slimming tools for plain boot/install/launch; slim
actions report the missing tool.

## Build & install

```sh
git clone git@github.com:Drzaln/orbit-slim.git
cd orbit-slim

make app        # build/OrbitSlim.app
make run        # build + open
make install    # copy to ~/Applications and open
```

The app is ad-hoc signed and runs unsandboxed so it can spawn `xcrun`, `simslim`,
`avdslim` and `adb`.

## Usage

1. Click the hex-grid icon in the menu bar.
2. Boot a simulator/emulator with the play button.
3. `⋯` menu per device:
   - Boot slim / boot stock
   - Slim or restore services
   - Install & launch a local file
   - Installed Apps…
   - Copy UDID / serial
4. **Open Manager** for the full window and drag-and-drop installs.

iOS boots go through `simslim on` when the simulator is not slim. Android boots
always use `avdslim start`, which applies:

- `-lowram` + `-memory` (no qemu 4 GB floor)
- `-gpu host` (Metal instead of software rasterization)
- guest debloating and `avdslim_clean` golden snapshot when present

## CLI

```sh
orbitslimctl list
orbitslimctl diag
orbitslimctl boot <udid|name|avd> [--stock]
orbitslimctl shutdown <udid|name|avd>
orbitslimctl slim <udid|name|avd>
orbitslimctl unslim <udid|name|avd>
orbitslimctl install <file.app|file.apk> [target]
orbitslimctl apps <udid|name|avd>
orbitslimctl uninstall <udid|name|avd> <bundle-id|package>
orbitslimctl package <file.apk>
orbitslimctl bundleid <file.app>
```

Binary location after `make build`:

```sh
.build/release/orbitslimctl
```

## How slim detection works

Booted simulators are queried live:

```sh
simslim status <udid> --json
```

Shutdown simulators are classified without booting them by reading the persisted
launchd override store:

```
/private/var/tmp/com.apple.CoreSimulator.SimDevice.<udid>/disabled.plist
```

Only the 168 labels simslim manages are counted. This avoids a probe boot just to
show a badge.

Android has no persisted per-AVD marker, so OrbitSlim counts disabled packages:

```sh
adb -s <serial> shell pm list packages -d
```

avdslim disables 45+ packages; stock images expose only a few.

## Logs

| What | Where |
|---|---|
| App lifecycle / refresh | `~/Library/Logs/OrbitSlim/app.log` |
| Android launch output | `~/Library/Logs/OrbitSlim/avd-<name>.log` |

## Project layout

```
Sources/OrbitSlimCore/     simctl, simslim, adb, avdslim services
Sources/OrbitSlim/         SwiftUI menu bar app + manager window
Sources/orbitslimctl/      CLI companion
Resources/Info.plist       LSUIElement menu bar app metadata
Makefile                   build / run / install
```

## Scope

v1 is local-only: no EAS build/update downloads, no Snack launch, no device
pairing. EAS/Snack support can layer on once the local workflow is stable.

## License

MIT. simslim and avdslim are separate MIT-licensed projects by their respective
authors. OrbitSlim bundles no code from Expo Orbit.
