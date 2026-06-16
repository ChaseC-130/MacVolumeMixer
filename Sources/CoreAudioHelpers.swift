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
    /// Reads the current default system output device ID.
    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice, defaultValue: AudioDeviceID.unknown)
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
