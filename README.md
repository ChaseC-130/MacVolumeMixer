# MacVolumeMixer (App Volume Mixer)

A lightweight macOS **menu-bar app** that controls **each application's audio
independently**:

- **Per-app volume** — turn down your browser while a game stays loud; mute one app
  without touching the rest (0–200%, boost soft-clipped).
- **Per-app output device** — send one app to your speakers and another to your
  headphones at the same time.

It uses the modern Core Audio **process-tap** API (macOS 14.4+) — no kernel
extension, no virtual driver to install. Each audio-playing app is tapped and
re-rendered, scaled by its volume, into whichever output device you choose for it.

## Requirements

- macOS 14.2+ (developed/tested on macOS 26 / Apple Silicon)
- Xcode command-line tools (Swift 6 / `swiftc`)
- The **System Audio Capture** permission (the app requests it on first launch)

## Build & run

```bash
./build.sh        # compile + bundle + sign -> build/AppVolumeMixer.app
./build.sh run    # ...and launch it
```

### Package a release DMG

```bash
./package_dmg.sh                            # build/AppVolumeMixer-<ver>.dmg (drag-to-Applications)
NOTARY_PROFILE=AVM-notary ./package_dmg.sh  # ...and notarize + staple
```

Set up the notary profile once (uses an app-specific password from appleid.apple.com):

```bash
xcrun notarytool store-credentials AVM-notary --apple-id "<your-apple-id>" --team-id JS4W2TZD6H
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
  device; each graph is an aggregate device + a real-time mixing I/O proc (vDSP,
  lock-free, no ARC on the audio thread). Rebuilt when the set of audio-playing
  apps, an app's chosen device, or the default output device changes.
- `MixerManager.swift` — `@MainActor @Observable`; discovers audio-active processes
  (`kAudioProcessPropertyIsRunning`), keeps a persistent per-app volume map
  (`UserDefaults`, keyed by bundle id), and drives the engine.
- `PermissionManager.swift` — preflights/requests the TCC audio-capture permission.
- `MixerView.swift` / `VolumeMixerApp.swift` — the SwiftUI menu-bar UI; the
  `AppDelegate` owns the manager so taps persist for the app's whole lifetime.

## Notes & limitations

- Volume range is 0–200%. Boost above 100% is soft-clipped to avoid clipping noise.
- Tapped apps are muted from their normal output and re-rendered by the mixer, so a
  bug in the mixer would silence that app — failures tear the tap down to recover.
- "Integrate with the macOS Control Center panel" is **not possible** for third-party
  apps (no public API to add a Control Center module), so this ships as a menu-bar
  app — the supported equivalent.
- Ad-hoc signed for local use; each rebuild changes the code identity, so macOS may
  re-prompt for the audio permission. Reset stale state with:
  `tccutil reset SystemAudioCapture com.antigravity.AppVolumeMixer`
