# MacVolumeMixer (App Volume Mixer)

A lightweight macOS **menu-bar app** that controls the **output volume of individual
applications independently** — turn down your browser while a game stays loud, mute
one app without touching the rest.

It uses the modern Core Audio **process-tap** API (macOS 14.4+) — no kernel
extension, no virtual driver to install. Each audio-playing app is tapped, and a
single private aggregate device re-renders every tap into your speakers scaled by a
per-app volume.

## Requirements

- macOS 14.2+ (developed/tested on macOS 26 / Apple Silicon)
- Xcode command-line tools (Swift 6 / `swiftc`)
- The **System Audio Capture** permission (the app requests it on first launch)

## Build & run

```bash
./build.sh        # compile + bundle + sign -> build/AppVolumeMixer.app
./build.sh run    # ...and launch it
```

The app appears as a slider icon (􀟫) in the menu bar. On first launch macOS asks
for permission to record/capture system audio — **click Allow**. (This grants the
`kTCCServiceAudioCapture` permission the tap API requires.)

If you previously denied it, re-enable under **System Settings → Privacy &
Security → Audio**, or use the in-app button.

## How it works

```
default output device ─┐
                       ├── ONE private aggregate device ──> ONE AudioDeviceIOProc
app A ──(stereo tap)───┤                                     mixes each tap * volume
app B ──(stereo tap)───┘                                     -> output (clamped)
```

- `AudioMixerEngine.swift` — owns the single aggregate device + the real-time
  mixing I/O proc (vDSP, lock-free, no ARC on the audio thread). Rebuilt only when
  the set of audio-playing apps changes or the default output device changes.
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
