import SwiftUI
import AudioToolbox
import OSLog

/// Owns process discovery, persistent per-app preferences, engine health, and
/// the UI-facing model. Helper processes that belong to one GUI application are
/// presented as one mixer row and always change volume/route together.
@MainActor
@Observable
final class MixerManager {
    struct AppMixerEntry: Identifiable {
        let id: String                 // owning application key / bundle ID
        let name: String
        let icon: NSImage
        let processCount: Int
        var volume: Float
        var isMuted: Bool
        var targetDeviceUID: String?
    }

    struct OutputDevice: Identifiable, Hashable {
        let uid: String
        let name: String
        var id: String { uid }
    }

    private(set) var activeMixers: [AppMixerEntry] = []
    private(set) var availableOutputDevices: [OutputDevice] = []
    private(set) var defaultOutputDeviceName = "System Default"
    private(set) var permission: AudioCapturePermission = .unknown
    private(set) var engineError: String?
    private(set) var audioWarning: String?

    let maxVolume = AudioRenderKernel.maximumGain

    private let logger = Logger(subsystem: "com.antigravity.AppVolumeMixer", category: "Manager")
    private let engine = AudioMixerEngine()

    private var controlled: [AudioObjectID: ControlledApp] = [:]
    private struct Meta {
        let name: String
        let icon: NSImage
        let key: String
        let isApp: Bool
    }
    private var meta: [AudioObjectID: Meta] = [:]
    private var idlePolls: [AudioObjectID: Int] = [:]
    private let graceLimitPolls = 2
    private var preMute: [String: Float] = [:]

    private var desired: [String: Float] = [:]
    private let desiredDefaultsKey = "AppVolumeMixer.desiredVolumes"
    private var desiredDevices: [String: String] = [:]
    private let desiredDevicesKey = "AppVolumeMixer.desiredDevices"

    private var timer: Timer?
    private var currentDefaultOutputUID: String?
    private var hardwareRefreshTask: Task<Void, Never>?
    private var warningClearTask: Task<Void, Never>?

    init() {
        loadDesired()

        engine.onHardwareChanged = { [weak self] in
            self?.scheduleHardwareRefresh()
        }
        engine.onProcessorOverload = { [weak self] deviceName in
            guard let self else { return }
            self.audioWarning = "Audio was interrupted on \(deviceName). The mixer is still running."
            self.warningClearTask?.cancel()
            self.warningClearTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard !Task.isCancelled else { return }
                self?.audioWarning = nil
            }
        }

        permission = PermissionManager.preflight()
        refreshDevices()
    }

    // MARK: - Lifecycle

    func start() {
        permission = PermissionManager.preflight()
        switch permission {
        case .authorized:
            beginPolling()
            refresh(forceEngine: true)
        case .unknown:
            requestPermission()
        case .denied:
            break
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
                self.refresh(forceEngine: true)
            }
        }
    }

    private func beginPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Discovery

    func refresh(forceEngine: Bool = false) {
        guard permission == .authorized else { return }
        let devicesChanged = refreshDevices()

        guard let processObjectIDs = try? AudioObjectID.readProcessList() else {
            if devicesChanged || forceEngine { configureEngine(force: true) }
            return
        }
        let presentIDs = Set(processObjectIDs)
        let active = discoverActiveProcesses(from: processObjectIDs)
        let myPID = ProcessInfo.processInfo.processIdentifier
        var membershipChanged = false

        for process in active where controlled[process.objectID] == nil {
            guard process.pid > 0, process.pid != myPID else { continue }
            let metadata = resolveMeta(objectID: process.objectID, pid: process.pid)
            guard metadata.isApp else { continue }

            let app = ControlledApp(
                processObjectID: process.objectID,
                pid: process.pid,
                key: metadata.key,
                initialVolume: desired[metadata.key] ?? 1.0,
                targetDeviceUID: desiredDevices[metadata.key]
            )
            controlled[process.objectID] = app
            meta[process.objectID] = metadata
            idlePolls[process.objectID] = 0
            membershipChanged = true
            logger.info("Now controlling \(metadata.name, privacy: .public) (pid=\(process.pid))")
        }

        var retired: [ControlledApp] = []
        var retiredKeys: Set<String> = []
        for id in Array(controlled.keys) {
            // Keep a tap for the lifetime of the Core Audio process object, not
            // merely while kAudioProcessPropertyIsRunning is true. Audio clients
            // commonly toggle that flag between tracks or even between short
            // sounds; tearing down at every pause was a major source of dropouts.
            if presentIDs.contains(id) {
                idlePolls[id] = 0
                continue
            }

            let count = (idlePolls[id] ?? 0) + 1
            idlePolls[id] = count
            guard count >= graceLimitPolls else { continue }

            if let app = controlled.removeValue(forKey: id) {
                retired.append(app)
                retiredKeys.insert(app.key)
            }
            meta.removeValue(forKey: id)
            idlePolls.removeValue(forKey: id)
            membershipChanged = true
        }
        for key in retiredKeys where !controlled.values.contains(where: { $0.key == key }) {
            preMute.removeValue(forKey: key)
        }

        if membershipChanged || devicesChanged || forceEngine {
            configureEngine(force: forceEngine || devicesChanged)
        }
        rebuildUIRows()
        withExtendedLifetime(retired) {}
    }

    private struct ActiveProcess {
        let objectID: AudioObjectID
        let pid: pid_t
    }

    private func discoverActiveProcesses(from objectIDs: [AudioObjectID]) -> [ActiveProcess] {
        return objectIDs.compactMap { objectID in
            guard objectID.readProcessIsRunningOutput() else { return nil }
            let pid: pid_t = (try? objectID.read(
                kAudioProcessPropertyPID, defaultValue: pid_t(-1)
            )) ?? -1
            return pid > 0 ? ActiveProcess(objectID: objectID, pid: pid) : nil
        }
    }

    // MARK: - Engine

    private func configureEngine(force: Bool = false) {
        let ordered = controlled.values.sorted { $0.pid < $1.pid }
        let requestedIDs = Set(ordered.map(\.processObjectID))
        guard force || requestedIDs != engine.configuredProcessIDs else { return }

        let result = engine.configure(with: ordered)
        engineError = result.failures.isEmpty ? nil : result.failures.joined(separator: "\n")
    }

    private func scheduleHardwareRefresh() {
        hardwareRefreshTask?.cancel()
        hardwareRefreshTask = Task { [weak self] in
            // Audio devices often publish several closely spaced notifications.
            // Let the route settle, then reconcile once.
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func tearDownAll() {
        engine.stop()
        controlled.removeAll()
        meta.removeAll()
        idlePolls.removeAll()
        preMute.removeAll()
        activeMixers = []
        engineError = nil
    }

    // MARK: - Volume / mute / route

    func setVolume(for key: String, to volume: Float) {
        let value = AudioRenderKernel.sanitizedGain(volume)
        let matching = controlled.values.filter { $0.key == key }
        guard !matching.isEmpty else { return }
        let oldValue = matching[0].volume

        if value == 0 {
            if oldValue > 0 { preMute[key] = oldValue }
        } else {
            preMute[key] = nil
        }
        for app in matching { app.setVolume(value) }

        desired[key] = value
        saveDesired()
        if let index = activeMixers.firstIndex(where: { $0.id == key }) {
            activeMixers[index].volume = value
            activeMixers[index].isMuted = value == 0
        }
    }

    func toggleMute(for key: String) {
        guard let app = controlled.values.first(where: { $0.key == key }) else { return }
        if app.volume > 0 {
            preMute[key] = app.volume
            setVolume(for: key, to: 0)
        } else {
            let restore = preMute[key] ?? 1.0
            setVolume(for: key, to: restore > 0 ? restore : 1.0)
        }
    }

    func setOutputDevice(for key: String, uid: String?) {
        let matching = controlled.values.filter { $0.key == key }
        guard !matching.isEmpty else { return }
        for app in matching { app.targetDeviceUID = uid }

        if let uid {
            desiredDevices[key] = uid
        } else {
            desiredDevices.removeValue(forKey: key)
        }
        saveDesiredDevices()
        if let index = activeMixers.firstIndex(where: { $0.id == key }) {
            activeMixers[index].targetDeviceUID = uid
        }
        configureEngine(force: true)
    }

    // MARK: - Output devices

    @discardableResult
    private func refreshDevices() -> Bool {
        let oldUIDs = Set(availableOutputDevices.map(\.uid))
        let oldDefaultUID = currentDefaultOutputUID
        guard let ids = try? AudioObjectID.readAllDeviceIDs() else { return false }

        var list: [OutputDevice] = []
        var seen: Set<String> = []
        for id in ids where id.hasOutputStreams {
            guard let uid = try? id.readDeviceUID(), seen.insert(uid).inserted else { continue }

            // Private graphs are visible to their creating process. Never offer
            // them as destinations or a user can accidentally route a graph
            // back into itself.
            let name = id.readDeviceName()
            let transport = id.readTransportType()
            let isOurAggregate = uid.hasPrefix(AudioMixerEngine.aggregateUIDPrefix)
                || (transport == kAudioDeviceTransportTypeAggregate
                    && name.hasPrefix("App Volume Mixer –"))
            // Loopback and virtual-mixer devices can create a recursive graph or
            // deadlock the HAL when used as this mixer's output destination.
            guard !isOurAggregate, transport != kAudioDeviceTransportTypeVirtual else { continue }
            list.append(OutputDevice(uid: uid, name: name))
        }
        list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if list != availableOutputDevices { availableOutputDevices = list }

        if let defaultID = try? AudioObjectID.readDefaultOutputDevice(), defaultID.isValid {
            defaultOutputDeviceName = defaultID.readDeviceName()
            currentDefaultOutputUID = try? defaultID.readDeviceUID()
        } else {
            defaultOutputDeviceName = "Unavailable"
            currentDefaultOutputUID = nil
        }
        return oldUIDs != Set(list.map(\.uid)) || oldDefaultUID != currentDefaultOutputUID
    }

    // MARK: - UI rows

    private func rebuildUIRows() {
        let grouped = Dictionary(grouping: controlled.values, by: \.key)
        let rows: [AppMixerEntry] = grouped.compactMap { key, apps in
            guard let app = apps.min(by: { $0.pid < $1.pid }),
                  let metadata = meta[app.processObjectID] else { return nil }
            return AppMixerEntry(
                id: key,
                name: metadata.name,
                icon: metadata.icon,
                processCount: apps.count,
                volume: app.volume,
                isMuted: app.volume == 0,
                targetDeviceUID: app.targetDeviceUID
            )
        }
        activeMixers = rows.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Metadata

    private func resolveMeta(objectID: AudioObjectID, pid: pid_t) -> Meta {
        let owningApp = responsibleApp(for: pid)
        let processBundleID = objectID.readProcessBundleID()
        let name = owningApp?.localizedName ?? processName(pid: pid) ?? "Process \(pid)"
        let key = owningApp?.bundleIdentifier
            ?? processBundleID
            ?? processName(pid: pid)
            ?? "pid:\(pid)"
        let icon = owningApp?.icon ?? NSWorkspace.shared.icon(for: .unixExecutable)
        return Meta(name: name, icon: icon, key: key, isApp: owningApp != nil)
    }

    private func responsibleApp(for pid: pid_t) -> NSRunningApplication? {
        let applications = NSWorkspace.shared.runningApplications
        var current = pid
        for _ in 0..<12 {
            if let app = applications.first(where: { $0.processIdentifier == current }) {
                return app
            }
            let parent = parentPID(of: current)
            guard parent > 1, parent != current else { break }
            current = parent
        }
        return nil
    }

    private func parentPID(of pid: pid_t) -> pid_t {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        return count == size ? pid_t(info.pbi_ppid) : 0
    }

    private func processName(pid: pid_t) -> String? {
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(MAXPATHLEN))
        defer { buffer.deallocate() }
        let length = proc_name(pid, buffer, UInt32(MAXPATHLEN))
        return length > 0 ? String(cString: buffer) : nil
    }

    // MARK: - Persistence

    private func loadDesired() {
        if let values = UserDefaults.standard.dictionary(forKey: desiredDefaultsKey) as? [String: Double] {
            desired = values.mapValues { AudioRenderKernel.sanitizedGain(Float($0)) }
        }
        if let devices = UserDefaults.standard.dictionary(forKey: desiredDevicesKey) as? [String: String] {
            desiredDevices = devices
        }
    }

    private func saveDesired() {
        UserDefaults.standard.set(desired.mapValues { Double($0) }, forKey: desiredDefaultsKey)
    }

    private func saveDesiredDevices() {
        UserDefaults.standard.set(desiredDevices, forKey: desiredDevicesKey)
    }
}
