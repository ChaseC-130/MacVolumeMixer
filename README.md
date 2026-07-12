# MacVolumeMixer (App Volume Mixer)

A lightweight macOS **menu-bar app** that controls **each application's audio
independently**:

- **Per-app volume** — turn down your browser while a game stays loud; mute one app
  without touching the rest (0–200%, boost soft-clipped).
- **Per-app output device** — send one app to your speakers and another to your
  headphones at the same time.

It uses the modern Core Audio **process-tap** API (macOS 14.2+) — no kernel
extension, no virtual driver to install. Each audio-playing app is tapped and
re-rendered, scaled by its volume, into whichever output device you choose for it.

## Requirements

- macOS 14.2+ (developed/tested on macOS 26)
- Xcode command-line tools (Swift 6 / `swiftc`)
- The **System Audio Capture** permission (the app requests it on first launch)

## Build & run

```bash
./build.sh        # compile + bundle + sign -> build/AppVolumeMixer.app
./build.sh run    # ...and launch it
./test.sh         # offline DSP/layout regression suite
```

Release builds are universal (Apple Silicon + Intel). For a faster local build,
use `ARCHS=arm64 ./build.sh`.

### Package a release DMG

```bash
./package_dmg.sh                            # build/AppVolumeMixer-<ver>.dmg (drag-to-Applications)
NOTARY_PROFILE=AVM-notary ./package_dmg.sh  # ...and notarize + staple
```

Set up the notary profile once (uses an app-specific password from appleid.apple.com):

```bash
xcrun notarytool store-credentials AVM-notary --apple-id "<your-apple-id>" --team-id "<your-team-id>"
```

### Install (from a release DMG)

Open the `.dmg`, drag **App Volume Mixer** onto **Applications**, then launch it. If
the build isn't notarized, right-click the app → **Open** the first time (or allow it
under System Settings → Privacy & Security).

The app appears as a slider icon (􀟫) in the menu bar. On first launch macOS asks
for permission to record/capture system audio — **click Allow**. (This grants the
`kTCCServiceAudioCapture` permission the tap API requires.)

If you previously denied it, re-enable under **System Settings → Privacy &
Security → Audio**, or use the in-app button.

## How it works

Apps are grouped by their chosen output device; each device gets its own private
aggregate device + mixing I/O proc. (Different devices → independent graphs, so
they never contend for the same hardware.)

```
Speakers ◀── aggregate(Speakers) ◀── IOProc ◀── tap A (vol), tap C (vol)
AirPods  ◀── aggregate(AirPods)  ◀── IOProc ◀── tap B (vol)
```

- `AudioMixerEngine.swift` — coordinates one `DeviceGraph` per target output
  device. It reads back the HAL-assigned tap UID, validates every tap/aggregate
  stream as native Float32 PCM, and uses maximum-quality drift compensation.
  Only the route whose membership changed is rebuilt; unaffected outputs keep
  running.
- `AudioRenderKernel.swift` — allocation-free real-time mixing, buffer-layout
  handling (interleaved or planar), one-buffer gain ramps that prevent clicks,
  and a transparent-knee soft limiter for boosted or summed peaks.
- `MixerManager.swift` — `@MainActor @Observable`; discovers audio-active processes
  with active output streams (`kAudioProcessPropertyIsRunningOutput`), groups an
  app's helper processes into one control, persists preferences by bundle ID,
  and keeps taps alive across ordinary playback pauses to avoid graph churn.
- `PermissionManager.swift` — preflights/requests the TCC audio-capture permission.
- `MixerView.swift` / `VolumeMixerApp.swift` — the SwiftUI menu-bar UI; the
  `AppDelegate` owns the manager so taps persist for the app's whole lifetime.
  Route failures and Core Audio processor overloads are surfaced in the UI.

## Notes & limitations

- Volume range is 0–200%. Audio below the limiter knee is unchanged; peaks that
  would exceed full scale are smoothly limited. Boost necessarily reduces peak
  headroom, so 100% is the fidelity-neutral setting.
- Tapped apps are muted from their normal output and re-rendered by the mixer, so a
  bug in the mixer would silence that app — failures tear the tap down to recover.
- Input-only audio clients are ignored. Apps remain in the mixer until their Core
  Audio process object disappears, which prevents dropouts between tracks and
  short sounds.
- Virtual loopback/mixer devices are intentionally excluded as destinations;
  routing one mixer into another can recurse or deadlock the Core Audio HAL.
  Hardware, USB, Bluetooth, HDMI, AirPlay, and user aggregate outputs remain
  selectable.
- "Integrate with the macOS Control Center panel" is **not possible** for third-party
  apps (no public API to add a Control Center module), so this ships as a menu-bar
  app — the supported equivalent.
- Ad-hoc signed for local use; each rebuild changes the code identity, so macOS may
  re-prompt for the audio permission. Reset stale state with:
  `tccutil reset SystemAudioCapture com.antigravity.AppVolumeMixer`
