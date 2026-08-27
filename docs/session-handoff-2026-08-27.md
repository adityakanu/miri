# Miri session handoff — 2026-08-27

Pick up here. This supersedes the status block at the top of
`docs/next-session-handoff.md`; that file's design sections are still accurate
and worth reading, but its "still outstanding" list is now stale.

## Where things stand

Branch: `feature/release-readiness-agent-hud`
HEAD: `ddb04ea` (plus this doc update)
25 commits ahead of `main`. **Nothing pushed to `origin`.** Working tree clean.

- `swift test`: **108 executed, 105 passed, 3 skipped, 0 failures**, zero
  warnings. The 3 skips assert the model-*not*-installed path and skip because
  this machine has the models.
- `swift build`: clean on Swift 6.2.1.
- Artifacts rebuilt and verified **from this commit**: `.preview/Miri.app`
  57 MB arm64-only, `dist/Miri-0.1.4.dmg` 30 MB, `.zip` 28 MB, signature valid,
  checksums OK, DMG CRC valid, bundle reports `0.1.4`.

**All 11 review findings are now closed in code.** What remains is human and
hardware work only. Do not tag `v0.1.4` yet — see "What must happen before
tagging".

## What was fixed this session

Every fix below was verified by reverting it and watching a test fail, not by
trusting a green suite.

### STOP-SHIP B — `ModelHub.offlineMode` global mutable state — FIXED

`Sources/MiriCore/ModelDownloadGate.swift` (new). `ModelHub.offlineMode` proxies
a `nonisolated(unsafe) static var` documented as "set once at startup", and both
loaders flipped it per load. That broke consent in both directions: an agent
reply loading with `allowDownload: false` during a consented install killed the
user's own download, and the `defer { offlineMode = false }` cleared the block
while an unconsented loader was still fetching.

The gate blocks downloads process-wide at launch (`MiriApplication.init`),
serialises loads so none overlap, and restores the *previous* value rather than
hardcoding `false`. Verified: reverting the gate body to per-load flag flipping
fails 3 of 4 tests in `ModelDownloadGateTests`.

### Approval-path coverage — FIXED

`Sources/MiriCore/ApprovalOutcome.swift` (new). The review's central point was
that all four stop-ships lived in `AppController` and nothing tested it.
`resolveApprovalTranscript` now delegates to `ApprovalOutcome`, so
`ApprovalOutcomeTests` exercises the code the app actually runs rather than a
parallel implementation. Verified: restoring the original
`try? await deliver(response); return .delivered(response)` fails
`testAFailedSendIsNeverReportedAsSuccess` on all four assertions.

### Should-fix items 5–8, 10 — FIXED

- **Per-agent mute (#5).** The check only fired when a `targetID` was passed,
  and the MCP path — the one agents actually use — passed none. `speak()` now
  resolves a target for every kind and returns *before* the interruption logic,
  so a muted agent cannot stop another agent's speech on its way to being
  silenced. The check moved into `startSpeech`, the single choke point.
- **Request expiry (#6).** Implemented, tested, and never used: all three
  production sites passed `expiresAt: nil`. `AttentionItem` now defaults to a
  300 s lifetime from the request's own `createdAt`, and `add()` sweeps against
  that clock so the queue stays deterministic under an injected date.
- **HUD presence (#7).** `hudModel` fabricated a `SessionPresence` per enabled
  target with `lastActiveAt: now`, so every row shared a timestamp and recency
  ordering degenerated to alphabetical. Presence is now recorded from real
  agent events and deliveries, and — importantly — is fed to `ContextResolver`,
  which previously received *no* sessions at all, meaning its foreground and
  recency rules could never fire. `LiveSessionDirectory` deleted; it was never
  instantiated outside its own tests.
- **`HotkeyGesture` (#8).** Deleted. No press-duration measurement and no HUD
  panel exist to open, so it was a pure function with no behaviour behind it.
- **Cloud STT CLI (#10).** Removed `miri models use-cloud` and the moonshine
  `use-defaults`/`use-accuracy` commands, which configured backends that no
  longer exist. **Not done:** the unreachable `.cloud` branches in
  `MiriApplication.swift` and `SettingsViews.swift` and the `STTBackend.cloud`
  case still exist. `sttBackend` is only ever set via
  `supported(configurationValue:)`, which returns `.parakeet` only, so the UI is
  dead but harmless. Removing it is a visible Settings change — deliberately
  left for a decision rather than done at release time.

### Doc fixes (#9) — FIXED

ANE claim corrected in `AGENTS.md` and `docs/competitive-landscape.md`
(PocketTTS is GPU-backed); the stale "opt-in cloud transcription" feature line
removed; test counts corrected in `README.md` and `docs/release-checklist.md`;
size unified to the measured 57 MB.

### Nice-to-haves — FIXED

`isInstalled` on both loaders required only a non-empty directory, so a partial
download passed the guard. Both now require a real CoreML bundle; verified
against this machine's actual model tree (the skip-when-installed tests still
skip, so a complete install is still recognised). Also: `pendingInteractions`
IDs collected before mutation, `setVoice` deleted, `RoutingReason` now logged.

### Deliberately not done

- **Wake-word plumbing removal.** ~25 entangled sites across
  `MiriApplication.swift`. Dead but harmless — `inputMode` can only be
  `.pushToTalk`. Not worth the regression risk immediately before a release.
- **Cloud Settings UI removal.** See #10 above.

## What must happen before tagging

These need real hardware or a human; no agent can close them.

1. Live M4 acceptance on `dist/Miri-0.1.4.dmg`: install, five consecutive
   voice → Codex → spoken-response turns, rapid Option-Space press/release
   re-entry, no new `~/Library/Logs/DiagnosticReports/Miri-*.ips`.
2. **30 overlay and final-transcript samples captured from the current commit.**
   The existing `artifacts/benchmarks/m4-responsive.json` predates the CoreML
   pivot; the evidence gate refuses it, by design — confirmed again this
   session (revision mismatch + two missing gates, exit 1). Prior overlay
   samples (207/118/110 ms) missed the p95 < 100 ms gate and were taken with
   the since-fixed double-load bug, so re-measurement may well pass.
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
- Lesson carried forward from the previous session: pure types were built and
  tested first, then only partly wired into `AppController`, so tests passed
  against code the app never executed. This session closed those gaps
  (`ContextResolver` now receives real sessions; `HotkeyGesture` and
  `LiveSessionDirectory` were deleted rather than left as untethered pure
  functions) and adopted a stricter rule: **verify a fix by reverting it and
  watching a named test fail.** Every fix in "What was fixed this session" was
  checked that way. A green suite alone proves nothing about the live path.
