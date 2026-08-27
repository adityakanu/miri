import AppKit
import Foundation

/// Types the transcript into whatever application currently has keyboard focus.
///
/// This is the "dictate anywhere" target: instead of routing to a coding agent,
/// the utterance lands wherever the caret already is — an editor, a browser
/// field, a terminal, a chat box.
///
/// Text is delivered as synthesized Unicode key events rather than a paste, so
/// the user's clipboard is never touched. macOS requires Accessibility
/// permission to post events into another application; without it the adapter
/// fails loudly rather than silently dropping the utterance.
public final class FocusedAppAdapter: AgentAdapter, @unchecked Sendable {
    public let id: String
    public let capabilities: AdapterCapabilities = []

    /// Posts one chunk of text to the focused application. Injected so the
    /// chunking and permission logic can be tested without a window server.
    private let post: @Sendable (String) -> Void
    private let hasPermission: @Sendable () -> Bool

    public init(
        id: String = "cursor",
        hasPermission: @escaping @Sendable () -> Bool = { AccessibilityPermission.isGranted },
        post: (@Sendable (String) -> Void)? = nil
    ) {
        self.id = id
        self.hasPermission = hasPermission
        self.post = post ?? Self.postUnicode
    }

    public func connect() async throws {}
    public func disconnect() async {}

    /// Reports `.failed` without Accessibility permission so the menu bar shows
    /// the target is unusable before the user speaks into it.
    public func status() async -> TargetStatus { hasPermission() ? .ready : .failed }

    public func sendUserMessage(_ text: String) async throws -> DeliveryReceipt {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .init(messageID: UUID(), disposition: .delivered) }
        guard hasPermission() else { throw FocusedAppError.accessibilityDenied }
        for chunk in Self.chunks(of: trimmed) { post(chunk) }
        return .init(messageID: UUID(), disposition: .delivered)
    }

    public func cancelTurn() async throws { throw AdapterError.noRunningTurn }
    public func events() -> AsyncStream<AgentEvent> { AsyncStream { $0.finish() } }

    /// `CGEventKeyboardSetUnicodeString` takes a bounded UTF-16 buffer, so long
    /// dictation is split. Chunks split on UTF-16 count, not characters, so an
    /// emoji or combining mark is never cut in half.
    static let maximumChunkUTF16Length = 20

    static func chunks(of text: String, limit: Int = maximumChunkUTF16Length) -> [String] {
        var chunks: [String] = []
        var current = ""
        for character in text {
            if current.utf16.count + character.utf16.count > limit, !current.isEmpty {
                chunks.append(current)
                current = ""
            }
            current.append(character)
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static let postUnicode: @Sendable (String) -> Void = { chunk in
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        var utf16 = Array(chunk.utf16)
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

public enum FocusedAppError: Error, Equatable, LocalizedError {
    case accessibilityDenied

    public var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            "Miri needs Accessibility permission to type into other apps. Grant it in System Settings › Privacy & Security › Accessibility."
        }
    }
}
