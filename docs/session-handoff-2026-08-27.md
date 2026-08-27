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

Two review findings are still open. Both are small and well understood.

### 1. Add the regression tests for the approval fix (highest value)

Commit `49aeb2b` fixed two stop-ships but **ships without tests**, which is
exactly how they got in. The existing `MultiAgentRoutingTests` passed against
the *pure* `ContextResolver` while the app used dead hand-rolled code — passing
tests against an unused path.

Write tests that fail if `49aeb2b` were reverted:

- An agent with two open approvals: the transcript must answer the request
  captured when recording began, never "the first pending one for this target".
- A request that expires/is withdrawn *while the user is speaking* must be
  refused, not re-routed to another request or delivered as a normal message.
- Two agents blocked at once must not start a recording at all.

The obstacle: this logic lives in `AppController` (`Sources/MiriApp/
MiriApplication.swift`, `@MainActor`, ~1400 lines) and is not directly
testable. Cheapest honest option is to extract the decision into a small pure
function in `MiriCore` — something like
`ApprovalBinding.resolve(requestID:queue:) -> AttentionItem?` plus the
`startListening` branch — and test that. Do **not** reshape the whole
controller; keep the diff tight.

Relevant code:
- `MiriApplication.swift:566-597` — routing via `ContextResolver`, sets
  `recordingRequestID`.
- `MiriApplication.swift:678-706` — approval lookup by request ID, fail-closed
  branch.
- `MiriApplication.swift:94` — `recordingRequestID` declaration.

### 2. Finish removing cloud STT

Half-removed, flagged should-fix by review:

- `Sources/MiriCLI/main.swift:65` — `miri models use-cloud` still writes
  `provider = "cloud"`, which the app now silently coerces to `.parakeet`.
  Remove the subcommand or make it exit with a clear error.
- `MiriApplication.swift` ~`956-999` and `SettingsViews.swift` ~`93-299` —
  unreachable `sttBackend == .cloud` branches.
- `Tests/MiriCoreTests/STTBackendTests.swift:12` still asserts the
  *pre-narrowing* `STTBackend(configurationValue: "cloud") == .cloud`. Add a
  test asserting `STTBackend.supported(configurationValue: "cloud") == .parakeet`
  so the narrowing has a negative test.

### 3. Fix two stale test-count claims

A docs subagent recorded counts before the last 7 tests landed:
- `README.md:195` and `docs/release-checklist.md:8` say "98 executed / 95
  passing". Actual: **105 executed, 102 passed, 3 skipped**.

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
