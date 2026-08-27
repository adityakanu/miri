# Miri agent handoff

## Objective

Finish and validate Miri `0.1.4` as a no-cost, ad-hoc-signed macOS community
release. Miri is a local-first voice interface for coding agents: hold the
global hotkey, speak to the selected agent session, and hear filtered agent
responses through local TTS. Do not tag or publish `v0.1.4` until the remaining
release blockers below pass.

The product scope and architecture are documented in `scope.md`,
`docs/implementation-plan.md`, and `docs/release-checklist.md`. Treat those as
the source of truth. Speech inference is now Swift + CoreML via FluidAudio;
there is no Python in the product.

## Current implementation

- Native SwiftUI/AppKit menu-bar accessory app with a non-activating,
  notch-aware status overlay and configurable hold-to-talk hotkey.
- AVFoundation microphone capture and PCM playback.
- All speech runs on CoreML in-process via FluidAudio (Apache-2.0): NVIDIA
  Parakeet TDT for transcription on the Apple Neural Engine, PocketTTS for
  speech output on the GPU. Do not claim the ANE for TTS. There is no Python
  runtime and no worker subprocess.
- Cloud transcription is not available: the provider was removed with the
  Python worker and is not reimplemented natively yet.
- Transcripts are normalized to written form before delivery via FluidAudio's
  NeMo inverse text normalization ("port eight thousand and eighty" arrives as
  "port 8080"). Voice approvals are parsed from the raw transcript, so no text
  transform sits on a permission boundary.
- An optional dictation target (`adapter = "cursor"`) types the transcript into
  whichever app has keyboard focus, using synthesized key events rather than the
  clipboard. It requires macOS Accessibility permission and fails loudly without
  it.
- Agent-neutral routing contracts with Clipboard, generic command, Codex,
  Claude Code, and Hermes adapters.
- Codex is the live-validated path. Miri snapshots the exact agent/thread target
  when an interaction begins; an agent can speak through `miri-mcp`, and the
  next hotkey response routes back to that pending interaction/session.
- Agent status speech is filtered and rate-limited. Explicit voice approval is
  supported through the neutral interaction contract.
- Private local socket only; no HTTP listener, analytics, or persistent
  transcript history. Failed delivery uses a memory-only outbox.
- The packaged app bundle is ~56 MB and arm64-only, including the `miri` and
  `miri-mcp` helpers. No inference runtime or model weights are embedded;
  Parakeet and PocketTTS models are downloaded on first use, together, after a
  single explicit consent prompt covering the full ~1 GB.

## Critical crash fixed on 2026-07-18

The installed `0.1.3` crashed as soon as the agent began speaking. Two reports
under `~/Library/Logs/DiagnosticReports/` showed `EXC_BREAKPOINT`/`SIGTRAP` on
`AVAudioPlayerNodeImpl.CompletionHandlerQueue`, with the failing frame in
`SpeechPCMPlayer.enqueue(_:)`.

Root cause: the `AVAudioPlayerNode` completion closure inherited `MainActor`
isolation but AVFoundation invoked it on its private completion queue. Swift's
executor check trapped before the closure could perform its intended actor hop.

Fix in `Sources/MiriCore/Native/AudioIO.swift`:

- Construct the playback callback in a `nonisolated` function.
- Make it `@Sendable`.
- Explicitly hop to `MainActor` before calling `bufferDidPlay()`.

Regression coverage is in
`Tests/MiriCoreTests/NativeComponentsTests.swift` as
`testSpeechPlaybackCompletionMayArriveOffMainActor`.

A second packaging defect in the Python worker launcher (`__pycache__` writes
invalidating the signed bundle) is now moot: the worker and its launcher were
removed when speech moved to CoreML.

## Verified state

Artifacts were rebuilt from the current branch on 2026-08-27:

- `dist/Miri-0.1.4.dmg` (~30 MB) and `dist/Miri-0.1.4.zip` (~28 MB), replacing
  the pre-pivot ~965 MB / ~656 MB artifacts
- `dist/Miri-0.1.4.sha256`
- staged application: `.preview/Miri.app` (~56 MB)

Completed checks:

- `swift test`: 111 executed, 108 passed, 3 skipped when speech models are
  absent. The 111 total includes the skips.
- The new off-main-actor playback regression test passes.
- `codesign --verify --deep --strict .preview/Miri.app` passes.
- The staged bundle is arm64-only.
- The bundle signature remains valid after first run; nothing writes into the
  app bundle.
- Both DMG and ZIP match `dist/Miri-0.1.4.sha256`.
- `hdiutil verify dist/Miri-0.1.4.dmg` passes.
- The staged bundle reports version `0.1.4`.
- The DMG build includes `Miri.app` and the `/Applications` drag target.

Useful verification commands:

```sh
swift test
(cd dist && shasum -a 256 -c Miri-0.1.4.sha256)
codesign --verify --deep --strict .preview/Miri.app
hdiutil verify dist/Miri-0.1.4.dmg
```

## User acceptance test required now

The user must test the corrected artifact rather than the installed `0.1.3`:

1. Quit Miri and remove the old `/Applications/Miri.app`.
2. Open `dist/Miri-0.1.4.dmg`.
3. Drag `Miri.app` to Applications.
4. Use **System Settings → Privacy & Security → Open Anyway** when Gatekeeper
   blocks the ad-hoc signed community build.
5. Confirm the app reports version `0.1.4`.
6. Complete voice → Codex → spoken response at least five consecutive times.
7. Rapidly press/release Option-Space, then press it again, repeatedly. Confirm
   no stale recording session, stuck overlay, crash, or forced relaunch.
8. Check for any new `Miri-*.ips` crash report and inspect
   `~/Library/Logs/Miri/` after the run.

Do not call the playback crash resolved for release until this real hardware
test succeeds. Automated coverage validates the executor fix but cannot prove
the complete microphone/agent/output-device path.

## Benchmark status

The partial M4/16 GB responsive-profile report is at
`artifacts/benchmarks/m4-responsive.json` and documented in
`docs/benchmarks.md`.

Passing evidence:

- First TTS audio p95: `251.258 ms` (budget `< 500 ms`).
- Idle CPU mean: `0.077%` (budget `< 1%`).
- Warm RSS maximum: `117.547 MB` (budget `< 1.25 GB`).

Incomplete evidence:

- Overlay response requires 30 clean human samples and p95 `< 100 ms`.
- Final transcript requires 30 clean human samples and p95 `< 1 second`.

Do not describe the overall benchmark as passing until both missing sample sets
are captured. `scripts/benchmark.py` supports repeated `--pid`,
`--events-start-line`, and `--base-report` so the existing resource/TTS evidence
can be retained. `scripts/benchmark-utterance.swift` is a synthetic helper, but
it needs Accessibility permission and does not replace human speech evidence.

## Remaining `0.1.4` release work

### Release blockers

These all require real hardware or a human; the code-side blockers are done.

1. Pass the acceptance test above on the freshly built DMG, including repeated
   TTS and rapid hotkey re-entry, with no new crash report.
2. Collect 30 human overlay and final-transcript samples and produce a complete
   passing M4 benchmark report from the current commit. The existing report
   predates the CoreML pivot and must not be reused.
3. Test installation on a fresh macOS user/machine without Xcode; verify the
   combined model consent/download, offline use afterwards, Codex MCP setup,
   and STT → agent → TTS.
4. Exercise microphone permission denial/recovery, Bluetooth input/output, and
   at least the primary accessibility path (Reduce Motion and VoiceOver labels).
5. Live-test Claude Code and Hermes, or ship them labelled experimental with
   Codex as the only validated adapter for `0.1.4`.
6. Review model/runtime licenses (FluidAudio Apache-2.0, Parakeet CC-BY-4.0),
   bundled notices, and the generated SBOM.
7. Push all intended changes, rebuild from that exact commit, and re-verify
   version, signature, DMG layout, checksums, and clean installation.
8. Only after the gates pass, create `v0.1.4`, publish one GitHub Release, and
   attach DMG, ZIP, checksum, SBOM, release notes, known limitations, supported
   hardware, and benchmark evidence.

### Completed in this cycle

- All 11 findings from the independent review are closed in code. See
  `docs/session-handoff-2026-08-27.md` for the per-finding detail.
- Model downloads are gated process-wide: `ModelDownloadGate` blocks fetches at
  launch, serialises loads, and restores the prior flag value, so an agent reply
  can no longer kill a user-consented download and a consented load can no
  longer open the door for an unconsented one.
- The approval path is covered by tests that run the app's own code
  (`ApprovalOutcome`), rather than parallel value types the controller never
  called.
- Per-agent mute now applies to the MCP path agents actually use; request
  expiry, session presence, and routing reasons are wired into live call paths
  instead of existing only as tested-but-unused types.
- Only Parakeet transcription and push-to-talk are user-selectable; the
  non-functional cloud backend and unavailable wake word are no longer offered,
  and the inert model-profile control is gone.
- Speaking can no longer trigger a silent ~520 MB voice download; one consent
  prompt covers both models, and deleting models now removes both FluidAudio
  roots instead of leaving the voice behind.
- Several agents can wait at once: pending requests are keyed by request ID,
  approvals outrank questions, and requests resolved in the agent's own UI,
  withdrawn, or belonging to a failed agent are dropped fail-closed.
- Routing no longer requires opening Settings: a waiting agent claims the next
  utterance, competing agents force an explicit choice, and live sessions with
  per-agent mute are listed in the menu bar.
- Version reporting is centralized on `MiriVersion.current`.

### Known limitations to disclose

- Free community artifacts are ad-hoc signed, not Developer-ID notarized, so
  users need the Gatekeeper **Open Anyway** flow.
- Apple Silicon only: the Neural Engine does not exist on Intel Macs. M4 is the
  validated platform; M1 remains best-effort until physical testing is recorded.
- Codex has the deepest live validation. Claude Code and Hermes do not yet have
  the same compatibility evidence.
- English-first speech; no custom vocabulary, multilingual catalog, spoken
  correction, mobile/remote relay, worktree/diff dashboard, or broad provider
  picker yet.
- Wake word is unavailable: it lived in the removed Python worker. Push-to-talk
  is the supported input mode.
- Cloud transcription is not available in `0.1.4`. The provider was removed with
  the Python worker and is not reimplemented natively yet.

## Working tree warning

The worktree intentionally contains uncommitted release work. Preserve it and
do not reset, clean, or overwrite unrelated changes. At handoff it includes:

- SwiftPM product collision fix: development app is `swift run miri-app`, while
  `miri` remains the CLI. XcodeGen still packages `Miri.app`.
- Playback crash fix and regression test.
- Benchmark harness/report/documentation changes.
- Competitor analysis updates.
- Generated benchmark artifacts and synthetic benchmark helper.

Run `git status --short` and inspect every diff before committing. Generated
`.preview/` and `dist/` artifacts may be ignored by Git; do not assume their
presence means source changes are committed.

## Distribution decision

The immediate channel is the GitHub-hosted unsigned community DMG/ZIP. Official
Homebrew Cask submission and frictionless notarized installation require Apple
Developer ID signing and are future work. Do not claim the community artifact
is notarized. A third-party tap may distribute it, but users will still face
Gatekeeper and this is not the preferred `0.1.4` launch path.

## Competitive positioning

See `docs/competitive-landscape.md`. Miri should launch around its focused
differentiator: a local, bidirectional, exact-session voice loop for coding
agents with explicit approval routing and a native macOS safety/status UI. It
currently trails mature dictation products in language breadth and correction
features, and trails broad agent orchestrators such as Paseo in dashboards,
remote/mobile access, providers, worktrees, and diffs. Do not overstate
competitive claims.
