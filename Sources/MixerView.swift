import SwiftUI

struct MixerView: View {
    let manager: MixerManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.15)

            switch manager.permission {
            case .authorized:
                appList
            case .denied:
                permissionPanel(
                    title: "Audio Access Denied",
                    message: "Enable “App Volume Mixer” under Privacy & Security → Audio so it can adjust app volumes.",
                    primary: ("Open System Settings", openAudioSettings)
                )
            case .unknown:
                permissionPanel(
                    title: "Permission Needed",
                    message: "App Volume Mixer needs permission to capture system audio so it can control each app's volume.",
                    primary: ("Enable Audio Access", manager.requestPermission)
                )
            }

            Divider().opacity(0.15)
            footer
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("App Volume Mixer")
                .font(.headline).fontWeight(.bold)
                .foregroundStyle(.linearGradient(colors: [.cyan, .purple], startPoint: .leading, endPoint: .trailing))
            Spacer()
            Button(action: manager.refresh) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Refresh app list")
        }
        .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 12)
    }

    // MARK: - App list

    private var appList: some View {
        ScrollView {
            VStack(spacing: 12) {
                if manager.activeMixers.isEmpty {
                    emptyState
                } else {
                    ForEach(manager.activeMixers) { entry in
                        AppVolumeRow(
                            entry: entry,
                            maxVolume: manager.maxVolume,
                            devices: manager.availableOutputDevices,
                            onVolumeChange: { manager.setVolume(for: entry.id, to: $0) },
                            onMuteToggle: { manager.toggleMute(for: entry.id) },
                            onDeviceChange: { manager.setOutputDevice(for: entry.id, uid: $0) }
                        )
                    }
                }
            }
            .padding(12)
        }
        .frame(minHeight: 150, maxHeight: 320)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 24)).foregroundColor(.secondary).padding(.top, 24)
            Text("No Active Audio Apps")
                .font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            Text("Apps currently playing audio appear here.")
                .font(.system(size: 9)).foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center).padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    // MARK: - Permission panel

    private func permissionPanel(title: String, message: String, primary: (String, () -> Void)) -> some View {
        VStack(spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill").foregroundColor(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).fontWeight(.semibold).font(.caption)
                    Text(message).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
            Button(primary.0, action: primary.1)
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 140)
    }

    private func openAudioSettings() {
        // Privacy & Security → Audio (System Audio Capture) pane.
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text("\(manager.activeMixers.count) app\(manager.activeMixers.count == 1 ? "" : "s")")
                .font(.system(size: 10)).foregroundColor(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.bordered).controlSize(.small)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct AppVolumeRow: View {
    let entry: MixerManager.AppMixerEntry
    let maxVolume: Float
    let devices: [MixerManager.OutputDevice]
    var onVolumeChange: (Float) -> Void
    var onMuteToggle: () -> Void
    var onDeviceChange: (String?) -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: entry.icon)
                .resizable().frame(width: 24, height: 24).cornerRadius(4).shadow(radius: 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(entry.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    Spacer()
                    Text("\(Int(entry.volume * 100))%")
                        .font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    Slider(
                        value: Binding(get: { entry.volume }, set: { onVolumeChange($0) }),
                        in: 0.0...maxVolume
                    )
                    .controlSize(.small)
                    .tint(.purple)

                    Button(action: onMuteToggle) {
                        Image(systemName: entry.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundColor(entry.isMuted ? .red : .secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                }

                // Per-app output device routing.
                HStack(spacing: 4) {
                    Image(systemName: "hifispeaker.fill")
                        .font(.system(size: 8)).foregroundColor(.secondary)
                    Picker("", selection: Binding(
                        get: { entry.targetDeviceUID ?? "" },
                        set: { onDeviceChange($0.isEmpty ? nil : $0) }
                    )) {
                        Text("System Default").tag("")
                        ForEach(devices) { dev in Text(dev.name).tag(dev.uid) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.mini)
                    .font(.system(size: 9))
                }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .cornerRadius(6)
    }
}
