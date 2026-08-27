# Miri next-session handoff

Last updated: 2026-08-27 (revised after the implementation cycle)

> **Read `docs/session-handoff-2026-08-27.md` first.** It reflects the current
> branch state, including two stop-ship fixes found by review after this
> document's status block was written. The design sections below are still
> accurate; the "Still outstanding" list here is stale.

> **Status:** the code-side stop-ship defects listed later in this document are
> now fixed on `feature/release-readiness-agent-hud`. What remains are the
> hardware/human gates: live M4 acceptance, 30 benchmark samples from the
> current commit, and fresh-machine installation. Sections below that describe
> a defect as outstanding are kept for context; see "Implementation cycle
> results" for what actually changed.

## Objective

Finish and validate Miri `0.1.4` as a focused, no-cost, ad-hoc-signed macOS
community release. Do not tag or publish the release until the stop-ship defects
and release gates in this document are resolved.

Miri's release differentiator is a local, bidirectional, exact-session voice
loop for coding agents—not generic cross-application dictation. The intended
first-release path is:

1. Hold the global hotkey.
2. Speak a request.
3. Transcribe locally with Parakeet.
4. Deliver to the snapshotted coding-agent session.
5. Hear the filtered agent response through local PocketTTS.
6. Route the next answer or explicit approval back to the same session.

## Repository state

- Working directory: `/Users/adityakanu/Developer/miri`
- Current branch: `feature/release-readiness-agent-hud`
- The branch is 14 commits ahead of `main`; nothing has been pushed to
  `origin`.
- `swift test`: 105 tests pass, 3 skipped when speech models are absent, zero
  warnings.
- The arm64 Release bundle is ~57 MB; `dist/Miri-0.1.4.dmg` is ~30 MB and the
  ZIP ~28 MB, replacing the obsolete pre-pivot artifacts.

Branch commits, newest first:

```text
6cd5ac0 Delete the inert model lifecycle profile
975cb34 Fail closed on stale benchmark evidence and wrong-version bundles
cc018e1 Correct release documentation to match verified state
e2292f2 Drop Codex requests that were resolved elsewhere
a714268 Cover multi-agent routing and approval races
eee9108 Show live agent sessions in the menu bar with per-agent mute
ee38e53 Classify quick tap versus hold on the push-to-talk key
3eba2e1 Add Agent HUD presentation model
0e27da4 Route waiting agent requests through the attention queue
dd11ed9 Add live session directory and deterministic context resolver
512fdf8 Gate voice download behind consent and delete both model roots
c868b4c Add expiry-aware attention lookup and correct Hermes capabilities
a827662 Narrow release scope and add request attention queue
16c393f Document release readiness and multi-agent follow-up
```

## Implementation cycle results

### Release scope, now honest

- Only Parakeet transcription and push-to-talk are user-selectable.
  `STTBackend.supportedCases` and `MiriInputMode.supportedCases` drive every
  picker, and legacy `cloud` / `wake_word` / `moonshine` configuration values
  migrate silently instead of selecting something that cannot work.
- The inert model lifecycle profile is deleted outright.
- Version reporting is centralized on `MiriVersion.current`; the app plist,
  Codex client metadata, and MCP `serverInfo` all report `0.1.4`.

### Model consent and deletion

- Speaking can no longer trigger a download: `startSpeech` loads the voice with
  `allowDownload: false`, so a missing voice falls back to the system voice
  instead of silently fetching ~520 MB mid-conversation.
- One consent prompt now covers both models and states the real ~1 GB total.
- `FluidSpeechSynthesizer.modelsDirectory` points at the real macOS TTS cache
  (`~/.cache/fluidaudio/Models`), so Delete Models and Reset All Data remove
  both FluidAudio roots instead of leaving the voice behind.

### Multi-agent attention

- `AttentionQueue` keys pending requests by request ID, so several agents can
  wait at once and one agent can raise both a question and an approval.
  Approvals sort ahead of questions.
- Requests fail closed when they expire, when the agent disconnects or fails,
  and when Codex reports `serverRequest/resolved` because the request was
  answered in its own UI, cancelled, or timed out.
- Approval still requires the exact phrase and a specific request ID; a vague
  "yes" is rejected, and an unparseable transcript leaves the request pending.

### Session routing and HUD

- `LiveSessionDirectory` holds ephemeral presence that expires on its own.
- `ContextResolver` is pure and explainable: explicit target, then a single
  waiting request, then foreground project, then recently used session, then
  pinned default. Two agents waiting at once returns `needsSelection` rather
  than guessing.
- `AgentHUDModel` derives the HUD rows; live sessions appear in the menu bar
  with per-agent mute, and muting silences speech without hiding that an agent
  is blocked.
- `HotkeyGesture` classifies a quick tap as "open the HUD" and a hold as
  speech, but any captured audio always counts as speech.

### Release automation

- `scripts/verify-release-evidence.sh` blocks publication unless the benchmark
  report's revision equals the release commit and every gate passes. It
  correctly rejects the current pre-pivot report.
- `scripts/release-metadata.sh` resolves whichever bundle is staged, refuses a
  bundle whose plist version differs from the release, and includes the SBOM in
  the checksum file. The workflow installs syft and attaches all four
  artifacts.

### Still outstanding

1. Live M4 acceptance on the rebuilt DMG, including repeated TTS and rapid
   hotkey re-entry, with no new crash report.
2. Thirty overlay and final-transcript samples captured from the current
   commit; the existing report predates the CoreML pivot and the evidence gate
   will refuse it.
3. Fresh-machine installation without Xcode.
4. Microphone denial/recovery, Bluetooth, and accessibility passes.
5. Claude Code and Hermes remain experimental: neither has a structured
   presence or approval bridge, and Hermes buffers its whole SSE body, so it no
   longer advertises streaming.
6. Push, rebuild from the pushed commit, then tag `v0.1.4`.

Do not reset or discard the handoff document if it is still uncommitted at the
start of the next session.

## Current verified state

### Automated verification

- `swift test`: 66 tests pass, 2 environment-dependent tests skip, 0 failures.
- Final test run produced no Miri-owned compiler warnings.
- A real arm64 Release app was built successfully using
  `scripts/build-release.sh` after fixing packaging to pass `ARCHS=arm64` to
  Xcode/SwiftPM dependencies.
- Packaged Release app size: approximately 56 MB, including:
  - Miri app executable: approximately 21 MB.
  - `miri` CLI helper: approximately 17 MB.
  - `miri-mcp` helper: approximately 17 MB.
- The packaged app contains:
  - `LICENSE`
  - `MODEL-LICENSES.md`
  - `THIRD-PARTY-NOTICES.md`
- The app executable is arm64-only.

### Live hardware verification on Apple M4 / 16 GB

- Parakeet downloaded, loaded, and transcribed real speech.
- The user judged Parakeet output good enough to adopt it as the primary local
  transcription engine.
- Long, disfluent English speech was transcribed with sensible spacing and
  punctuation; filler words were preserved in the raw transcript.
- FluidAudio seam-gap repair recovered tokens at ASR chunk boundaries.
- Miri delivered real transcripts to Codex and received agent responses.
- PocketTTS downloaded its English pack, loaded the `alba` voice, streamed
  speech through Miri's PCM player, and sounded good to the user.
- Hindi/Hinglish was not recognized accurately. This is an expected model
  limitation, not a claim of multilingual support.
- No new Miri crash report was observed during the tested sessions.

### Important caveat

The live tests used a development build (`swift run miri-app`), not a freshly
installed DMG produced from current `main`. Full release acceptance remains
open.

## Current product feature set

### Native macOS application

- SwiftUI/AppKit menu-bar accessory app.
- Non-activating, notch-aware status overlay.
- Configurable global hold-to-talk hotkey.
- Native AVFoundation microphone capture and PCM playback.
- Audio-device connection/disconnection observation.
- Microphone permission flow.
- Reduce Motion behavior and VoiceOver labels.
- Listening, transcribing, sending, waiting, speaking, cancellation, delivery,
  and error overlay states.

### Voice input

- Push-to-talk is the supported input mode.
- Input is converted to 16 kHz mono Float32 for Parakeet.
- Short/quiet recording diagnostics.
- Escape cancellation.
- Starting a new recording can interrupt current speech.
- Final transcript and overlay latency metrics are recorded without logging
  transcript content.

### Local speech recognition

- NVIDIA Parakeet TDT 0.6B v3 through FluidAudio/CoreML.
- Parakeet encoder uses the Apple Neural Engine with supporting CPU execution.
- In-process Swift inference: no Python runtime, worker subprocess, or speech
  IPC.
- Explicit consent before Parakeet download.
- Approximately 461–470 MB on this Mac.
- Local/offline after installation.
- English and Parakeet's supported European-language set; Hindi/Hinglish is not
  supported well enough to claim.

### Local speech synthesis

- Kyutai PocketTTS v2.1 English through FluidAudio/CoreML.
- Streaming 24 kHz mono Float32 synthesis.
- Default voice: `alba`.
- Current code uses FluidAudio defaults: FP16 precision and default GPU model
  placement. Do not claim PocketTTS runs on the Neural Engine without changing
  and measuring its placement.
- macOS `AVSpeechSynthesizer` fallback if PocketTTS is unavailable.
- Interruptible and priority-aware speech.
- Approximately 523 MB in `~/.cache/fluidaudio` on this Mac.

### Agent routing and delivery

- Target/session snapshot at interaction start.
- Clipboard adapter.
- Generic command adapter; transcripts are sent through stdin and never shell
  interpolated.
- Codex app-server adapter and Codex thread discovery.
- Claude Code CLI adapter.
- Hermes HTTP/SSE adapter.
- Executable discovery through explicit override, login-shell `PATH`, and common
  user prefixes.
- Per-target connection status.
- One queued message per busy target with reject/replace/confirm policy.
- Memory-only failed-delivery outbox with edit, retry, copy, and discard.
- No persistent transcript history.

### Bidirectional interaction

- Spoken agent responses.
- Agent question/interaction pinning to the originating session.
- Explicit voice approval and denial through neutral interaction contracts.
- Vague phrases such as `yes` do not approve requests.
- Approval fails closed on disconnect.
- Agent speech filtering, deduplication, priority, rate limiting, and length
  limits.

### Configuration, privacy, and diagnostics

- TOML configuration with live reload, validation, and conflict detection.
- macOS Keychain storage for cloud-transcription credentials.
- Private local Unix control socket; no local HTTP listener.
- No analytics.
- Raw audio and full transcript text are omitted from normal logs.
- Model deletion and reset UI exists, but has a confirmed cleanup defect listed
  below.
- Third-party attribution covers FluidAudio/FluidInference, NVIDIA, Kyutai,
  Parakeet, PocketTTS, and NemoTextProcessing.

## Current model and runtime inventory

| Function | Current model/runtime | Placement | Approximate local size | Status |
|---|---|---|---:|---|
| STT | NVIDIA Parakeet TDT 0.6B v3, FluidInference CoreML conversion | ANE + CPU | 461–470 MB | Live-validated on M4 |
| TTS | Kyutai PocketTTS v2.1 English, FluidInference CoreML conversion | CoreML, current default GPU placement | 523 MB | Live-validated on M4 |
| TTS fallback | macOS `AVSpeechSynthesizer` | System | Built into macOS | Implemented |
| Text normalization dependency | NemoTextProcessing through FluidAudio | Native dependency | Bundled transitively | Present |
| Cloud presets shown in UI | Groq Whisper Large v3 Turbo, OpenAI GPT-4o Mini Transcribe, custom/local OpenAI-compatible server | Remote/local endpoint | N/A | Configuration probe only; actual STT path is broken |

Total local FluidAudio model storage observed on this machine is approximately
984 MB across two different roots:

```text
~/Library/Application Support/FluidAudio   # Parakeet, ~461 MB
~/.cache/fluidaudio                       # PocketTTS, ~523 MB
```

FluidAudio is pinned through `Package.resolved`; `Package.swift` currently uses
`from: "0.15.6"`.

## Major completed engineering work

### Native speech pivot

- Integrated FluidAudio and Parakeet in-process.
- Added actor-based `ParakeetTranscriber` with explicit download consent,
  buffering, finish/cancel/unload, and model-presence detection.
- Fixed actor reentrancy that allowed concurrent Parakeet callers to compile/load
  the same model twice.
- Added a concurrent-load regression test.
- Added native streaming PocketTTS through `FluidSpeechSynthesizer`.
- Shared concurrent load work for PocketTTS to avoid the same actor-reentrancy
  defect.
- Routed TTS frames directly to `SpeechPCMPlayer`.
- Removed the Python worker, Python packaging, PyTorch, ONNX Runtime, Moonshine,
  worker launcher, worker supervisor/client, and Python CI.
- Reduced the packaged product from gigabyte-scale Python artifacts to a 56 MB
  app bundle with CLI/MCP helpers and on-demand models.

### Audio crash and concurrency fixes

- Fixed the AVAudioPlayerNode off-main completion-handler crash by constructing
  a nonisolated `@Sendable` callback and explicitly hopping to `MainActor`.
- Added regression coverage for off-main playback completion.
- Fixed control-socket silent-client blocking, byte-at-a-time reading,
  accept-loop busy-spin, and state races.
- Added a regression test proving a silent client no longer blocks later
  requests.
- Fixed cold-start metric corruption caused by recording session elapsed time on
  worker restart.

### Settings and native STT UI

- Added Settings → Speech.
- Added Parakeet install state and consent flow.
- Added cloud-provider presets, endpoint/model/language/prompt settings, Keychain
  credential storage, key removal, and connection probe.
- Added warning-free configuration round-trip coverage for speech settings.
- Fixed the shortcut editor so `option+space` no longer duplicates or wraps in
  Settings/onboarding.

### Agent and reliability work

- Added shared executable resolution for version managers and Finder-launched
  workflows.
- Removed a dead Codex adapter implementation.
- Preserved exact-session routing and shared final-transcript handling.
- Preserved explicit approval routing, delivery queue, and memory outbox.

### Legal and packaging work

- Preserved the user's complete Apache 2.0 `LICENSE` text.
- Added prominent FluidAudio credit and the official FluidInference badge to the
  README.
- Added `THIRD-PARTY-NOTICES.md`.
- Included all legal files in community and signed release channels.
- Forced arm64 in both packaging scripts after a real Release build exposed
  attempted x86_64 compilation of FluidAudio.
- Removed an accidentally committed Vim swap file and added swap files to
  `.gitignore`.

### Competitive positioning

Miri should not claim to beat Wispr Flow at generic dictation. Wispr is more
mature for multilingual cross-app dictation, filler removal, backtracking,
formatting, snippets, dictionaries, and broad platform support.

Miri's defensible first-release advantages are:

- local/offline speech after model installation;
- no recurring subscription;
- exact coding-agent session routing;
- spoken agent responses;
- explicit voice approvals;
- open, agent-neutral architecture;
- native macOS safety/status UI.

## Confirmed stop-ship defects

### 1. Cloud STT is exposed but actual recordings cannot use it

Settings, Keychain storage, validation, and the silent-WAV connection probe work.
The recording/transcription runtime does not.

Current behavior:

- Selecting cloud unloads Parakeet.
- Microphone samples still go to `ParakeetTranscriber.accept`.
- `endListening` still calls `ParakeetTranscriber.finish`.
- Cloud mode therefore fails instead of uploading the utterance.

Relevant code:

- `Sources/MiriApp/MiriApplication.swift:546-580`
- `Sources/MiriApp/MiriApplication.swift:617-622`
- `Sources/MiriApp/MiriApplication.swift:934-969`

Recommended first-release decision: hide/remove cloud STT for `0.1.4` and ship
the focused local path. If cloud is required, implement a real native URLSession
batch transcription client and live-test Groq plus one other compatible endpoint.
Do not advertise cloud until the recording path is connected.

### 2. PocketTTS downloads without explicit consent

Parakeet asks permission, but PocketTTS downloads approximately 523 MB when the
first agent reply attempts speech. The live test showed 48 files downloading.

Relevant code:

- `Sources/MiriApp/MiriApplication.swift:779-785`
- `Sources/MiriCore/FluidSpeechSynthesizer.swift:42-56`

The onboarding `installModels()` function does not install either model; it only
writes a configuration value:

- `Sources/MiriApp/MiriApplication.swift:1136-1153`

Required fix:

- One honest consent flow for approximately 1 GB total.
- Install/download Parakeet and PocketTTS from that flow.
- Show progress for both where FluidAudio exposes it.
- Do not surprise the user with a half-gigabyte download on the first spoken
  response.

### 3. Model deletion/reset leaves PocketTTS behind

`Delete Downloaded Models` and `Reset All Data` remove Parakeet under Application
Support but do not remove PocketTTS under `~/.cache/fluidaudio`.

Relevant code:

- `Sources/MiriApp/MiriApplication.swift:1116-1171`
- `Sources/MiriCore/FluidSpeechSynthesizer.swift:33-37`

`FluidSpeechSynthesizer.modelsDirectory` currently points to the wrong root for
PocketTTS on macOS.

Required fix:

- Resolve FluidAudio's actual TTS cache path.
- Remove both Parakeet and PocketTTS data after unloading both actors.
- Verify by measuring both directories before and after deletion/reset.
- Add tests around path selection where possible.

### 4. Wake word remains selectable but is unavailable

Wake word still appears in Settings, onboarding, and the menu-bar Input Mode
picker. Its implementation immediately falls back to push-to-talk and can leave
persisted configuration inconsistent.

Relevant code:

- `Sources/MiriCore/Preferences.swift:3-20`
- `Sources/MiriApp/SettingsViews.swift:196-199`
- `Sources/MiriApp/SettingsViews.swift:405-408`
- `Sources/MiriApp/MiriApplication.swift:1031-1037`
- `Sources/MiriApp/MiriApplication.swift:1310-1314`

Required first-release fix: remove wake word from user-facing choices and make
push-to-talk the only supported mode. Reintroduce it only with a working native
wake model.

### 5. Model lifecycle profile is a placebo

Settings offers Responsive/Balanced/Eco and claims different unload policies.
Neither Parakeet nor PocketTTS reads or implements those policies.

Relevant code:

- `Sources/MiriCore/Preferences.swift:24-38`
- `Sources/MiriApp/SettingsViews.swift:202-209`
- `Sources/MiriApp/MiriApplication.swift:873-881`

Required first-release fix: remove the control and related onboarding page. Do
not add three lifecycle modes without measured need.

### 6. Benchmark evidence predates the FluidAudio pivot

`artifacts/benchmarks/m4-responsive.json` records revision `d1e55b2`, before the
native speech architecture. It has zero overlay and final-transcript samples and
an incomplete overall status. Its resource and TTS evidence must not be reused
as proof for current `main`.

Required fix: collect a new current-revision benchmark with 30 clean human
samples for overlay response and final transcript plus current TTS, CPU, RSS,
and cold-start data.

### 7. Existing `dist/` artifacts are obsolete

Current `dist/` still contains the pre-pivot artifacts:

- DMG: approximately 972 MB.
- ZIP: approximately 656 MB.

Do not publish them. Rebuild all artifacts from the exact final pushed commit.

### 8. Version strings disagree

Known values:

- `App/Info.plist`: `0.1.0`
- MCP server info: `0.1.4`
- Codex app-server client info: `0.1.0`
- Intended release: `0.1.4`

The release script overrides some app metadata, but development/protocol values
remain inconsistent.

Required fix: create one build-time version source or update and test every
reported version before tagging.

### 9. Documentation contains stale architecture measurements/claims

Examples:

- `AGENTS.md` still mentions 47 tests instead of 66.
- It says the app is about 22 MB, while the full packaged app with helpers is
  approximately 56 MB.
- Some text says both speech models run on the ANE, while current PocketTTS uses
  FluidAudio's default GPU placement.
- Some comments still refer to the removed Python worker.

Update only after the above feature decisions are final so documentation does
not churn twice.

## Important non-blocking technical debt

### Hermes falsely advertises streaming

`HermesAdapter` declares `.streaming` but uses `URLSession.data(for:)`, buffers
the full SSE response, and emits deltas only after completion.

Relevant code:

- `Sources/MiriCore/AgentIntegrations.swift:24-75`

For `0.1.4`, either remove the streaming capability or implement incremental
`URLSession.bytes(for:)` parsing. The minimal honest fix is to remove the
capability and label Hermes experimental until live-tested.

### Worker-era dead code and naming remain

Potential cleanup after the stop-ship items:

- `MiriIPC` audio/worker frame protocol is no longer part of the product path.
- `MiriApplication.swift` still imports `MiriIPC`.
- `AudioChunkPipe`, `audioSenderTask`, VAD fields, wake-session fields, worker
  error-domain strings, and worker comments remain.
- Legacy Moonshine/config keys remain accepted for migration; that is fine, but
  they should be clearly marked as compatibility-only.

Do this carefully and with tests. Do not let cleanup delay functional release
work.

### AppController remains a coordination hotspot

`Sources/MiriApp/MiriApplication.swift` is approximately 1,368 lines and owns
recording, speech, routing, adapters, overlays, settings, onboarding, models,
queues, and timeouts.

Before `0.1.4`, add focused rapid-hotkey and cancellation tests rather than
attempting a broad refactor. After release, extract a `VoiceSessionCoordinator`
that owns session identity, timeout tasks, cancellation, and re-entry.

### Bundle helper duplication

The 56 MB app includes two approximately 17 MB helpers that statically pull much
of MiriCore/FluidAudio. Moving speech-only code into an app-only target could
reduce helper sizes. This is optimization, not a release blocker.

## Recommended next-session implementation order

### Phase 1: make the first-release scope honest

1. Decide cloud STT scope.
   - Recommended: remove/hide it for `0.1.4`.
   - If retained: implement and live-test the actual upload/transcription path.
2. Remove wake word from all user-facing pickers and menus.
3. Remove model lifecycle profile from Settings/onboarding/config writes.
4. Mark Codex validated; label Claude Code and Hermes experimental unless they
   receive equivalent live testing.
5. Remove Hermes `.streaming` capability unless true incremental SSE is added.

### Phase 2: repair model lifecycle

1. Create a shared model-install consent flow stating approximately 1 GB total.
2. Install/load Parakeet and PocketTTS from the explicit flow.
3. Ensure normal startup never downloads models implicitly.
4. Fix deletion/reset to remove:
   - Miri model/cache paths.
   - Parakeet under Application Support.
   - PocketTTS under `~/.cache/fluidaudio`.
   - Keychain cloud secret, if cloud remains.
5. Verify deletion by checking real directory sizes before and after.

### Phase 3: tighten correctness and release metadata

1. Centralize version `0.1.4` across plist, MCP, Codex client metadata, scripts,
   release notes, and tag.
2. Remove remaining worker-era names/comments that can mislead maintainers.
3. Add rapid push/release/re-entry regression coverage around session state.
4. Update README, AGENTS.md, privacy, installation, model-license, benchmark,
   and release-checklist text to match final architecture and measured sizes.

### Phase 4: human and hardware acceptance

1. Build a fresh current community DMG.
2. Install it rather than running from SwiftPM.
3. Complete at least five consecutive Parakeet → Codex → PocketTTS turns.
4. Rapidly press/release Option-Space and immediately re-enter, repeatedly.
5. Confirm no stale recording, stuck overlay, crash, or forced relaunch.
6. Check `~/Library/Logs/DiagnosticReports/Miri-*.ips` and Miri logs.
7. Test microphone denial and recovery.
8. Test Bluetooth input and output.
9. Test Reduce Motion and VoiceOver labels.
10. Test a fresh macOS user/machine without Xcode:
    - Gatekeeper Open Anyway.
    - Explicit model consent/download.
    - Offline operation after download.
    - Codex discovery/MCP installation.
    - Complete STT → agent → TTS.
11. Test on M1 or clearly label M1 best effort.
12. Live-test Claude Code and Hermes or keep both explicitly experimental.

### Phase 5: benchmark and release artifacts

1. Collect a current M4 benchmark from final `main`:
   - 30 overlay-response samples, p95 below 100 ms.
   - 30 final-transcript samples, p95 below 1 second.
   - First TTS audio, p95 below 500 ms.
   - Idle CPU mean below 1%.
   - Warm RSS maximum below 1.25 GB.
   - Current cold-start measurement.
2. Generate and inspect an SPDX SBOM.
3. Commit and push all intended source changes.
4. Rebuild from that exact pushed commit.
5. Generate new DMG, ZIP, and SHA-256 file.
6. Verify:
   - version `0.1.4` everywhere;
   - arm64-only binaries;
   - ad-hoc signature with `codesign --verify --deep --strict`;
   - DMG integrity and Applications drag target;
   - ZIP/DMG checksums;
   - bundled license/notices;
   - clean installation.
7. Only after all gates pass, create `v0.1.4` and publish one GitHub Release.

## First-release limitations to disclose

- Apple Silicon only.
- macOS 14 or later.
- M4 is the validated hardware; M1 is best effort until physically tested.
- English-first speech output; PocketTTS is currently English.
- Parakeet supports a European-language set, but Hindi/Hinglish is unsupported
  and should not be marketed.
- Push-to-talk only; no wake word in `0.1.4`.
- Codex is the validated adapter. Claude Code and Hermes are experimental unless
  live evidence is recorded.
- Community builds are ad-hoc signed, not Developer-ID notarized. Users must use
  Privacy & Security → Open Anyway.
- No filler removal, spoken correction, custom vocabulary UI, mobile/remote
  relay, worktree/diff dashboard, or broad provider catalog.
- No model weights are embedded; approximately 1 GB downloads on first setup if
  both local STT and TTS are installed.

## Post-release product improvements

## Multi-agent session discovery and attention UX

The next major product problem is not merely target selection or tool approval
in isolation. They are one problem: **which live agent session currently needs
the user, and where should the user's next utterance go?**

### Current behavior and limitations

- Codex thread discovery exists through `thread/list`, but a discovered thread
  must be manually added as a persistent target from Settings.
- The normal route is dedicated hotkey → manually selected target → configured
  default target.
- Miri already snapshots the exact target when recording begins; preserve this
  invariant.
- Codex approval requests are already decoded for command execution, file
  changes, and permission escalation and exposed as
  `AgentEvent.interactionRequested`.
- Miri already speaks a basic approval prompt and requires the exact phrases
  `approve request` or `deny request`.
- Pending interactions are currently keyed by target ID, so only one pending
  request per target can exist; a later request can overwrite an earlier one.
- Free-form questions are inferred from a final response ending in `?`, which is
  not reliable enough for multiple agents.
- Claude Code and Hermes do not yet emit equivalent structured interaction
  requests through their current adapters.

### Recommended product model

Build two small native primitives shared by every adapter:

1. **Live Session Directory** — ephemeral, automatically discovered agent
   sessions and their activity state.
2. **Attention Queue** — ordered questions, approvals, decisions, errors, and
   blockers requiring the user.

Settings should configure integrations and persistent preferences, not serve as
the everyday target switcher.

### Live Session Directory

Introduce a `SessionPresence` value with at least:

- stable agent/session/thread identifier;
- adapter and agent kind;
- project/repository and working directory;
- human-readable label;
- connection and activity state (`idle`, `working`, `needsInput`, `failed`);
- process/window identity when safely available;
- `lastActiveAt` and `lastUserInteractionAt`;
- discovery source and TTL.

Store presence in a `LiveSessionDirectory` actor. Most entries should be
memory-only and expire when the agent disappears. Persist only user aliases,
pinning, and integration preferences. Do not turn every discovered session into
TOML configuration.

Discovery should be adapter-neutral but use the strongest source available:

- Codex: app-server `thread/list`, thread events, and managed app-server
  connections.
- Miri MCP/control socket: session registration, heartbeat, current project,
  activity state, and structured interaction requests.
- Claude Code: use its supported hook/SDK/plugin mechanism after validating the
  exact event contract; do not scrape terminal text.
- Hermes: expose session presence and tool/approval events through its API or a
  Hermes plugin; the current chat-only SSE adapter is insufficient.
- Generic command/clipboard: remain explicit static targets; do not infer
  terminal prompts.

Avoid relying on window titles as the primary identity mechanism. Accessibility
or frontmost-window information may be used as a routing hint only after it maps
to an already registered session.

### Deterministic context resolver

Replace the manually selected target as the only practical route with a scored,
explainable resolver. Recommended priority:

1. An explicit target chosen for the current utterance.
2. The pending interaction the user is currently answering.
3. Exactly one highest-priority session needing attention.
4. A registered session matching the foreground app/window/project.
5. The session the user spoke to most recently, within a bounded recency window.
6. A user-pinned default.
7. If still ambiguous, open the Agent HUD rather than guessing.

Every recording still captures an immutable `RecordingTargetSnapshot` before
audio begins. Auto-routing chooses the snapshot; it must never retarget an
utterance after recording has started.

The overlay should always show the chosen destination immediately, for example:

```text
Listening → Codex · miri
```

The resolver should retain a short reason (`pending approval`, `frontmost
project`, `recent session`, `manual`) for diagnostics and user trust.

### Agent HUD: everyday multi-agent UI

Add a compact, non-activating floating **Agent HUD** rather than requiring
Settings. It should be keyboard-first and visually match Miri's existing status
overlay.

Recommended invocation:

- Hold the existing push-to-talk hotkey: speak immediately to the resolved
  session.
- Quick-tap the same hotkey: open the Agent HUD without starting a recording.
- A separate configurable shortcut can be offered later if tap/hold proves
  ambiguous in hardware testing.

HUD rows should show only:

- agent icon/name;
- project/session label;
- state (`Working`, `Ready`, `Needs approval`, `Needs answer`, `Failed`);
- relative last activity;
- an attention badge.

Sort by:

1. needs attention;
2. foreground-context match;
3. working;
4. recent activity.

Keyboard behavior:

- arrows or number keys select;
- Return pins/selects and begins listening;
- Space shows safe request details;
- Escape dismisses;
- optional actions: rename, pin, mute spoken notifications, open the source
  agent window.

The menu-bar menu may expose the same live list as a secondary path, but the HUD
is the primary interaction. Do not add another permanent dashboard for the
first version of this feature.

Per the project's UI process, decide and review the exact Agent HUD visual
treatment before implementing other new multi-agent UI components.

### Attention Queue

Replace `pendingAgentInteractions: [targetID: PendingAgentInteraction]` with a
queue keyed by interaction/request ID. A target may have multiple pending
requests.

Minimum request fields:

- request ID and target/session ID;
- kind: approval, question, choice, blocked/error;
- safe spoken summary;
- optional display-only details;
- options where applicable;
- creation time and optional expiry;
- adapter response handle;
- risk/sensitivity classification.

Ordering:

1. approvals and blocked turns;
2. direct questions/choices;
3. failures requiring intervention;
4. informational completion notices.

When a request arrives:

1. Mark the session `needsInput`.
2. Badge the menu-bar icon and Agent HUD.
3. Show a compact overlay containing agent + project + safe summary.
4. Speak a concise prompt if spoken notifications are enabled and Miri is not
   recording/speaking something more important.
5. If the user is inactive or speech is muted, optionally issue a native macOS
   notification without sensitive command arguments.

Example:

```text
Codex in miri needs approval to run tests.
Hold Option-Space and say “approve request” or “deny request.”
```

Never speak secrets, full shell commands, diffs, or private paths by default.
Show sanitized details in the HUD and let the user request more detail.

### Reply and approval routing

While an interaction is selected, the next held-hotkey utterance routes directly
to that request's originating session regardless of the normal active target.

Response behavior:

- Approval: exact `approve request` / `deny request`; one-shot scope only for the
  first implementation.
- Question: send transcript text to the structured adapter request when
  supported; otherwise send it as the next user message to the pinned session.
- Choice: support explicit forms such as `choose option two`, after displaying
  and speaking concise options.
- Ambiguous response: do not guess; keep the request pending and ask again.
- Multiple pending requests: the HUD selects one. Voice may disambiguate by
  agent/project name later, but should not be required initially.

Never offer broad spoken approvals such as `approve all`, `always allow`, or
session-wide elevated permission in the first implementation. Approval must be
bound to one structured adapter request ID and fail closed if that request
expires or the adapter disconnects.

### Adapter work

#### Codex

Codex is the first implementation target because most of the transport already
exists:

- app-server thread discovery;
- status/stream events;
- structured command, file-change, and permission approval requests;
- request-ID-bound responses.

Improve it by extracting sanitized command/action summaries and preserving every
pending request instead of one per target. Add automatic transient session
presence rather than forcing every thread into static configuration.

#### Claude Code

Validate the current Claude Code hooks/SDK/plugin APIs for:

- session lifecycle and identity;
- current working directory/project;
- permission/tool-use requests;
- questions and completion;
- sending a response to the exact pending request.

Do not parse ANSI terminal output or simulate keyboard input as the primary
integration. Until structured events are live-validated, label Claude Code's
attention/approval support experimental.

#### Hermes

The current adapter only sends chat and buffers an SSE response. Add a Hermes
plugin/API bridge that emits session presence and structured tool-approval or
question events. Use Miri's neutral interaction contracts rather than coupling
the HUD to Hermes-specific payloads.

### Minimal implementation sequence

1. Refactor pending interactions into a request-ID-keyed `AttentionQueue` with
   tests for multiple requests from one and several targets.
2. Implement `LiveSessionDirectory` and deterministic `ContextResolver` as pure
   MiriCore types with scoring/reason tests.
3. Feed existing Codex thread/status/approval events into both primitives.
4. Add a read-only Agent HUD showing live sessions and pending attention.
5. Allow HUD selection to produce the existing immutable recording snapshot.
6. Add quick-tap-versus-hold behavior only after testing false activations and
   accessibility; keep a separate shortcut fallback.
7. Complete Codex end-to-end approval/question flows with simultaneous agents.
8. Add Claude Code and Hermes presence/interaction bridges one at a time after
   validating each upstream event API.

### Multi-agent acceptance scenarios

- Three Codex sessions in different repositories appear without manual TOML
  target creation.
- Foreground project resolves correctly and the overlay names it before speech.
- Ambiguous context opens the HUD instead of silently choosing the wrong agent.
- Two agents request approval concurrently; neither request is overwritten.
- A question from one agent and approval from another are ordered and clearly
  attributed.
- Replying to an interaction routes to its originating session even if another
  app is foreground.
- A stale/closed request cannot be approved by a delayed transcript.
- Disconnect declines/fails pending approvals safely.
- Spoken summaries omit secrets, full commands, diffs, and private paths.
- Muting one noisy agent does not hide its HUD badge.
- The normal single-agent path remains one hold-and-speak action with no picker.

### High-value FluidAudio follow-ups

- Expose Parakeet's supported language selection and pass a real language hint.
- Add vocabulary boosting for coding terms, repository names, agent names, and
  symbols such as SwiftUI, AVFoundation, Codex, Miri, and Parakeet.
- Integrate inverse text normalization for numbers, dates, currency, and spoken
  punctuation.
- Evaluate FluidAudio streaming ASR for partial transcripts.
- Evaluate FluidAudio VAD and endpoint/EOU detection for a future hands-free
  mode.
- Evaluate additional PocketTTS language packs only after measuring size,
  quality, and voice availability.
- Evaluate a native wake model before reintroducing wake-word UI.

### Dictation-quality improvements

- Optional filler-word removal.
- Repetition cleanup.
- Explicit spoken self-correction/backtracking.
- Preserve raw transcript access and avoid silently rewriting coding commands.
- Domain vocabulary learned from target repository names and symbols, with
  clear privacy boundaries.

### Architecture improvements

- Extract `VoiceSessionCoordinator` after the release.
- Make Hermes SSE truly incremental.
- Remove obsolete MiriIPC/worker protocol code if no external compatibility
  requirement remains.
- Split speech-only code from helper-linked MiriCore to reduce bundled CLI/MCP
  sizes.
- Add release packaging smoke checks to CI.

## Useful verification commands

```sh
cd /Users/adityakanu/Developer/miri

git status --short
git branch --show-current
swift test

# Build the unsigned arm64 Release app used before signing.
scripts/build-release.sh 0.1.4
file .release/Miri.app/Contents/MacOS/Miri
du -sh .release/Miri.app

# Community artifacts after the release blockers are resolved.
scripts/build-community.sh 0.1.4
(cd dist && shasum -a 256 -c Miri-0.1.4.sha256)
codesign --verify --deep --strict .preview/Miri.app
hdiutil verify dist/Miri-0.1.4.dmg

# Inspect live model storage.
du -sh "$HOME/Library/Application Support/FluidAudio" 2>/dev/null
du -sh "$HOME/.cache/fluidaudio" 2>/dev/null

# Check for crashes after hardware acceptance.
ls -lt "$HOME/Library/Logs/DiagnosticReports"/Miri-*.ips 2>/dev/null
```

## Release decision

The fastest credible first release is intentionally narrow:

- local Parakeet transcription;
- local English PocketTTS with system fallback;
- push-to-talk;
- Codex validated;
- Clipboard fallback;
- Claude Code and Hermes experimental;
- no wake word;
- no fake lifecycle profiles;
- no cloud STT until the real path works.

This scope is differentiated, small, private, and honest. Avoid delaying it to
match Wispr Flow's general-dictation breadth. Fix the exposed contract defects,
complete current-revision benchmarks and clean-machine acceptance, then ship.