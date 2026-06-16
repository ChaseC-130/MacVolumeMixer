import SwiftUI
import AudioToolbox
import OSLog

/// Owns audio-process discovery, the persistent per-app volume model, and the
/// single mixing engine. Lives at App scope (see VolumeMixerApp) so taps persist
/// for the whole app lifetime regardless of whether the menu popover is open.
@MainActor
@Observable
final class MixerManager {
    /// One row in the UI. A value type observed by SwiftUI; the real-time volume
    /// truth lives in the matching ControlledApp's volume pointer.
    struct AppMixerEntry: Identifiable {
        let id: AudioObjectID    // Core Audio process object ID
        let pid: pid_t
        let name: String
        let icon: NSImage
        var volume: Float
        var isMuted: Bool
    }

    private(set) var activeMixers: [AppMixerEntry] = []
    private(set) var permission: AudioCapturePermission = .unknown

    /// Largest boost the UI/clamp allows (2.0 == 200%).
    let maxVolume: Float = 2.0

    private let logger = Logger(subsystem: "com.antigravity.AppVolumeMixer", category: "Manager")
    private let engine = AudioMixerEngine()

    // Audio identity → controlled app (holds the RT volume pointer + tap UUID).
    private var controlled: [AudioObjectID: ControlledApp] = [:]
    // Cached UI metadata so we don't re-resolve names/icons every poll.
    private struct Meta { let name: String; let icon: NSImage; let key: String }
    private var meta: [AudioObjectID: Meta] = [:]
    // Consecutive polls a controlled app has been audio-inactive (hysteresis).
    private var idlePolls: [AudioObjectID: Int] = [:]
    private let graceLimitPolls = 2
    // Per-app pre-mute level so unmute restores the previous volume.
    private var preMute: [AudioObjectID: Float] = [:]
    // Persisted desired volume keyed by bundleID/exec-name, survives tap churn.
    private var desired: [String: Float] = [:]
    private let desiredDefaultsKey = "AppVolumeMixer.desiredVolumes"

    private var timer: Timer?

    init() {
        loadDesired()
        engine.onDefaultDeviceChanged = { [weak self] in self?.rebuildEngine(force: true) }
        permission = PermissionManager.preflight()
    }

    // MARK: - Lifecycle

    /// Called once when the app finishes launching. Drives the permission flow
    /// and starts polling once authorized.
    func start() {
        permission = PermissionManager.preflight()
        switch permission {
        case .authorized:
            beginPolling()
            refresh()
        case .unknown:
            requestPermission()   // prompt the user; begin once granted
        case .denied:
            break                 // UI shows the "Open System Settings" path
        }
    }

    func requestPermission() {
        PermissionManager.request { [weak self] granted in
            guard let self else { return }
            self.permission = granted ? .authorized : .denied
            self.logger.info("Audio capture permission \(granted ? "granted" : "denied")")
            if granted {
                self.tearDownAll()
                self.beginPolling()
                self.refresh()
            }
        }
    }

    private func beginPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: - Discovery

    /// Polls Core Audio for audio-active processes, reconciles the controlled
    /// set (with idle hysteresis), rebuilds the engine on membership change, and
    /// refreshes the UI rows.
    func refresh() {
        guard permission == .authorized else { return }

        let active = discoverActiveProcesses()
        let activeIDs = Set(active.map(\.objectID))
        let myPID = ProcessInfo.processInfo.processIdentifier
        var membershipChanged = false

        // Add newly-active processes.
        for proc in active where controlled[proc.objectID] == nil {
            guard proc.pid > 0, proc.pid != myPID else { continue }
            let m = resolveMeta(objectID: proc.objectID, pid: proc.pid)
            let initial = desired[m.key] ?? 1.0
            let app = ControlledApp(processObjectID: proc.objectID, pid: proc.pid, key: m.key, initialVolume: initial)
            controlled[proc.objectID] = app
            meta[proc.objectID] = m
            idlePolls[proc.objectID] = 0
            membershipChanged = true
        }

        // Age out processes that have gone inactive past the grace period.
        // Keep retired apps alive across the rebuild: the engine also retains
        // them until it destroys the old IOProc, but holding a ref here too keeps
        // the RT volume pointer valid no matter the ordering.
        var retired: [ControlledApp] = []
        for id in Array(controlled.keys) {
            if activeIDs.contains(id) {
                idlePolls[id] = 0
            } else {
                let n = (idlePolls[id] ?? 0) + 1
                idlePolls[id] = n
                if n >= graceLimitPolls {
                    if let app = controlled.removeValue(forKey: id) { retired.append(app) }
                    meta.removeValue(forKey: id)
                    idlePolls.removeValue(forKey: id)
                    preMute.removeValue(forKey: id)
                    membershipChanged = true
                }
            }
        }

        if membershipChanged { rebuildEngine() }   // teardown() stops the old IOProc here
        rebuildUIRows()
        withExtendedLifetime(retired) {}            // only now may retired volumePtrs free
    }

    private struct ActiveProcess { let objectID: AudioObjectID; let pid: pid_t }

    private func discoverActiveProcesses() -> [ActiveProcess] {
        guard let objectIDs = try? AudioObjectID.readProcessList() else { return [] }
        var result: [ActiveProcess] = []
        for objectID in objectIDs {
            guard objectID.readProcessIsRunning() else { continue }   // audio-active only
            let pid: pid_t = (try? objectID.read(kAudioProcessPropertyPID, defaultValue: pid_t(-1))) ?? -1
            guard pid > 0 else { continue }
            result.append(ActiveProcess(objectID: objectID, pid: pid))
        }
        return result
    }

    // MARK: - Engine

    /// Rebuilds the aggregate device for the current controlled set. `force`
    /// rebuilds even if membership is unchanged (used on default-device change).
    private func rebuildEngine(force: Bool = false) {
        let ordered = controlled.values.sorted { $0.pid < $1.pid }   // deterministic tap order
        let orderedIDs = ordered.map(\.processObjectID)
        if !force && orderedIDs == engine.builtKeys { return }

        do {
            try engine.rebuild(with: ordered)
        } catch {
            logger.error("Engine rebuild failed: \(error.localizedDescription)")
            // A failure here on macOS is almost always the capture permission.
            let status = PermissionManager.preflight()
            if status != .authorized { permission = status }
        }
    }

    private func tearDownAll() {
        engine.stop()
        controlled.removeAll()
        meta.removeAll()
        idlePolls.removeAll()
        preMute.removeAll()
        activeMixers = []
    }

    // MARK: - Volume / mute

    func setVolume(for id: AudioObjectID, to volume: Float) {
        let v = max(0, min(volume, maxVolume))
        guard let app = controlled[id] else { return }
        let old = app.volume
        // Track pre-mute level however 0 is reached (slider or mute button), and
        // clear it once the app is audible again, so unmute restores the last
        // audible level rather than jumping to 100%.
        if v == 0 {
            if old > 0 { preMute[id] = old }
        } else {
            preMute[id] = nil
        }
        app.setVolume(v)
        desired[app.key] = v
        saveDesired()
        if let i = activeMixers.firstIndex(where: { $0.id == id }) {
            activeMixers[i].volume = v
            activeMixers[i].isMuted = (v == 0)
        }
    }

    func toggleMute(for id: AudioObjectID) {
        guard let app = controlled[id] else { return }
        if app.volume > 0 {
            preMute[id] = app.volume
            setVolume(for: id, to: 0)
        } else {
            let restore = preMute[id] ?? 1.0
            setVolume(for: id, to: restore > 0 ? restore : 1.0)
        }
    }

    // MARK: - UI rows

    private func rebuildUIRows() {
        let rows: [AppMixerEntry] = controlled.values.compactMap { app in
            guard let m = meta[app.processObjectID] else { return nil }
            return AppMixerEntry(
                id: app.processObjectID,
                pid: app.pid,
                name: m.name,
                icon: m.icon,
                volume: app.volume,
                isMuted: app.volume == 0
            )
        }
        // Alphabetical, computed only on rebuild (stable identity keeps rows put).
        activeMixers = rows.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Metadata

    private func resolveMeta(objectID: AudioObjectID, pid: pid_t) -> Meta {
        let runningApp = NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }
        let bundleID = objectID.readProcessBundleID() ?? runningApp?.bundleIdentifier
        let name = runningApp?.localizedName ?? processName(pid: pid) ?? "Process \(pid)"
        let key = bundleID ?? processName(pid: pid) ?? "pid:\(pid)"
        let icon = runningApp?.icon ?? NSWorkspace.shared.icon(for: .unixExecutable)
        return Meta(name: name, icon: icon, key: key)
    }

    private func processName(pid: pid_t) -> String? {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        defer { buffer.deallocate() }
        let len = proc_name(pid, buffer, UInt32(MAXPATHLEN))
        return len > 0 ? String(cString: buffer) : nil
    }

    // MARK: - Persistence

    private func loadDesired() {
        if let dict = UserDefaults.standard.dictionary(forKey: desiredDefaultsKey) as? [String: Double] {
            desired = dict.mapValues { Float($0) }
        }
    }

    private func saveDesired() {
        UserDefaults.standard.set(desired.mapValues { Double($0) }, forKey: desiredDefaultsKey)
    }
}
