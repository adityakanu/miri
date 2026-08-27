import Foundation

/// The outcome of answering an agent's approval request by voice.
///
/// Extracted from `AppController` because every stop-ship on this branch lived
/// in the approval path and none of it was reachable from a test: the queue
/// types were tested in isolation while the decisions were made in a 1400-line
/// `@MainActor` controller. This keeps the decision pure and testable without
/// reshaping the controller.
public enum ApprovalOutcome: Equatable, Sendable {
    /// The transcript was not a recognised decision. Nothing was sent.
    case notUnderstood
    /// The decision reached the agent.
    case delivered(AgentInteractionResponse)
    /// The decision did NOT reach the agent — a dead pipe, a failed write.
    case notDelivered(String)

    /// Whether the request must stay answerable. A decision that never left
    /// the machine must not clear the request, or a lost "deny" silently looks
    /// like a delivered one on a permission boundary.
    public var requestRemainsPending: Bool {
        switch self {
        case .notUnderstood, .notDelivered: true
        case .delivered: false
        }
    }

    /// Whether the user may be told their decision took effect.
    public var reportsSuccess: Bool {
        if case .delivered = self { return true }
        return false
    }

    public func statusMessage(targetName: String) -> String {
        switch self {
        case .notUnderstood:
            "Approval unchanged. Say exactly: approve request, or deny request."
        case .delivered(let response):
            response == .approve ? "Approved for \(targetName)" : "Denied for \(targetName)"
        case .notDelivered:
            "Could not send your decision to \(targetName). The request is still waiting."
        }
    }

    /// Resolves a transcript against a delivery attempt.
    ///
    /// `deliver` performs the send and throws if the decision did not reach
    /// the agent. Nothing is sent when the transcript is not a decision.
    public static func resolve(
        transcript: String,
        deliver: sending (AgentInteractionResponse) async throws -> Void
    ) async -> Self {
        guard let response = VoiceApprovalParser.parse(transcript) else {
            return .notUnderstood
        }
        do {
            try await deliver(response)
            return .delivered(response)
        } catch {
            return .notDelivered(error.localizedDescription)
        }
    }
}
