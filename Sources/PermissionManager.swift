import Foundation
import OSLog

enum AudioCapturePermission: Equatable {
    case unknown      // not yet determined — we can prompt
    case denied       // user said no — must go to System Settings
    case authorized   // good to go
}

/// Thin wrapper over the private TCC.framework entry points used to preflight
/// and request the System Audio Capture permission (`kTCCServiceAudioCapture`)
/// that Core Audio process taps require. This is the same approach AudioCap
/// uses; it is SPI, acceptable for a locally-built utility.
enum PermissionManager {
    private static let logger = Logger(subsystem: "com.antigravity.AppVolumeMixer", category: "Permission")
    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias PreflightFn = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFn = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? =
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/TCC", RTLD_NOW)

    /// Synchronous, non-prompting status check.
    static func preflight() -> AudioCapturePermission {
        guard let handle, let sym = dlsym(handle, "TCCAccessPreflight") else {
            logger.error("TCCAccessPreflight unavailable")
            return .unknown
        }
        let fn = unsafeBitCast(sym, to: PreflightFn.self)
        switch fn(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .unknown   // 2 == not determined
        }
    }

    /// Prompts the user (first time only) and reports the result on the main queue.
    static func request(_ completion: @escaping (Bool) -> Void) {
        guard let handle, let sym = dlsym(handle, "TCCAccessRequest") else {
            logger.error("TCCAccessRequest unavailable")
            DispatchQueue.main.async { completion(false) }
            return
        }
        let fn = unsafeBitCast(sym, to: RequestFn.self)
        fn(service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
