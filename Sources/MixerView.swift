import SwiftUI

struct MixerView: View {
    let manager: MixerManager

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.35)

            switch manager.permission {
            case .authorized:
                authorizedContent
            case .denied:
                permissionPanel(
                    title: "Audio Access Denied",
                    message: "Enable App Volume Mixer under Privacy & Security → Audio, then return and refresh.",
                    primary: ("Open System Settings", openAudioSettings)
                )
            case .unknown:
                permissionPanel(
                    title: "Audio Access Needed",
                    message: "Access to system audio lets the mixer adjust each app without a virtual audio driver.",
                    primary: ("Enable Audio Access", manager.requestPermission)
                )
            }

            Divider().opacity(0.35)
            footer
        }
        .frame(width: 360)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.gradient)
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("App Volume Mixer")
                    .font(.system(size: 13, weight: .semibold))
                Text(headerStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .accessibilityLabel(headerStatus)
            Button {
                manager.refresh(forceEngine: true)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Refresh apps and retry audio routes")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var headerStatus: String {
        if manager.permission != .authorized { return "Waiting for permission" }
        if manager.engineError != nil { return "A route needs attention" }
        if manager.audioWarning != nil { return "Audio interruption detected" }
        if manager.activeMixers.isEmpty { return "Ready" }
        return "Mixing \(manager.activeMixers.count) app\(manager.activeMixers.count == 1 ? "" : "s")"
    }

    private var statusColor: Color {
        if manager.permission == .denied || manager.engineError != nil { return .red }
        if manager.permission == .unknown || manager.audioWarning != nil { return .orange }
        return .green
    }

    private var authorizedContent: some View {
        VStack(spacing: 0) {
            if let error = manager.engineError {
                statusBanner(
                    icon: "exclamationmark.triangle.fill",
                    color: .red,
                    title: "Audio route unavailable",
                    message: error
                )
            } else if let warning = manager.audioWarning {
                statusBanner(
                    icon: "waveform.badge.exclamationmark",
                    color: .orange,
                    title: "Audio interruption",
                    message: warning
                )
            }
            appList
        }
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 9) {
                if manager.activeMixers.isEmpty {
                    emptyState
                } else {
                    ForEach(manager.activeMixers) { entry in
                        AppVolumeRow(
                            entry: entry,
                            maxVolume: manager.maxVolume,
                            devices: manager.availableOutputDevices,
                            defaultDeviceName: manager.defaultOutputDeviceName,
                            onVolumeChange: { manager.setVolume(for: entry.id, to: $0) },
                            onMuteToggle: { manager.toggleMute(for: entry.id) },
                            onDeviceChange: { manager.setOutputDevice(for: entry.id, uid: $0) }
                        )
                    }
                }
            }
            .padding(11)
        }
        .frame(minHeight: 170, maxHeight: 430)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 25))
                .foregroundStyle(.secondary)
            Text("No apps are playing audio")
                .font(.system(size: 11, weight: .medium))
            Text("Start playback and the app will appear here automatically.")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 145)
        .padding(.horizontal, 35)
    }

    private func statusBanner(
        icon: String,
        color: Color,
        title: String,
        message: String
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10, weight: .semibold))
                Text(message)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(9)
        .background(color.opacity(0.09))
        .overlay(alignment: .bottom) { Divider().opacity(0.2) }
    }

    private func permissionPanel(
        title: String,
        message: String,
        primary: (String, () -> Void)
    ) -> some View {
        VStack(spacing: 13) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 26))
                .foregroundStyle(.tint)
            VStack(spacing: 4) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(primary.0, action: primary.1)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 190)
    }

    private func openAudioSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(manager.defaultOutputDeviceName)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct AppVolumeRow: View {
    let entry: MixerManager.AppMixerEntry
    let maxVolume: Float
    let devices: [MixerManager.OutputDevice]
    let defaultDeviceName: String
    var onVolumeChange: (Float) -> Void
    var onMuteToggle: () -> Void
    var onDeviceChange: (String?) -> Void

    private var isBoosted: Bool { entry.volume > 1.0 }
    private var unavailableTarget: String? {
        guard let target = entry.targetDeviceUID,
              !devices.contains(where: { $0.uid == target }) else { return nil }
        return target
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(nsImage: entry.icon)
                .resizable()
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 5) {
                    Text(entry.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                    if entry.processCount > 1 {
                        Text("\(entry.processCount)")
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.12), in: Capsule())
                            .help("\(entry.processCount) audio helper processes grouped together")
                    }
                    Spacer()
                    Text("\(Int((entry.volume * 100).rounded()))%")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(isBoosted ? .orange : .secondary)
                }

                HStack(spacing: 8) {
                    Slider(
                        value: Binding(get: { entry.volume }, set: onVolumeChange),
                        in: 0...maxVolume
                    )
                    .controlSize(.small)
                    .tint(isBoosted ? .orange : .accentColor)
                    .accessibilityLabel("Volume for \(entry.name)")

                    Button(action: onMuteToggle) {
                        Image(systemName: entry.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(entry.isMuted ? .red : .secondary)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .help(entry.isMuted ? "Unmute" : "Mute")
                }

                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                    Picker("Output", selection: Binding(
                        get: { entry.targetDeviceUID ?? "" },
                        set: { onDeviceChange($0.isEmpty ? nil : $0) }
                    )) {
                        Text("System Default — \(defaultDeviceName)").tag("")
                        ForEach(devices) { device in
                            Text(device.name).tag(device.uid)
                        }
                        if let unavailableTarget {
                            Text("Unavailable — using default").tag(unavailableTarget)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.mini)
                    .font(.system(size: 9))
                }
            }
        }
        .padding(10)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contextMenu {
            Button("Set to 100%") { onVolumeChange(1.0) }
            Button(entry.isMuted ? "Unmute" : "Mute", action: onMuteToggle)
        }
    }
}
