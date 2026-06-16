import Foundation
import AudioToolbox
import Darwin

// MARK: - Constants and Extensions

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isUnknown: Bool { self == .unknown }
    var isValid: Bool { !isUnknown }
}

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

// MARK: - Concrete Property Helpers

extension AudioObjectID {
    /// Reads the current default OUTPUT device — the device regular application
    /// audio plays through (what the user picks in Sound settings / Control
    /// Center). NOTE: deliberately kAudioHardwarePropertyDefaultOutputDevice, NOT
    /// kAudioHardwarePropertyDefaultSystemOutputDevice — the latter is only the
    /// system alert / UI-sounds device and is frequently a different device.
    static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultOutputDevice, defaultValue: AudioDeviceID.unknown)
    }

    /// Reads all audio device object IDs known to the system.
    static func readAllDeviceIDs() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(.system, &address, 0, nil, &dataSize)
        guard err == noErr else { throw "Failed to get device list size: \(err)" }
        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var value = [AudioObjectID](repeating: .unknown, count: count)
        err = AudioObjectGetPropertyData(.system, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { throw "Failed to get device list: \(err)" }
        return value
    }

    /// Translates a device UID string back to its AudioDeviceID, or nil if no
    /// such device is currently present.
    static func readDeviceID(forUID uid: String) -> AudioObjectID? {
        guard let id: AudioObjectID = try? AudioObjectID.system.read(
            kAudioHardwarePropertyTranslateUIDToDevice,
            defaultValue: AudioObjectID.unknown,
            qualifier: uid as CFString
        ), id.isValid else { return nil }
        return id
    }

    /// Human-readable device name.
    func readDeviceName() -> String {
        if let n = try? readString(kAudioObjectPropertyName), !n.isEmpty { return n }
        if let n = try? readString(kAudioDevicePropertyDeviceNameCFString), !n.isEmpty { return n }
        return "Unknown Device"
    }

    /// True if the device exposes any output channels (i.e. is a playback device).
    var hasOutputStreams: Bool { channelCounts(scope: kAudioObjectPropertyScopeOutput).channels > 0 }

    /// The device's designated stereo (left, right) output channels as 0-based
    /// indices. On a multichannel device (e.g. a display with a speaker array)
    /// the stereo pair is not necessarily channels 0/1. Returns nil if the
    /// device doesn't advertise a preferred stereo pair.
    func preferredStereoChannels() -> (left: Int, right: Int)? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyPreferredChannelsForStereo,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var chans: [UInt32] = [0, 0]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        let err = AudioObjectGetPropertyData(self, &addr, 0, nil, &size, &chans)
        guard err == noErr, chans[0] >= 1, chans[1] >= 1 else { return nil }
        return (Int(chans[0]) - 1, Int(chans[1]) - 1)   // property is 1-based
    }

    /// Reads all active Core Audio process object IDs.
    static func readProcessList() throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(.system, &address, 0, nil, &dataSize)
        guard err == noErr else { throw "Failed to get process list size: \(err)" }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var value = [AudioObjectID](repeating: .unknown, count: count)
        err = AudioObjectGetPropertyData(.system, &address, 0, nil, &dataSize, &value)
        guard err == noErr else { throw "Failed to get process list: \(err)" }

        return value
    }

    /// Translates a PID to a Core Audio process object ID.
    static func translatePIDToProcessObjectID(pid: pid_t) throws -> AudioObjectID {
        let processObject = try AudioObjectID.system.read(
            kAudioHardwarePropertyTranslatePIDToProcessObject,
            defaultValue: AudioObjectID.unknown,
            qualifier: pid
        )
        guard processObject.isValid else {
            throw "Invalid process identifier for PID: \(pid)"
        }
        return processObject
    }

    /// Reads the bundle identifier of an audio process object.
    func readProcessBundleID() -> String? {
        if let result = try? readString(kAudioProcessPropertyBundleID) {
            return result.isEmpty ? nil : result
        }
        return nil
    }

    /// Reads whether the process is currently running audio.
    func readProcessIsRunning() -> Bool {
        (try? readBool(kAudioProcessPropertyIsRunning)) ?? false
    }

    /// Reads the device UID for an audio device.
    func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    /// Reads the basic stream format description of an audio tap.
    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    /// Returns (bufferCount, totalChannels) for a device's stream configuration
    /// in the given scope. Used for diagnostics / verifying the tap→channel
    /// mapping of the aggregate device. Returns (0,0) on any error.
    func channelCounts(scope: AudioObjectPropertyScope) -> (buffers: Int, channels: Int) {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(self, &addr, 0, nil, &size) == noErr, size > 0 else { return (0, 0) }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(self, &addr, 0, nil, &size, raw) == noErr else { return (0, 0) }
        let abl = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        var channels = 0
        for b in 0..<abl.count { channels += Int(abl[b].mNumberChannels) }
        return (abl.count, channels)
    }
}

// MARK: - Generic Property Access

extension AudioObjectID {
    func read<T, Q>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T,
        qualifier: Q
    ) throws -> T {
        try read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element), defaultValue: defaultValue, qualifier: qualifier)
    }

    func read<T>(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
        defaultValue: T
    ) throws -> T {
        try read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element), defaultValue: defaultValue)
    }

    func read<T, Q>(_ address: AudioObjectPropertyAddress, defaultValue: T, qualifier: Q) throws -> T {
        var inQualifier = qualifier
        let qualifierSize = UInt32(MemoryLayout<Q>.size(ofValue: qualifier))
        return try withUnsafeMutablePointer(to: &inQualifier) { qualifierPtr in
            try read(address, defaultValue: defaultValue, inQualifierSize: qualifierSize, inQualifierData: qualifierPtr)
        }
    }

    func read<T>(_ address: AudioObjectPropertyAddress, defaultValue: T) throws -> T {
        try read(address, defaultValue: defaultValue, inQualifierSize: 0, inQualifierData: nil)
    }

    func readString(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> String {
        try read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element), defaultValue: "" as CFString) as String
    }

    func readBool(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) throws -> Bool {
        let value: Int = try read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element), defaultValue: 0)
        return value == 1
    }

    private func read<T>(
        _ inAddress: AudioObjectPropertyAddress,
        defaultValue: T,
        inQualifierSize: UInt32 = 0,
        inQualifierData: UnsafeRawPointer? = nil
    ) throws -> T {
        var address = inAddress
        var dataSize: UInt32 = 0

        var err = AudioObjectGetPropertyDataSize(self, &address, inQualifierSize, inQualifierData, &dataSize)
        guard err == noErr else {
            throw "Error reading data size for \(inAddress): \(err)"
        }

        var value: T = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, inQualifierSize, inQualifierData, &dataSize, ptr)
        }
        guard err == noErr else {
            throw "Error reading data for \(inAddress): \(err)"
        }

        return value
    }
}
