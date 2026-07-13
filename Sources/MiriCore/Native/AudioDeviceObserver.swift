@preconcurrency import AVFoundation
import AppKit
import Foundation

public enum AudioDeviceChange: Sendable, Equatable {
    case engineConfigurationChanged
    case deviceConnected(String)
    case deviceDisconnected(String)
}

/// Consolidates the AVFoundation notifications that require capture/playback graphs to be rebuilt.
@MainActor
public final class AudioDeviceObserver {
    public typealias Handler = @MainActor (AudioDeviceChange) -> Void

    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []
    private var handler: Handler?

    public init(center: NotificationCenter = .default, handler: @escaping Handler) {
        self.center = center
        self.handler = handler
        tokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handler?(.engineConfigurationChanged) }
        })
        tokens.append(center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let name = (notification.object as? AVCaptureDevice)?.localizedName ?? "Audio device"
            MainActor.assumeIsolated { self?.handler?(.deviceConnected(name)) }
        })
        tokens.append(center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let name = (notification.object as? AVCaptureDevice)?.localizedName ?? "Audio device"
            MainActor.assumeIsolated { self?.handler?(.deviceDisconnected(name)) }
        })
    }

    deinit {
        for token in tokens { center.removeObserver(token) }
    }
}

@MainActor
public final class AccessibilityDisplayObserver {
    public typealias Handler = @MainActor (Bool) -> Void
    private var token: NSObjectProtocol?
    private var handler: Handler?

    public var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    public init(handler: @escaping Handler) {
        self.handler = handler
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.handler?(self.reduceMotion)
            }
        }
    }

    deinit {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    }
}
