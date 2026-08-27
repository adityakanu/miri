import XCTest
@testable import MiriCore

private func makeTarget(_ id: String, project: String? = nil) -> TargetDefinition {
    TargetDefinition(id: id, name: id, adapter: "codex", project: project)
}

final class SessionRoutingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    // MARK: - Live session directory

    func testExpiredSessionsDisappearWithoutBeingRemovedByHand() async {
        let directory = LiveSessionDirectory()
        await directory.observe(.init(target: makeTarget("a"), status: .ready, lastActiveAt: now, expiresAt: now.addingTimeInterval(30)))
        await directory.observe(.init(target: makeTarget("b"), status: .ready, lastActiveAt: now, expiresAt: now.addingTimeInterval(5)))

        let live = await directory.sessions(at: now.addingTimeInterval(10))
        XCTAssertEqual(live.map(\.id), ["a"])
    }

    func testObservingTheSameSessionUpdatesRatherThanDuplicates() async {
        let directory = LiveSessionDirectory()
        await directory.observe(.init(target: makeTarget("a"), status: .ready, lastActiveAt: now, expiresAt: now.addingTimeInterval(30)))
        await directory.observe(.init(target: makeTarget("a"), status: .busy, lastActiveAt: now, expiresAt: now.addingTimeInterval(30)))

        let live = await directory.sessions(at: now)
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.status, .busy)
    }

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
}
