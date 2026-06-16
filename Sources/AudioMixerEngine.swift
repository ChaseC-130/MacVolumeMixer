import Foundation
import AudioToolbox
import CoreAudio
import Accelerate
import OSLog

/// A single app whose output volume and target device the engine controls.
///
/// `volumePtr` is the real-time source of truth: read on the audio I/O thread,
/// written on the main thread. It is a bare `UnsafeMutablePointer<Float>` (not
/// ARC-managed) so the I/O block can capture it by value with zero retain/release
/// traffic. On arm64 an aligned 4-byte access is tear-free, so the relaxed RT
/// read is safe in practice; the value is only ever a volume scalar.
final class ControlledApp: Identifiable {
    let processObjectID: AudioObjectID   // Core Audio process object — engine identity
    let pid: pid_t
    let key: String                      // bundleID ?? executable name — persistent key
    let tapUUID = UUID()
    let volumePtr: UnsafeMutablePointer<Float>
    /// Target output device UID, or nil to follow the system default output.
    /// Main-thread only; a route change triggers an engine rebuild.
    var targetDeviceUID: String?

    init(processObjectID: AudioObjectID, pid: pid_t, key: String, initialVolume: Float, targetDeviceUID: String?) {
        self.processObjectID = processObjectID
        self.pid = pid
        self.key = key
        self.targetDeviceUID = targetDeviceUID
        self.volumePtr = .allocate(capacity: 1)
        self.volumePtr.initialize(to: initialVolume)
    }

    deinit { volumePtr.deallocate() }

    var volume: Float { volumePtr.pointee }
    func setVolume(_ v: Float) { volumePtr.pointee = v }
}

/// Coordinates one `DeviceGraph` per distinct target output device. Apps routed
/// to the same device share a graph (and its single mixing IOProc); apps routed
/// to different devices get independent graphs. Different graphs drive different
/// hardware, so they do not contend for the same output (which is why
/// per-process aggregates on the SAME device were the original bug).
final class AudioMixerEngine {
    private let logger = Logger(subsystem: "com.antigravity.AppVolumeMixer", category: "Engine")

    // One graph per output device UID currently in use.
    private var graphs: [String: DeviceGraph] = [:]
    /// Process object IDs currently tapped across all graphs (membership guard).
    private(set) var builtProcessIDs: Set<AudioObjectID> = []

    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    /// Invoked on the main actor when the system default output device changes,
    /// so the owner can rebuild (apps following the default need re-routing).
    var onDefaultDeviceChanged: (() -> Void)?

    var isRunning: Bool { !graphs.isEmpty }

    // MARK: - Public

    /// Tear down all graphs and rebuild them, grouping `apps` by their effective
    /// target device. Throws if every group fails to build despite having apps
    /// (almost always the capture permission).
    func rebuild(with apps: [ControlledApp]) throws {
        teardownAll()
        guard !apps.isEmpty else {
            builtProcessIDs = []
            logger.info("Engine idle (no apps to control)")
            return
        }

        let defaultUID = try? AudioObjectID.readDefaultOutputDevice().readDeviceUID()

        // Group apps by the device they will actually play through.
        var groups: [String: [ControlledApp]] = [:]
        for app in apps {
            guard let uid = effectiveDeviceUID(app.targetDeviceUID, default: defaultUID) else { continue }
            groups[uid, default: []].append(app)
        }
        guard !groups.isEmpty else { throw "No usable output device for any app" }

        var firstError: Error?
        var built: Set<AudioObjectID> = []
        for (uid, groupApps) in groups {
            let ordered = groupApps.sorted { $0.pid < $1.pid }   // deterministic tap order
            do {
                graphs[uid] = try DeviceGraph(outputDeviceUID: uid, apps: ordered, logger: logger)
                for a in ordered { built.insert(a.processObjectID) }
            } catch {
                logger.error("Graph build failed for device \(uid): \(error.localizedDescription)")
                if firstError == nil { firstError = error }
            }
        }

        builtProcessIDs = built
        if graphs.isEmpty, let firstError { throw firstError }   // total failure → surface (permission)

        installDefaultDeviceListener()
        logger.info("Engine running: \(self.graphs.count) device graph(s), \(built.count) tap(s)")
    }

    func stop() { teardownAll() }

    private func teardownAll() {
        for (_, g) in graphs { g.teardown() }
        graphs.removeAll()
        builtProcessIDs = []
    }

    deinit {
        removeDefaultDeviceListener()
        teardownAll()
    }

    // MARK: - Routing helpers

    /// The device an app will actually play through: its explicit target if that
    /// device is present, else the system default.
    private func effectiveDeviceUID(_ target: String?, default def: String?) -> String? {
        if let t = target, AudioObjectID.readDeviceID(forUID: t) != nil { return t }
        return def
    }

    // MARK: - Default device change

    private func installDefaultDeviceListener() {
        guard deviceListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.logger.info("Default output device changed — rebuilding")
                self?.onDefaultDeviceChanged?()
            }
        }
        let err = AudioObjectAddPropertyListenerBlock(.system, &deviceListenerAddr, DispatchQueue.main, block)
        if err == noErr { deviceListenerBlock = block }
    }

    private func removeDefaultDeviceListener() {
        guard let block = deviceListenerBlock else { return }
        AudioObjectRemovePropertyListenerBlock(.system, &deviceListenerAddr, DispatchQueue.main, block)
        deviceListenerBlock = nil
    }
}

/// One private aggregate device wrapping a single output device plus a tap per
/// app routed to it, and one real-time IOProc that mixes every tap into the
/// output scaled by per-app volume.
private final class DeviceGraph {
    private let outputDeviceUID: String
    private let ioQueue = DispatchQueue(label: "com.antigravity.AppVolumeMixer.io", qos: .userInteractive)

    private var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private var tapIDs: [AudioObjectID] = []
    // Strong refs to the apps in this graph — released only after the IOProc is
    // destroyed in teardown(), so a volume pointer can never be freed while the
    // running IOProc still reads it (real-time use-after-free guard).
    private var builtApps: [ControlledApp] = []
    private var volTable: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>?

    init(outputDeviceUID: String, apps: [ControlledApp], logger: Logger) throws {
        self.outputDeviceUID = outputDeviceUID
        try build(apps: apps, logger: logger)
    }

    deinit { teardown() }

    private func build(apps: [ControlledApp], logger: Logger) throws {
        // 1. One process tap per app.
        var tapList: [[String: Any]] = []
        var createdTaps: [AudioObjectID] = []
        for app in apps {
            let desc = CATapDescription(stereoMixdownOfProcesses: [app.processObjectID])
            desc.uuid = app.tapUUID
            desc.muteBehavior = .mutedWhenTapped
            desc.name = "AVM-\(app.pid)"
            desc.isPrivate = true

            var tapID: AudioObjectID = .unknown
            let err = AudioHardwareCreateProcessTap(desc, &tapID)
            guard err == noErr, tapID.isValid else {
                for t in createdTaps { AudioHardwareDestroyProcessTap(t) }
                throw "AudioHardwareCreateProcessTap failed for pid \(app.pid): OSStatus \(err)"
            }
            createdTaps.append(tapID)
            tapList.append([
                kAudioSubTapUIDKey as String: app.tapUUID.uuidString,
                kAudioSubTapDriftCompensationKey as String: true,
            ])
        }
        self.tapIDs = createdTaps

        // 2. Output device this graph plays through. Its own input channel count
        //    precedes the taps in the aggregate input layout (offsets the tap
        //    mapping); its preferred stereo pair tells us which output channels
        //    are L/R (channels 0/1 on a multichannel device may be wrong).
        let outDevID = AudioObjectID.readDeviceID(forUID: outputDeviceUID)
        let inputBaseOffset = outDevID?.channelCounts(scope: kAudioObjectPropertyScopeInput).channels ?? 0
        let stereoOut = outDevID?.preferredStereoChannels() ?? (left: 0, right: 1)

        // 3. Aggregate combining the output sub-device + this group's taps.
        let aggUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AppVolumeMixer-\(outputDeviceUID)",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputDeviceUID],
            ],
            kAudioAggregateDeviceTapListKey as String: tapList,
        ]

        var aggID: AudioObjectID = .unknown
        let aggErr = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard aggErr == noErr, aggID.isValid else {
            for t in createdTaps { AudioHardwareDestroyProcessTap(t) }
            self.tapIDs = []
            throw "AudioHardwareCreateAggregateDevice failed for \(outputDeviceUID): OSStatus \(aggErr)"
        }
        self.aggregateID = aggID

        let inCfg = aggID.channelCounts(scope: kAudioObjectPropertyScopeInput)
        let outCfg = aggID.channelCounts(scope: kAudioObjectPropertyScopeOutput)
        let devName = outDevID?.readDeviceName() ?? outputDeviceUID
        logger.info("""
        Graph[\(devName, privacy: .public)] taps=\(apps.count) \
        input channels=\(inCfg.channels) (expected \(inputBaseOffset + apps.count * 2)) \
        output channels=\(outCfg.channels) baseOffset=\(inputBaseOffset) \
        stereoOut=(\(stereoOut.left),\(stereoOut.right))
        """)

        // 4. RT volume-pointer table (tap order) + the mixing IOProc.
        let table = UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>.allocate(capacity: apps.count)
        for (i, app) in apps.enumerated() { table[i] = app.volumePtr }
        self.volTable = table
        self.builtApps = apps   // retain so volumePtrs outlive the IOProc

        let volBase = table.baseAddress!
        let tapCount = apps.count
        let baseOffset = inputBaseOffset
        let outLeftCh = stereoOut.left
        let outRightCh = stereoOut.right

        var newProcID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggID, ioQueue) {
            _, inInputData, _, outOutputData, _ in
            DeviceGraph.render(
                input: inInputData,
                output: outOutputData,
                volumes: volBase,
                tapCount: tapCount,
                inputBaseOffset: baseOffset,
                outLeftCh: outLeftCh,
                outRightCh: outRightCh
            )
        }
        guard procErr == noErr, let liveProc = newProcID else {
            throw "AudioDeviceCreateIOProcIDWithBlock failed: OSStatus \(procErr)"
        }
        self.procID = liveProc

        let startErr = AudioDeviceStart(aggID, liveProc)
        guard startErr == noErr else {
            throw "AudioDeviceStart failed: OSStatus \(startErr)"
        }
    }

    func teardown() {
        if let procID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        for t in tapIDs where t.isValid { AudioHardwareDestroyProcessTap(t) }
        tapIDs = []
        volTable?.deallocate()
        volTable = nil
        // Release apps LAST — strictly after AudioDeviceDestroyIOProcID (which
        // blocks until no render is in flight), so freeing a volumePtr can never
        // race a live IOProc read.
        builtApps = []
    }

    // MARK: - Real-time render

    /// Mixes every stereo tap into the output buffers, scaled by per-app volume.
    /// Allocation-free and lock-free (stack scratch + vDSP). Assumes Float32.
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        volumes: UnsafePointer<UnsafeMutablePointer<Float>>,
        tapCount: Int,
        inputBaseOffset: Int,
        outLeftCh: Int,
        outRightCh: Int
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        withChannelRefs(outList) { outCh, outChCount, outFrames in
            for c in 0..<outChCount {
                vDSP_vclr(outCh[c].base, vDSP_Stride(outCh[c].stride), vDSP_Length(outFrames))
            }
            guard outChCount > 0, tapCount > 0 else { return }

            withChannelRefs(inList) { inCh, inChCount, inFrames in
                let frames = min(outFrames, inFrames)
                guard frames > 0, inChCount > 0 else { return }

                // Route to the device's designated stereo channels (clamped),
                // not blindly to 0/1 — matters on multichannel output devices.
                let leftIdx = min(max(outLeftCh, 0), outChCount - 1)
                let rightIdx = min(max(outRightCh, 0), outChCount - 1)

                for i in 0..<tapCount {
                    let lInIdx = inputBaseOffset + 2 * i
                    let rInIdx = inputBaseOffset + 2 * i + 1
                    guard rInIdx < inChCount else { break }
                    var v = volumes[i].pointee
                    if v == 0 { continue }

                    let l = inCh[lInIdx], r = inCh[rInIdx]
                    let oL = outCh[leftIdx], oR = outCh[rightIdx]
                    vDSP_vsma(l.base, vDSP_Stride(l.stride), &v,
                              oL.base, vDSP_Stride(oL.stride),
                              oL.base, vDSP_Stride(oL.stride), vDSP_Length(frames))
                    vDSP_vsma(r.base, vDSP_Stride(r.stride), &v,
                              oR.base, vDSP_Stride(oR.stride),
                              oR.base, vDSP_Stride(oR.stride), vDSP_Length(frames))
                }

                var lo: Float = -1, hi: Float = 1
                for c in 0..<outChCount {
                    vDSP_vclip(outCh[c].base, vDSP_Stride(outCh[c].stride),
                               &lo, &hi,
                               outCh[c].base, vDSP_Stride(outCh[c].stride),
                               vDSP_Length(frames))
                }
            }
        }
    }

    private struct ChannelRef { var base: UnsafeMutablePointer<Float>; var stride: Int }

    /// Flattens an AudioBufferList into per-channel (base, stride) refs + frame
    /// count, using stack scratch (RT-safe).
    private static func withChannelRefs(
        _ list: UnsafeMutableAudioBufferListPointer,
        _ body: (_ chans: UnsafeMutablePointer<ChannelRef>, _ count: Int, _ frames: Int) -> Void
    ) {
        var total = 0
        for b in 0..<list.count { total += Int(list[b].mNumberChannels) }
        guard total > 0 else {
            withUnsafeTemporaryAllocation(of: ChannelRef.self, capacity: 1) { p in body(p.baseAddress!, 0, 0) }
            return
        }
        withUnsafeTemporaryAllocation(of: ChannelRef.self, capacity: total) { scratch in
            var idx = 0
            var frames = Int.max
            for b in 0..<list.count {
                let buf = list[b]
                let ch = Int(buf.mNumberChannels)
                guard ch > 0, let data = buf.mData else { continue }
                let base = data.assumingMemoryBound(to: Float.self)
                let bufFrames = Int(buf.mDataByteSize) / (MemoryLayout<Float>.size * ch)
                frames = min(frames, bufFrames)
                for c in 0..<ch {
                    scratch[idx] = ChannelRef(base: base + c, stride: ch)
                    idx += 1
                }
            }
            if frames == Int.max { frames = 0 }
            body(scratch.baseAddress!, idx, frames)
        }
    }
}
