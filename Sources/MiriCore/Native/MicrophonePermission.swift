@preconcurrency import AVFoundation
import AppKit
import Foundation

public enum MicrophonePermission: String, Sendable {
    case undetermined, denied, restricted, granted
}

public enum MicrophonePermissions {
    public static var current: MicrophonePermission {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .notDetermined: .undetermined
        case .restricted: .restricted
        case .denied: .denied
        case .authorized: .granted
        @unknown default: .denied
        }
    }

    /// Triggers the system prompt only when permission has not been decided yet.
    public static func request() async -> MicrophonePermission {
        guard current == .undetermined else { return current }
        let allowed = await AVCaptureDevice.requestAccess(for: .audio)
        return allowed ? .granted : .denied
    }

    @MainActor
    public static func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else { return }
        NSWorkspace.shared.open(url)
    }
}
