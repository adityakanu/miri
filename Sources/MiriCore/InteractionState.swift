import Foundation

public enum InteractionState: Equatable, Sendable {
    case idle, listening, transcribing, delivering, speaking
    case failed(String)
}

public enum InteractionEvent: Sendable {
    case pressToTalk, releaseToTalk, transcriptReady, delivered
    case speechStarted, speechFinished, cancel, failure(String)
}

public struct InteractionMachine: Sendable {
    public private(set) var state: InteractionState = .idle
    public init() {}

    @discardableResult public mutating func handle(_ event: InteractionEvent) -> InteractionState {
        switch (state, event) {
        case (_, .cancel), (_, .speechFinished): state = .idle
        case (.idle, .pressToTalk), (.speaking, .pressToTalk): state = .listening
        case (.listening, .releaseToTalk): state = .transcribing
        case (.transcribing, .transcriptReady): state = .delivering
        case (.delivering, .delivered): state = .idle
        case (.idle, .speechStarted): state = .speaking
        case (_, .failure(let message)): state = .failed(message)
        default: break
        }
        return state
    }
}
