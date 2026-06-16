import Foundation
import AudioToolbox
import CoreAudio
import Accelerate
import OSLog

/// A single app whose output volume the engine controls.
///
/// The `volume` pointer is the real-time source of truth: it is read on the
/// audio I/O thread and written from the main thread. It is a bare
/// `UnsafeMutablePointer<Float>` (not ARC-managed) so the I/O block can capture
/// it by value with zero retain/release traffic. On arm64 an aligned 4-byte
/// load/store is tear-free, so a relaxed read on the RT thread is safe in
/// practice; the value is only ever a volume scalar.
final class ControlledApp: Identifiable {
    let processObjectID: AudioObjectID   // Core Audio process object — engine identity
    let pid: pid_t
    let key: String                      // bundleID ?? executable name — persistent volume key
    let tapUUID = UUID()
    let volumePtr: UnsafeMutablePointer<Float>

    init(processObjectID: AudioObjectID, pid: pid_t, key: String, initialVolume: Float) {
        self.processObjectID = processObjectID
        self.pid = pid
        self.key = key
        self.volumePtr = .allocate(capacity: 1)
        self.volumePtr.initialize(to: initialVolume)
    }

    deinit { volumePtr.deallocate() }

    var volume: Float { volumePtr.pointee }
    func setVolume(_ v: Float) { volumePtr.pointee = v }
}

/// Owns ONE private aggregate device that wraps the current default output
/// device plus one process tap per controlled app, and a single I/O proc that
/// mixes every tap into the output scaled by that app's volume.
///
/// This is the canonical "AudioCap-style" routing: a stereo mixdown tap per app
/// (muted from its normal path via `.mutedWhenTapped`) re-rendered through one
/// aggregate. Creating a separate aggregate per app instead makes them contend
/// for the same hardware and mute each other.
final class AudioMixerEngine {
    private let logger = Logger(subsystem: "com.antigravity.AppVolumeMixer", category: "Engine")
    private let ioQueue = DispatchQueue(label: "com.antigravity.AppVolumeMixer.io", qos: .userInteractive)

    // Currently-built graph.
    private var aggregateID: AudioObjectID = .unknown
    private var procID: AudioDeviceIOProcID?
    private var tapIDs: [AudioObjectID] = []
    private(set) var builtKeys: [AudioObjectID] = []   // process object IDs in the live aggregate, in tap order
    private var outputDeviceUID: String?

    // RT-captured table of volume pointers, in tap order. Heap-allocated and
    // freed on teardown; captured by the I/O block as a raw base pointer so the
    // block never touches Swift Array machinery on the audio thread.
    private var volTable: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>?

    // Strong refs to the apps in the live graph. Held until teardown destroys
    // the IOProc, so a ControlledApp's volume pointer cannot be freed while the
    // running IOProc still reads it (real-time use-after-free guard).
    private var builtApps: [ControlledApp] = []

    // Default-output-device change listener. Block + address are kept so we can
    // unregister it (Core Audio retains the block until explicitly removed).
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var deviceListenerAddr = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    /// Invoked on the main actor when the system default output device changes,
    /// so the owner can rebuild with the current app set.
    var onDefaultDeviceChanged: (() -> Void)?

    var isRunning: Bool { procID != nil }

    // MARK: - Public

    /// Tear down the current graph and rebuild it for `apps` (tap order = array
    /// order). Pass an empty array to fully stop. Safe to call repeatedly; the
    /// caller should only call it when the membership set actually changes.
    /// Throws if the OS refuses to create the tap/aggregate (e.g. permission).
    func rebuild(with apps: [ControlledApp]) throws {
        teardown()
        guard !apps.isEmpty else {
            logger.info("Engine idle (no apps to control)")
            return
        }
        do {
            try build(apps)
            logger.info("Engine running with \(apps.count) tap(s)")
        } catch {
            logger.error("Engine build failed: \(error.localizedDescription)")
            teardown()
            throw error
        }
    }

    /// Same membership, but the volume pointers already updated in place — no
    /// rebuild needed because volumes are read live on the RT thread.
    func stop() { teardown() }

    // MARK: - Build / teardown

    private func build(_ apps: [ControlledApp]) throws {
        // 1. Create one process tap per app.
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
                // Roll back taps already created this pass.
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

        // 2. Resolve the default output device UID (drift master / playback sink).
        let outputID = try AudioObjectID.readDefaultSystemOutputDevice()
        let outputUID = try outputID.readDeviceUID()
        self.outputDeviceUID = outputUID

        // If the output device also exposes input streams, those input channels
        // appear FIRST in the aggregate's input layout, shifting the taps. Offset
        // the tap channel mapping past them. (Plain speakers/headphones expose 0
        // input channels, so this is usually 0.)
        let inputBaseOffset = outputID.channelCounts(scope: kAudioObjectPropertyScopeInput).channels

        // 3. Aggregate combining the output sub-device + all taps.
        let aggUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "AppVolumeMixer",
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: outputUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: outputUID],
            ],
            kAudioAggregateDeviceTapListKey as String: tapList,
        ]

        var aggID: AudioObjectID = .unknown
        let aggErr = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggID)
        guard aggErr == noErr, aggID.isValid else {
            for t in createdTaps { AudioHardwareDestroyProcessTap(t) }
            self.tapIDs = []
            throw "AudioHardwareCreateAggregateDevice failed: OSStatus \(aggErr)"
        }
        self.aggregateID = aggID

        logStreamLayout(aggID, tapCount: apps.count)

        // 4. Build the RT volume-pointer table (tap order).
        let table = UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>.allocate(capacity: apps.count)
        for (i, app) in apps.enumerated() { table[i] = app.volumePtr }
        self.volTable = table
        self.builtKeys = apps.map(\.processObjectID)
        self.builtApps = apps   // retain so volumePtrs outlive the IOProc

        let volBase = table.baseAddress!
        let tapCount = apps.count
        let baseOffset = inputBaseOffset

        // 5. One mixing I/O proc. Captures only trivial values (raw pointers,
        //    Int) — no self, no ARC, no locks → real-time safe.
        var newProcID: AudioDeviceIOProcID?
        let procErr = AudioDeviceCreateIOProcIDWithBlock(&newProcID, aggID, ioQueue) {
            _, inInputData, _, outOutputData, _ in
            AudioMixerEngine.render(
                input: inInputData,
                output: outOutputData,
                volumes: volBase,
                tapCount: tapCount,
                inputBaseOffset: baseOffset
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

        installDefaultDeviceListener()
    }

    private func teardown() {
        if let procID, aggregateID.isValid {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        self.procID = nil

        if aggregateID.isValid {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = .unknown
        }
        for t in tapIDs where t.isValid { AudioHardwareDestroyProcessTap(t) }
        tapIDs = []

        volTable?.deallocate()
        volTable = nil
        builtKeys = []
        outputDeviceUID = nil
        // Release the apps LAST — strictly after AudioDeviceDestroyIOProcID
        // (which blocks until no render is in flight), so freeing a volumePtr can
        // never race a live IOProc read.
        builtApps = []
    }

    deinit {
        removeDefaultDeviceListener()
        teardown()
    }

    // MARK: - Real-time render

    /// Mixes every stereo tap into the output buffers, scaled by per-app volume.
    ///
    /// Runs on the audio I/O thread. Allocation-free and lock-free: channel
    /// pointer tables use stack scratch (`withUnsafeTemporaryAllocation`) and the
    /// math is vDSP. Assumes Float32 streams (the tap mixdown and aggregate
    /// streams are Float32 on macOS); non-Float streams would be skipped to
    /// silence rather than mis-scaled.
    private static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        volumes: UnsafePointer<UnsafeMutablePointer<Float>>,
        tapCount: Int,
        inputBaseOffset: Int
    ) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        // Flatten output channels first; we always need them (to zero them).
        withChannelRefs(outList) { outCh, outChCount, outFrames in
            // Zero every output channel — anything we don't fill stays silent
            // (e.g. surround channels, or all of it if input is unusable).
            for c in 0..<outChCount {
                vDSP_vclr(outCh[c].base, vDSP_Stride(outCh[c].stride), vDSP_Length(outFrames))
            }
            guard outChCount > 0, tapCount > 0 else { return }

            withChannelRefs(inList) { inCh, inChCount, inFrames in
                let frames = min(outFrames, inFrames)
                guard frames > 0, inChCount > 0 else { return }

                let leftIdx = 0
                let rightIdx = outChCount >= 2 ? 1 : 0   // mono output: fold R into ch0

                // Each tap contributes 2 flattened input channels (stereo), in
                // tap order: tap i -> input channels [2i, 2i+1].
                for i in 0..<tapCount {
                    let lInIdx = inputBaseOffset + 2 * i
                    let rInIdx = inputBaseOffset + 2 * i + 1
                    guard rInIdx < inChCount else { break }
                    var v = volumes[i].pointee
                    if v == 0 { continue }                // muted — contributes nothing

                    // out[L] += in[L] * v   ;   out[R] += in[R] * v   (accumulate)
                    let l = inCh[lInIdx], r = inCh[rInIdx]
                    let oL = outCh[leftIdx], oR = outCh[rightIdx]
                    vDSP_vsma(l.base, vDSP_Stride(l.stride), &v,
                              oL.base, vDSP_Stride(oL.stride),
                              oL.base, vDSP_Stride(oL.stride), vDSP_Length(frames))
                    vDSP_vsma(r.base, vDSP_Stride(r.stride), &v,
                              oR.base, vDSP_Stride(oR.stride),
                              oR.base, vDSP_Stride(oR.stride), vDSP_Length(frames))
                }

                // Clip the mixed region to [-1, 1] so >100% boosts don't emit
                // out-of-range samples. Only `frames` were mixed; the zeroed tail
                // (already cleared above) needs no clipping.
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

    /// A single logical audio channel: base pointer + element stride.
    private struct ChannelRef { var base: UnsafeMutablePointer<Float>; var stride: Int }

    /// Flattens an AudioBufferList into per-channel (base, stride) refs and the
    /// frame count, using stack scratch (RT-safe). Interleaved buffers expose
    /// `mNumberChannels` channels at stride = channel count; deinterleaved
    /// buffers expose one channel at stride 1.
    private static func withChannelRefs(
        _ list: UnsafeMutableAudioBufferListPointer,
        _ body: (_ chans: UnsafeMutablePointer<ChannelRef>, _ count: Int, _ frames: Int) -> Void
    ) {
        // Count total channels.
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

    // MARK: - Default device change

    private func installDefaultDeviceListener() {
        guard deviceListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            // Listener fires on DispatchQueue.main; hop to the main actor so the
            // callback into MainActor-isolated state is statically correct.
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

    // MARK: - Diagnostics

    private func logStreamLayout(_ device: AudioObjectID, tapCount: Int) {
        let inCfg = device.channelCounts(scope: kAudioObjectPropertyScopeInput)
        let outCfg = device.channelCounts(scope: kAudioObjectPropertyScopeOutput)
        logger.info("""
        Aggregate built: taps=\(tapCount) \
        input buffers=\(inCfg.buffers) channels=\(inCfg.channels) (expected \(tapCount * 2)) \
        output buffers=\(outCfg.buffers) channels=\(outCfg.channels)
        """)
    }
}
