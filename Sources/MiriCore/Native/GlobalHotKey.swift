import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import Foundation

public struct KeyboardShortcut: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier flags (`optionKey`, `shiftKey`, `controlKey`, `cmdKey`).
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static let optionSpace = KeyboardShortcut(
        keyCode: UInt32(kVK_Space),
        modifiers: UInt32(optionKey)
    )

    public static func parse(_ value: String) throws -> KeyboardShortcut {
        let parts = value.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty else { throw KeyboardShortcutError.invalid(value) }
        var modifiers: UInt32 = 0
        for modifier in parts.dropLast() {
            switch modifier {
            case "option", "alt": modifiers |= UInt32(optionKey)
            case "shift": modifiers |= UInt32(shiftKey)
            case "control", "ctrl": modifiers |= UInt32(controlKey)
            case "command", "cmd": modifiers |= UInt32(cmdKey)
            default: throw KeyboardShortcutError.invalid(value)
            }
        }
        let keyCodes: [String: Int] = [
            "space": kVK_Space, "return": kVK_Return, "enter": kVK_Return, "tab": kVK_Tab,
            "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D,
            "e": kVK_ANSI_E, "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H,
            "i": kVK_ANSI_I, "j": kVK_ANSI_J, "k": kVK_ANSI_K, "l": kVK_ANSI_L,
            "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O, "p": kVK_ANSI_P,
            "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
            "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X,
            "y": kVK_ANSI_Y, "z": kVK_ANSI_Z,
            "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
            "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7,
            "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        ]
        guard let keyCode = keyCodes[String(key)], modifiers != 0 else { throw KeyboardShortcutError.invalid(value) }
        return .init(keyCode: UInt32(keyCode), modifiers: modifiers)
    }
}

public enum KeyboardShortcutError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { "Invalid shortcut '\(value)'. Example: option+shift+c" }
    private var value: String { if case .invalid(let value) = self { value } else { "" } }
}

public enum GlobalHotKeyEvent: Equatable, Sendable {
    case pressed(identifier: UInt32)
    case released(identifier: UInt32)
    case cancelled
}

public enum GlobalHotKeyError: LocalizedError {
    case registrationFailed(OSStatus)
    case eventHandlerFailed(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .registrationFailed(let status): "The shortcut is unavailable (OSStatus \(status))."
        case .eventHandlerFailed(let status): "The global shortcut handler could not start (OSStatus \(status))."
        }
    }
}

/// Carbon hot keys provide press and release events without requiring Accessibility permission.
/// Escape is observed only while an interaction is active and is never consumed from the frontmost app.
@MainActor
public final class GlobalHotKeyController: @unchecked Sendable {
    public typealias Handler = @MainActor (GlobalHotKeyEvent) -> Void

    nonisolated private static let signature: OSType = 0x4D_49_52_49 // "MIRI"
    private var handler: Handler?
    private var eventHandler: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]
    private var localEscapeMonitor: Any?
    private var globalEscapeMonitor: Any?
    private var cancellationEnabled = false

    public init(handler: @escaping Handler) throws {
        self.handler = handler
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
                var id = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard result == noErr, id.signature == GlobalHotKeyController.signature else { return OSStatus(eventNotHandledErr) }
                let kind = GetEventKind(event)
                MainActor.assumeIsolated {
                    controller.handler?(kind == UInt32(kEventHotKeyPressed)
                        ? .pressed(identifier: id.id)
                        : .released(identifier: id.id))
                }
                return noErr
            },
            specs.count,
            &specs,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { throw GlobalHotKeyError.eventHandlerFailed(status) }
        installEscapeMonitors()
    }

    public func register(_ shortcut: KeyboardShortcut, identifier: UInt32) throws {
        unregister(identifier: identifier)
        var reference: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &reference
        )
        guard status == noErr, let reference else { throw GlobalHotKeyError.registrationFailed(status) }
        registrations[identifier] = reference
    }

    public func unregister(identifier: UInt32) {
        guard let reference = registrations.removeValue(forKey: identifier) else { return }
        UnregisterEventHotKey(reference)
    }

    public func unregisterAll() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
    }

    public func enableEscapeCancellation(_ enabled: Bool) {
        cancellationEnabled = enabled
    }

    private func installEscapeMonitors() {
        localEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == UInt16(kVK_Escape) {
                MainActor.assumeIsolated { self?.sendCancellationIfEnabled() }
            }
            return event
        }
        globalEscapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == UInt16(kVK_Escape) else { return }
            Task { @MainActor [weak self] in self?.sendCancellationIfEnabled() }
        }
    }

    private func sendCancellationIfEnabled() {
        guard cancellationEnabled else { return }
        handler?(.cancelled)
    }

    /// Release registrations before discarding the controller. The app calls this
    /// from its main-actor shutdown path; process termination is the final fallback.
    public func shutdown() {
        for reference in registrations.values { UnregisterEventHotKey(reference) }
        registrations.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
        if let localEscapeMonitor { NSEvent.removeMonitor(localEscapeMonitor) }
        localEscapeMonitor = nil
        if let globalEscapeMonitor { NSEvent.removeMonitor(globalEscapeMonitor) }
        globalEscapeMonitor = nil
    }
}

public enum AccessibilityPermission {
    public static var isGranted: Bool { AXIsProcessTrusted() }

    /// Displays Apple's Accessibility prompt when global event observation needs it.
    @discardableResult
    public static func requestIfNeeded() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
