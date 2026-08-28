import XCTest
@testable import MiriCore

private func makeTarget(_ id: String, project: String? = nil) -> TargetDefinition {
    TargetDefinition(id: id, name: id, adapter: "codex", project: project)
}

final class SessionRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    // MARK: - Context resolver

    func testExplicitTargetAlwaysWins() {
        let chosen = makeTarget("chosen")
        let resolution = ContextResolver.resolve(
            explicitTarget: chosen,
            attention: [.init(request: .init(kind: .approval, title: "Run tests?"), target: makeTarget("other"), adapterBacked: true)],
            sessions: [],
            now: now
        )
        guard case .resolved(let snapshot, let reason) = resolution else { return XCTFail("expected a resolved target") }
        XCTAssertEqual(snapshot.target.id, "chosen")
        XCTAssertEqual(reason, .explicit)
    }

    func testASingleWaitingRequestClaimsTheNextUtterance() {
        let waiting = makeTarget("waiting")
        let resolution = ContextResolver.resolve(
            attention: [.init(request: .init(kind: .approval, title: "Run tests?"), target: waiting, adapterBacked: true)],
            sessions: [.init(target: makeTarget("idle"), status: .ready, lastActiveAt: now, expiresAt: now.addingTimeInterval(30))],
            now: now
        )
        guard case .resolved(let snapshot, let reason) = resolution else { return XCTFail("expected a resolved target") }
        XCTAssertEqual(snapshot.target.id, "waiting")
        XCTAssertEqual(reason, .pendingRequest)
    }

    /// Two agents waiting at once is exactly when guessing is most damaging.
    func testCompetingRequestsAskTheUserInsteadOfGuessing() {
        let resolution = ContextResolver.resolve(
            attention: [
                .init(request: .init(id: "one", kind: .approval, title: "Run tests?"), target: makeTarget("a"), adapterBacked: true),
                .init(request: .init(id: "two", kind: .approval, title: "Delete files?"), target: makeTarget("b"), adapterBacked: true),
            ],
            sessions: [],
            now: now
        )
        guard case .needsSelection(let ids) = resolution else { return XCTFail("expected the HUD to be asked") }
        XCTAssertEqual(ids.sorted(), ["one", "two"])
    }

    func testForegroundProjectPicksItsOwnSession() {
        let resolution = ContextResolver.resolve(
            attention: [],
            sessions: [
                .init(target: makeTarget("miri", project: "miri"), status: .ready, lastActiveAt: now, expiresAt: now.addingTimeInterval(30)),
                .init(target: makeTarget("other", project: "other"), status: .ready, lastActiveAt: now, expiresAt: now.addingTimeInterval(30)),
            ],
            foregroundTargetIDs: ["miri"],
            now: now
        )
        guard case .resolved(let snapshot, let reason) = resolution else { return XCTFail("expected a resolved target") }
        XCTAssertEqual(snapshot.target.id, "miri")
        XCTAssertEqual(reason, .foregroundContext)
    }

    func testFallsBackToTheSessionYouJustSpokeTo() {
        let resolution = ContextResolver.resolve(
            attention: [],
            sessions: [
                .init(target: makeTarget("recent"), status: .ready, lastActiveAt: now, lastUserInteractionAt: now.addingTimeInterval(-20), expiresAt: now.addingTimeInterval(30)),
                .init(target: makeTarget("stale"), status: .ready, lastActiveAt: now, lastUserInteractionAt: now.addingTimeInterval(-9_000), expiresAt: now.addingTimeInterval(30)),
            ],
            now: now
        )
        guard case .resolved(let snapshot, let reason) = resolution else { return XCTFail("expected a resolved target") }
        XCTAssertEqual(snapshot.target.id, "recent")
        XCTAssertEqual(reason, .recentSession)
    }

    func testNoSessionsAndNoDefaultReportsNoTarget() {
        let resolution = ContextResolver.resolve(attention: [], sessions: [], now: now)
        guard case .noTarget = resolution else { return XCTFail("expected noTarget") }
    }

    func testPinnedDefaultIsTheLastResortBeforeGivingUp() {
        let resolution = ContextResolver.resolve(
            attention: [],
            sessions: [],
            pinnedDefault: makeTarget("pinned"),
            now: now
        )
        guard case .resolved(let snapshot, let reason) = resolution else { return XCTFail("expected a resolved target") }
        XCTAssertEqual(snapshot.target.id, "pinned")
        XCTAssertEqual(reason, .pinnedDefault)
    }

    /// An expired request must not silently capture the microphone.
    func testExpiredRequestsAreIgnoredWhenResolving() {
        let resolution = ContextResolver.resolve(
            attention: [
                .init(
                    request: .init(kind: .approval, title: "Run tests?"),
                    target: makeTarget("expired"),
                    adapterBacked: true,
                    expiresAt: now.addingTimeInterval(-1)
                )
            ],
            sessions: [],
            pinnedDefault: makeTarget("pinned"),
            now: now
        )
        guard case .resolved(let snapshot, _) = resolution else { return XCTFail("expected a resolved target") }
        XCTAssertEqual(snapshot.target.id, "pinned")
    }

    /// The exact shape the app used to get wrong.
    ///
    /// `AppController` passed the user's chosen target as `pinnedDefault` — the
    /// lowest-priority rule — and never populated `explicitTarget`. Any agent
    /// with a question outranked the deliberate pick, so the utterance went
    /// somewhere the user had not selected. A choice must arrive as
    /// `explicitTarget`, and it must win.
    func testAChosenTargetBeatsAWaitingRequestAndTheConfiguredDefault() {
        let chosen = makeTarget("chosen")
        let resolution = ContextResolver.resolve(
            explicitTarget: chosen,
            attention: [
                .init(request: .init(kind: .question, title: "Which branch?"), target: makeTarget("noisy"), adapterBacked: true)
            ],
            sessions: [
                .init(target: makeTarget("foreground"), status: .ready, lastActiveAt: now, expiresAt: now.addingTimeInterval(30))
            ],
            foregroundTargetIDs: ["foreground"],
            pinnedDefault: makeTarget("configured-default"),
            now: now
        )
        guard case .resolved(let snapshot, let reason) = resolution else { return XCTFail("expected a resolved target") }
        XCTAssertEqual(snapshot.target.id, "chosen")
        XCTAssertEqual(reason, .explicit)
    }

    /// Passing the same target as `pinnedDefault` instead — the old behaviour —
    /// demonstrably loses to a pending request.
    func testPassingAChoiceAsThePinnedDefaultLosesToAPendingRequest() {
        let resolution = ContextResolver.resolve(
            attention: [
                .init(request: .init(kind: .question, title: "Which branch?"), target: makeTarget("noisy"), adapterBacked: true)
            ],
            sessions: [],
            pinnedDefault: makeTarget("chosen"),
            now: now
        )
        guard case .resolved(let snapshot, let reason) = resolution else { return XCTFail("expected a resolved target") }
        XCTAssertEqual(snapshot.target.id, "noisy", "this is the regression the explicit path exists to prevent")
        XCTAssertEqual(reason, .pendingRequest)
    }
}
