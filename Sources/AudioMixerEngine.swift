import Foundation
import AudioToolbox
import CoreAudio
import OSLog

/// A single Core Audio process whose output the engine controls.
final class ControlledApp: Identifiable {
    let processObjectID: AudioObjectID
    let pid: pid_t
    let key: String
    let tapUUID = UUID()
    let volumePtr: UnsafeMutablePointer<Float>
    /// Target output device UID, or nil to follow the system default output.
    var targetDeviceUID: String?

    init(
        processObjectID: AudioObjectID,
        pid: pid_t,
        key: String,
        initialVolume: Float,
        targetDeviceUID: String?
    ) {
        self.processObjectID = processObjectID
        self.pid = pid
        self.key = key
        self.targetDeviceUID = targetDeviceUID
        volumePtr = .allocate(capacity: 1)
        volumePtr.initialize(to: AudioRenderKernel.sanitizedGain(initialVolume))
    }

    deinit { volumePtr.deallocate() }

    var volume: Float { volumePtr.pointee }
    func setVolume(_ value: Float) { volumePtr.pointee = AudioRenderKernel.sanitizedGain(value) }
}

struct AudioEngineConfigurationResult {
    let failures: [String]
}

/// Coordinates one graph per physical output route. Unchanged graphs survive a
/// configuration update, so an app starting on one device no longer interrupts
/// audio already playing on another device.
final class AudioMixerEngine {
    static let aggregateUIDPrefix = "com.antigravity.AppVolumeMixer.aggregate."

    private let logger = Logger(subsystem: "com.antigravity.AppVolumeMixer", category: "Engine")
    private var graphs: [String: DeviceGraph] = [:]

    /// The most recently requested membership, including routes that failed.
    /// Tracking requested membership prevents a failed route from destructively
    /// retrying every discovery poll; manual refresh and hardware changes retry.
    private(set) var configuredProcessIDs: Set<AudioObjectID> = []

    var onHardwareChanged: (() -> Void)?
    var onProcessorOverload: ((String) -> Void)?

    private var systemListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultDeviceAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var deviceListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init() {
        installSystemListeners()
    }

    /// Reconciles the desired app/device groups with live graphs. A graph is
    /// rebuilt only if that specific device's process membership changed.
    @discardableResult
    func configure(with apps: [ControlledApp]) -> AudioEngineConfigurationResult {
        let requestedIDs = Set(apps.map(\.processObjectID))
        configuredProcessIDs = requestedIDs

        guard !apps.isEmpty else {
            teardownAll()
            logger.info("Engine idle (no apps to control)")
            return AudioEngineConfigurationResult(failures: [])
        }

        let defaultUID = try? AudioObjectID.readDefaultOutputDevice().readDeviceUID()
        var desiredGroups: [String: [ControlledApp]] = [:]
        var failures: [String] = []

        for app in apps {
            guard let uid = effectiveDeviceUID(app.targetDeviceUID, default: defaultUID) else {
                let message = "No compatible output is available for \(app.key). "
                    + "Choose a hardware device instead of a virtual mixer or loopback device."
                if !failures.contains(message) { failures.append(message) }
                continue
            }
            desiredGroups[uid, default: []].append(app)
        }
        for uid in desiredGroups.keys {
            desiredGroups[uid]?.sort { $0.pid < $1.pid }
        }

        // Remove obsolete or changed graphs. Unchanged routes remain live.
        for uid in Array(graphs.keys) {
            let desiredIDs = desiredGroups[uid]?.map(\.processObjectID)
            guard desiredIDs == graphs[uid]?.processIDs else {
                graphs.removeValue(forKey: uid)?.teardown()
                continue
            }
        }

        // Build missing routes, including previously failed routes on explicit
        // refresh. A failed graph tears itself down completely before throwing.
        for uid in desiredGroups.keys.sorted() where graphs[uid] == nil {
            guard let group = desiredGroups[uid] else { continue }
            do {
                let graph = try DeviceGraph(
                    outputDeviceUID: uid,
                    apps: group,
                    logger: logger,
                    onProcessorOverload: { [weak self] deviceName in
                        self?.onProcessorOverload?(deviceName)
                    }
                )
                graphs[uid] = graph
            } catch {
                let deviceName = AudioObjectID.readDeviceID(forUID: uid)?.readDeviceName() ?? uid
                let message = "\(deviceName): \(error.localizedDescription)"
                failures.append(message)
                logger.error("Graph build failed: \(message, privacy: .public)")
            }
        }

        let builtProcessCount = Set(graphs.values.flatMap(\.processIDs)).count
        logger.info("Engine configured: \(self.graphs.count) graph(s), \(builtProcessCount) tap(s)")
        return AudioEngineConfigurationResult(failures: failures)
    }

    func stop() {
        configuredProcessIDs = []
        teardownAll()
    }

    private func teardownAll() {
        for graph in graphs.values { graph.teardown() }
        graphs.removeAll()
    }

    private func effectiveDeviceUID(_ target: String?, default defaultUID: String?) -> String? {
        if let target,
           let device = AudioObjectID.readDeviceID(forUID: target),
           device.hasOutputStreams,
           device.readTransportType() != kAudioDeviceTransportTypeVirtual {
            return target
        }
        guard let defaultUID,
              let defaultDevice = AudioObjectID.readDeviceID(forUID: defaultUID),
              defaultDevice.hasOutputStreams,
              defaultDevice.readTransportType() != kAudioDeviceTransportTypeVirtual else {
            return nil
        }
        return defaultUID
    }

    // MARK: - Hardware notifications

    private func installSystemListeners() {
        guard systemListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.logger.info("Audio hardware routing changed")
                self?.onHardwareChanged?()
            }
        }

        let defaultError = AudioObjectAddPropertyListenerBlock(
            .system, &defaultDeviceAddress, DispatchQueue.main, block
        )
        let listError = AudioObjectAddPropertyListenerBlock(
            .system, &deviceListAddress, DispatchQueue.main, block
        )
        if defaultError == noErr, listError == noErr {
            systemListenerBlock = block
        } else {
            if defaultError == noErr {
                AudioObjectRemovePropertyListenerBlock(.system, &defaultDeviceAddress, DispatchQueue.main, block)
            }
            if listError == noErr {
                AudioObjectRemovePropertyListenerBlock(.system, &deviceListAddress, DispatchQueue.main, block)
            }
            logger.error("Unable to install all hardware listeners: \(defaultError), \(listError)")
        }
    }

    private func removeSystemListeners() {
        guard let block = systemListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(.system, &defaultDeviceAddress, DispatchQueue.main, block)
        AudioObjectRemovePropertyListenerBlock(.system, &deviceListAddress, DispatchQueue.main, block)
        systemListenerBlock = nil
    }

    deinit {
        removeSystemListeners()
        teardownAll()
    }
}

/// A private aggregate device containing one real output subdevice and one
/// stereo process tap per controlled process routed to that device.
private final class DeviceGraph {
    let processIDs: [AudioObjectID]

    private let outputDeviceUID: String
    private let logger: Logger
    private let ioQueue: DispatchQueue
    private let onProcessorOverload: (String) -> Void

    private var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private var isStarted = false
    private var tapIDs: [AudioObjectID] = []
    private var builtApps: [ControlledApp] = []
    private var volumeTable: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>?
    private var smoothedVolumeTable: UnsafeMutableBufferPointer<Float>?

    private var overloadListenerBlock: AudioObjectPropertyListenerBlock?
    private var overloadAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDeviceProcessorOverload,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    init(
        outputDeviceUID: String,
        apps: [ControlledApp],
        logger: Logger,
        onProcessorOverload: @escaping (String) -> Void
    ) throws {
        self.outputDeviceUID = outputDeviceUID
        self.processIDs = apps.map(\.processObjectID)
        self.logger = logger
        self.onProcessorOverload = onProcessorOverload
        self.ioQueue = DispatchQueue(
            label: "com.antigravity.AppVolumeMixer.io.\(outputDeviceUID)",
            qos: .userInteractive
        )

        do {
            try build(apps: apps)
        } catch {
            teardown()
            throw error
        }
    }

    private func build(apps: [ControlledApp]) throws {
        guard let outputDevice = AudioObjectID.readDeviceID(forUID: outputDeviceUID),
              outputDevice.hasOutputStreams,
              outputDevice.readTransportType() != kAudioDeviceTransportTypeVirtual else {
            throw "The selected output device is unavailable."
        }
        let deviceName = outputDevice.readDeviceName()
        let inputBaseOffset = outputDevice.channelCounts(scope: kAudioObjectPropertyScopeInput).channels
        let preferredStereo = outputDevice.preferredStereoChannels()

        // Use the UID returned by the created tap, as required by Apple's
        // process-tap sample. Validate every tap before it can reach the IOProc.
        var tapList: [[String: Any]] = []
        for app in apps {
            let description = CATapDescription(stereoMixdownOfProcesses: [app.processObjectID])
            description.uuid = app.tapUUID
            description.muteBehavior = .mutedWhenTapped
            description.name = "App Volume Mixer – \(app.pid)"
            description.isPrivate = true

            var tapID: AudioObjectID = .unknown
            let createError = AudioHardwareCreateProcessTap(description, &tapID)
            guard createError == noErr, tapID.isValid else {
                throw "Could not create a process tap for PID \(app.pid) (OSStatus \(createError))."
            }
            tapIDs.append(tapID)

            let tapUID = try tapID.readAudioTapUID()
            let format = try tapID.readAudioTapStreamBasicDescription()
            guard format.isNativeFloat32PCM, format.mChannelsPerFrame == 2 else {
                throw "Unsupported tap format for PID \(app.pid): \(format.conciseDescription)."
            }
            logger.debug("Tap PID \(app.pid): \(format.conciseDescription, privacy: .public)")

            tapList.append([
                kAudioSubTapUIDKey as String: tapUID,
                kAudioSubTapDriftCompensationKey as String: true,
                kAudioSubTapDriftCompensationQualityKey as String:
                    UInt32(kAudioAggregateDriftCompensationMaxQuality),
            ])
        }

        let aggregateUID = AudioMixerEngine.aggregateUIDPrefix + UUID().uuidString
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "App Volume Mixer – \(deviceName)",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID],
            ],
            kAudioAggregateDeviceTapListKey as String: tapList,
        ]

        var newAggregateID: AudioObjectID = .unknown
        let aggregateError = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard aggregateError == noErr, newAggregateID.isValid else {
            throw "Could not create the output graph (OSStatus \(aggregateError))."
        }
        aggregateID = newAggregateID

        let inputFormats = try aggregateID.readStreamFormats(scope: kAudioObjectPropertyScopeInput)
        let outputFormats = try aggregateID.readStreamFormats(scope: kAudioObjectPropertyScopeOutput)
        guard !inputFormats.isEmpty, !outputFormats.isEmpty else {
            throw "The aggregate device did not expose usable input and output streams."
        }
        guard inputFormats.allSatisfy(\.isNativeFloat32PCM),
              outputFormats.allSatisfy(\.isNativeFloat32PCM) else {
            let formats = (inputFormats + outputFormats).map(\.conciseDescription).joined(separator: ", ")
            throw "Unsupported aggregate stream format: \(formats)."
        }

        let inputChannels = inputFormats.reduce(0) { $0 + Int($1.mChannelsPerFrame) }
        let outputChannels = outputFormats.reduce(0) { $0 + Int($1.mChannelsPerFrame) }
        let expectedInputChannels = inputBaseOffset + apps.count * 2
        guard inputChannels >= expectedInputChannels, outputChannels > 0 else {
            throw "Unexpected aggregate layout (\(inputChannels) input / \(outputChannels) output channels)."
        }

        let stereoOutput = preferredStereo ?? (left: 0, right: min(1, outputChannels - 1))
        guard stereoOutput.left < outputChannels, stereoOutput.right < outputChannels else {
            throw "The device's preferred stereo channels are outside its output layout."
        }

        let volumes = UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>.allocate(capacity: apps.count)
        let smoothed = UnsafeMutableBufferPointer<Float>.allocate(capacity: apps.count)
        for (index, app) in apps.enumerated() {
            volumes[index] = app.volumePtr
            smoothed[index] = app.volume
        }
        volumeTable = volumes
        smoothedVolumeTable = smoothed
        builtApps = apps

        guard let volumeBase = volumes.baseAddress, let smoothedBase = smoothed.baseAddress else {
            throw "Could not allocate real-time mixer state."
        }

        let tapCount = apps.count
        let leftChannel = stereoOutput.left
        let rightChannel = stereoOutput.right
        var newProcID: AudioDeviceIOProcID?
        let procError = AudioDeviceCreateIOProcIDWithBlock(
            &newProcID, aggregateID, ioQueue
        ) { _, inputData, _, outputData, _ in
            AudioRenderKernel.render(
                input: inputData,
                output: outputData,
                targetVolumes: volumeBase,
                smoothedVolumes: smoothedBase,
                tapCount: tapCount,
                inputBaseOffset: inputBaseOffset,
                outLeftChannel: leftChannel,
                outRightChannel: rightChannel
            )
        }
        guard procError == noErr, let liveProcID = newProcID else {
            throw "Could not install the audio renderer (OSStatus \(procError))."
        }
        procID = liveProcID

        let startError = AudioDeviceStart(aggregateID, liveProcID)
        guard startError == noErr else {
            throw "Could not start audio output (OSStatus \(startError))."
        }
        isStarted = true
        installOverloadListener(deviceName: deviceName)

        logger.info("""
        Graph[\(deviceName, privacy: .public)] taps=\(apps.count) \
        input=\(inputChannels)ch output=\(outputChannels)ch \
        stereo=(\(stereoOutput.left),\(stereoOutput.right)) driftQuality=max
        """)
    }

    private func installOverloadListener(deviceName: String) {
        let logger = self.logger
        let report = onProcessorOverload
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            logger.error("Processor overload on \(deviceName, privacy: .public)")
            report(deviceName)
        }
        let error = AudioObjectAddPropertyListenerBlock(
            aggregateID, &overloadAddress, DispatchQueue.main, block
        )
        if error == noErr { overloadListenerBlock = block }
    }

    func teardown() {
        if let block = overloadListenerBlock, aggregateID.isValid {
            AudioObjectRemovePropertyListenerBlock(
                aggregateID, &overloadAddress, DispatchQueue.main, block
            )
        }
        overloadListenerBlock = nil

        if let procID, aggregateID.isValid {
            if isStarted { AudioDeviceStop(aggregateID, procID) }
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        isStarted = false
        procID = nil

        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        for tapID in tapIDs where tapID.isValid {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapIDs.removeAll()

        volumeTable?.deallocate()
        volumeTable = nil
        smoothedVolumeTable?.deallocate()
        smoothedVolumeTable = nil

        // Apps own the target pointers captured by the IOProc, so release them
        // only after the IOProc has been destroyed.
        builtApps.removeAll()
    }

    deinit { teardown() }
}
