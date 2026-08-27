# Miri session handoff — 2026-08-27

Pick up here. This supersedes the status block at the top of
`docs/next-session-handoff.md`; that file's design sections are still accurate
and worth reading, but its "still outstanding" list is now stale.

## Where things stand

Branch: `feature/release-readiness-agent-hud`
HEAD: `49aeb2b`
16 commits ahead of `main`. **Nothing pushed to `origin`.** Working tree clean.

- `swift test`: **105 executed, 102 passed, 3 skipped, 0 failures**, zero
  warnings. The 3 skips assert the model-*not*-installed path and skip because
  this machine has the models.
- `swift build`: clean on Swift 6.2.1.
- Artifacts rebuilt and verified from HEAD: `.preview/Miri.app` 57 MB arm64-only,
  `dist/Miri-0.1.4.dmg` 30 MB, `.zip` 28 MB, signature valid, checksums OK, DMG
  CRC valid, three license files bundled.

Do not tag `v0.1.4` yet. See "What must happen before tagging".

## Do this first

The independent review found 11 issues. Two stop-ships are fixed (`49aeb2b`);
**two remain open**, plus should-fix items. Full report:
`/Users/adityakanu/.hermes/cache/delegation/subagent-summary-0-20260827_165339_806636.txt`

### STOP-SHIP A — approval/deny failures are swallowed; UI reports success

`Sources/MiriCore/CodexAppServerAdapter.swift:285-288`

```swift
private func respond(id: RPCID, result: [String: Any]) {
    guard let input, let data = try? JSONSerialization.data(...) else { return }
    try? input.write(contentsOf: data + Data([0x0A]))
}
```

`respond(to:with:)` (`:168`) removes the pending interaction *before* writing,
then calls this non-throwing sink. If the Codex process died (`input == nil`)
or the pipe write fails, it returns normally, `resolveApprovalTranscript`
(`MiriApplication.swift:720-727`) takes the success path, and Miri announces
**"Approved for <target>"**. A spoken **deny that never reached Codex is
indistinguishable from one that did** — the worst possible failure direction on
a permission boundary.

**Fix:** make `respond(id:result:)` `throws`; propagate
`CodexAppServerError.disconnected` and the write error; on failure re-insert the
pending interaction and surface an error state.

### STOP-SHIP B — `ModelHub.offlineMode` is global mutable state; breaks consent both ways

`FluidSpeechSynthesizer.swift:72-77` and `ParakeetTranscriber.swift:72-78`

```swift
if !allowDownload { guard Self.isInstalled else { throw ... }; ModelHub.offlineMode = true }
defer { ModelHub.offlineMode = false }
```

`ModelHub.offlineMode` proxies `HFClient.offlineMode`, a
`nonisolated(unsafe) static var` whose documented contract is "set once at
startup". Two independent actors flip it per-load:

- An agent reply arriving *during* a consented download calls
  `synth.load(allowDownload: false)` → sets `offlineMode = true` → **the
  user-consented Parakeet download fails** with `networkDisabled`.
- The `defer` runs unconditionally, including when `allowDownload == true`, so a
  consented loader **clears the offline flag while an unconsented loader is
  still fetching** — the exact bypass this branch set out to close.
- Also a Swift 6 data race: unsynchronised cross-actor writes to a
  `nonisolated(unsafe)` global.

**Fix:** set `offlineMode = true` once at launch; clear it only for the duration
of an explicitly consented install, serialised through one actor. In `defer`,
restore the *previous* value — never hardcode `false`.

### Then: regression tests for the approval path

Commit `49aeb2b` fixed two stop-ships but **ships without tests**, which is how
they got in. `AttentionQueueTests` / `MultiAgentRoutingTests` test the value
types in isolation — **none exercise `AppController`, where all four stop-ships
live**. That is the real coverage gap.

Write tests that fail if `49aeb2b` were reverted:
- Agent with two open approvals: the transcript must answer the request captured
  at recording start, not "first pending for this target".
- A request withdrawn *while the user speaks* must be refused, not re-routed.
- Two agents blocked at once must not start a recording.

Obstacle: the logic sits in `AppController` (`@MainActor`, ~1400 lines).
Cheapest honest option is to extract one small pure function into `MiriCore`
(e.g. `ApprovalBinding.resolve(requestID:queue:)`) and test that. Keep the diff
tight; do not reshape the controller.

Relevant code: `MiriApplication.swift:566-597` (routing, sets
`recordingRequestID`), `:678-706` (request-ID lookup + fail-closed branch),
`:94` (declaration).

### Should-fix (review numbering)

5. **Per-agent mute is bypassed on the path agents actually use.**
   `MiriApplication.swift:781-785` gates on `mutedTargetIDs` only when
   `targetID` is passed, but the MCP path `speak(_:)` at `:763` calls
   `startSpeech` with no target — so an agent speaking through `miri-mcp` is
   never muted. Move the check into `startSpeech`.
6. **Request expiry is implemented, tested, and never used.** All three
   production sites pass `expiresAt: nil` (`:272, :320, :749`), so `isExpired`
   is always false and `removeExpired` is uncalled. An agent that hangs without
   emitting anything waits forever and can capture a later utterance. Pass
   `createdAt + 300` and sweep before each `pending()` read.
7. **The HUD shows configured targets, not live sessions.** `:1082-1090`
   fabricates a `SessionPresence` per enabled target with `lastActiveAt: now`;
   `LiveSessionDirectory` is never instantiated in Sources. Every row shares the
   same timestamp, so the recency tiebreak degenerates to alphabetical order.
   Either feed a real directory from `.status` events or rename the section to
   "Agent targets" and delete the unused type.
8. **`HotkeyGesture` is dead code.** Referenced only by its tests; no
   press-duration measurement and no `.openHUD` handler exist. The commit ships
   a pure function, not the behaviour. Wire it using the existing
   `hotkeyPressedAt`, or delete it and the claim.
9. **Docs contradict each other** (see "Doc fixes" below).
10. **Cloud STT still reachable via CLI/config.** `MiriCLI/main.swift:65`
    `miri models use-cloud` writes a setting the app silently ignores;
    unreachable `.cloud` branches remain in `MiriApplication.swift:956-999` and
    `SettingsViews.swift:93-299`; `STTBackendTests.swift:12` still asserts
    pre-narrowing behaviour.

### Doc fixes (all verified wrong)

- `AGENTS.md:21-23` and `docs/competitive-landscape.md:42` — claim **both**
  models run on the ANE. Contradicted by `docs/architecture.md:17-19` and
  `README.md:81-83` *on this same branch*. PocketTTS is GPU-backed.
- `AGENTS.md:24-25` lists opt-in cloud transcription as current, while
  `AGENTS.md:196` and README say it's unavailable in 0.1.4.
- `README.md:195` / `docs/release-checklist.md:8` — "98 executed / 95 passing".
  Real: **105 executed, 102 passed, 3 skipped**.
- `AGENTS.md:35,72` says ~57 MB; `README.md:154` says ~56 MB. (Bare Xcode app is
  22 MB; 56–57 MB is after the two 17 MB helpers — pick one and use it.)
- `AGENTS.md:76` "105 tests pass, 3 skipped" double-counts: 105 is the total
  *including* the skips.

### Nice-to-have

- `FluidSpeechSynthesizer.swift:48-54` — `isInstalled` returns true for any
  non-empty `pocket-tts` dir, so a partial download passes the guard. Check for
  a required model file.
- Per-voice `.safetensors` are fetched lazily at *speak* time; preloading the
  configured voice during the consented install closes a small unconsented
  fetch window.
- `setVoice` is never called — voice is fixed at `"alba"` in the initialiser.
- `CodexAppServerAdapter.swift:259-265` mutates `pendingInteractions` while
  iterating it (safe in Swift, fragile) — collect IDs first.
- ~30 lines of dead wake-word plumbing survive at `MiriApplication.swift:662,
  701, 861, 881-883, 1041-1060`.
- `RoutingReason` is never named outside its own file — the logging it exists
  for isn't wired up.
- `AGENTS.md` documents `installParakeetModels`/`installModels` as distinct;
  both are now one-line forwarders to `installSpeechModels`.

**Release automation was reviewed and had no findings at any severity.**

## What was done this session

All committed on the branch.

**Release scope narrowed to what actually works**
- `STTBackend.supportedCases == [.parakeet]`,
  `MiriInputMode.supportedCases == [.pushToTalk]` drive every picker. Legacy
  `cloud` / `wake_word` / `moonshine` config values migrate silently.
- Deleted `ModelLifecycleProfile` entirely — it was hidden from the UI but still
  carried as a published property, config binding, and setter that changed no
  behaviour. `audio.profile` stays allowlisted so old configs don't warn.
- Version centralized on `MiriVersion.current`; plist, Codex client metadata,
  and MCP `serverInfo` all report `0.1.4`.

**Model consent and deletion (real user-facing bugs)**
- Speaking could silently download ~520 MB of PocketTTS weights mid-conversation.
  `startSpeech` now loads with `allowDownload: false`; a missing voice falls back
  to the system voice.
- `FluidSpeechSynthesizer.modelsDirectory` pointed at Application Support, but
  FluidAudio caches TTS under `~/.cache/fluidaudio/Models`. Delete Models and
  Reset All Data were leaving the voice behind. Both roots now removed.
- One consent prompt covers both models and states the true ~1 GB total.
- The old "installer" only wrote `stt.provider` — a placebo. Replaced.

**Multi-agent attention**
- `AttentionQueue` (value type, `Sources/MiriCore/AttentionQueue.swift`) keys
  pending requests by request ID. Previously one dictionary slot per target, so
  a second request from the same agent silently overwrote the first.
- Approvals sort ahead of questions; expiry, agent disconnect/failure, and
  Codex `serverRequest/resolved` all drop requests fail-closed.
- `AgentEvent.interactionResolved` added so adapters can report a request
  answered in the agent's own UI.

**Session routing and HUD**
- `Sources/MiriCore/SessionRouting.swift` — `SessionPresence`,
  `LiveSessionDirectory` (expires on its own, no timer), `ContextResolver`
  (pure, explainable, returns `needsSelection` rather than guessing).
- `Sources/MiriCore/AgentHUDModel.swift` — HUD rows derived from live sessions
  + attention. Muting silences speech without hiding that an agent is blocked.
- `Sources/MiriApp/AgentSessionsMenu.swift` — live sessions in the menu bar with
  per-agent mute. Reuses the existing menu; no second window.
- `Sources/MiriCore/HotkeyGesture.swift` — quick tap opens the HUD, hold speaks;
  any captured audio always counts as speech so a brief utterance is never lost.

**Release automation**
- `scripts/verify-release-evidence.sh` — blocks publication unless the benchmark
  report's revision equals the release commit and every gate/metric passes.
  Independently verified: exit 0 on a passing fixture; non-zero for stale
  revision, incomplete status, and absent gates. **It correctly refuses the
  current pre-pivot benchmark**, which is the desired behaviour.
- `scripts/release-metadata.sh` — resolved SBOM from `.release` while the
  community channel stages to `.preview`, so community SBOM generation was
  silently broken. Now prefers `.preview`, refuses a bundle whose plist version
  differs from the release, and includes the SBOM in the checksum file.
- Workflow installs syft, gates before packaging, attaches all four artifacts.

**Honesty fixes**
- Hermes no longer advertises `.streaming`: it buffers the whole SSE body before
  emitting deltas.
- AGENTS.md sizes/test counts corrected; competitive-landscape 22 MB → 57 MB.

## What must happen before tagging

These need real hardware or a human; no agent can close them.

1. Live M4 acceptance on `dist/Miri-0.1.4.dmg`: install, five consecutive
   voice → Codex → spoken-response turns, rapid Option-Space press/release
   re-entry, no new `~/Library/Logs/DiagnosticReports/Miri-*.ips`.
2. **30 overlay and final-transcript samples captured from the current commit.**
   The existing `artifacts/benchmarks/m4-responsive.json` predates the CoreML
   pivot; the evidence gate will refuse it, by design. Prior overlay samples
   (207/118/110 ms) missed the p95 < 100 ms gate and were taken with the
   since-fixed double-load bug, so re-measurement may well pass.
3. Fresh macOS user/machine without Xcode: model consent/download, offline use
   afterwards, Codex MCP setup, full STT → agent → TTS.
4. Microphone denial/recovery, Bluetooth I/O, Reduce Motion + VoiceOver.
5. Push, rebuild from the pushed commit, re-verify, then tag `v0.1.4`.

## Known limitations to keep disclosing

- Ad-hoc signed, **not** notarized — Gatekeeper "Open Anyway" required.
- Apple Silicon only (`ARCHS: arm64` project-wide; FluidAudio 0.15.6 does not
  build for x86_64, and the ANE doesn't exist on Intel).
- Codex is the only live-validated adapter. Claude Code and Hermes are
  experimental: neither has a structured presence or approval bridge.
- English-only voice. Parakeet TDT v3 covers 25 European languages — **no Hindi
  or Hinglish**, confirmed in live testing.
- Wake word unavailable (lived in the deleted Python worker).
- Cloud transcription unavailable in 0.1.4.
- PocketTTS runs FP16 on **GPU**, not the ANE — only the Parakeet encoder uses
  `cpuAndNeuralEngine`. Do not claim ANE for TTS.

## Working notes

- Full independent review transcript (worth reading before touching the
  approval path):
  `/Users/adityakanu/.hermes/cache/delegation/live/deleg_c1b35593/task-0.log`
- Agent HUD visual spec (420 pt panel, 5 rows, exact typography/states) is in
  the design subagent transcript:
  `/Users/adityakanu/.hermes/cache/delegation/live/deleg_667b2af6/task-0.log`
  Only the *model* and menu-bar list are built; the expandable notch panel
  itself is not implemented.
- Verification commands:
  ```sh
  swift test
  ./scripts/build-community.sh 0.1.4
  codesign --verify --deep --strict .preview/Miri.app
  (cd dist && shasum -a 256 -c Miri-0.1.4.sha256)
  hdiutil verify dist/Miri-0.1.4.dmg
  ./scripts/verify-release-evidence.sh "$(git rev-parse HEAD)" artifacts/benchmarks/m4-responsive.json
  ```
- Lesson from this session, worth keeping: pure types were built and tested
  first, then only partly wired into `AppController`. Tests passed against code
  the app never executed. When adding logic to `MiriApplication.swift`, confirm
  the live call path uses it — don't trust a green suite alone.
