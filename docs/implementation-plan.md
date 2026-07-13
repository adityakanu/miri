# Miri v1 complete implementation plan

This plan turns `scope.md` into buildable slices. A slice is complete only when
its unit tests pass and it participates in at least one integration test.

## Architecture boundaries

- `MiriIPC`: versioned framing and message schemas only; no product policy.
- `MiriCore`: configuration, routing, adapters, lifecycle, status policy, and
  worker supervision. It must not import a provider-specific model package.
- `MiriNative`: AppKit/AVFoundation components: audio, hotkeys, overlay, devices,
  and permissions. These components do not select agent targets.
- `MiriApp`: composition root and user-facing menu/settings/onboarding.
- `miri-worker`: replaceable speech inference process. It owns STT/TTS/VAD and
  wake-word providers, but never routes agent messages or plays audio.
- `miri` and `miri-mcp`: clients of the private control socket. No HTTP listener.

## Slice 1: shared contracts and deterministic loop

1. Define every IPC v1 request/event (`hello`, `health`, `audio.*`,
   `transcript.*`, `speech.*`, `model.progress`, `cancel`, and `error`).
2. Use length-prefixed frames with protocol/request/session IDs and JSON or PCM.
3. Keep golden frames readable by Swift and Python tests.
4. Provide deterministic STT/TTS providers and a fake adapter so CI can prove
   capture -> transcript -> route and status -> chunks -> playback without models.
5. Supervise worker launch, health checks, cancellation, crash detection, bounded
   restart/backoff, and clean shutdown.

Exit gate: Swift/Python golden tests and both deterministic end-to-end flows pass.

## Slice 2: native interaction shell

1. Request microphone permission only after explanatory onboarding.
2. Capture input through AVFoundation and convert to 16 kHz mono float32.
3. Play streamed 24 kHz mono float32 without writing temporary audio files.
4. Register configurable global press/release hotkeys and Escape cancellation;
   detect duplicate/conflicting configured shortcuts.
5. Implement the half-duplex state machine and audio-device change recovery.
6. Present a nonactivating notch-aware panel on the active/pinned display with a
   top-center fallback, Reduce Motion behavior, contrast, and VoiceOver labels.

Exit gate: manual hold/release and automated state/cancellation tests pass without
focus stealing on notched, non-notched, and external displays.

## Slice 3: configuration and models

1. Parse `~/.config/miri/config.toml`, validate the complete document, report
   file/line errors, and warn for unknown keys.
2. Atomically write Settings edits and live-reload valid external edits while
   reporting conflicts rather than overwriting them.
3. Implement `responsive`, `balanced`, and `eco` lifecycle policies.
4. Require explicit consent before model downloads. Use pinned manifests,
   SHA-256 checksums, resume support, progress events, health checks, deletion,
   and local-path overrides.
5. Never log audio/full transcripts unless explicit debug logging is enabled.

Exit gate: config migration/reload/conflict and interrupted download tests pass.

## Slice 4: routing and delivery

1. Maintain addressable target definitions and adapter capabilities/status.
2. Resolve per-target hotkey, selected target, then default target and snapshot
   the result at recording start.
3. Never reroute after failure. Require a delivery receipt before `Delivered`.
4. Permit one queued message per target with explicit/configured replacement.
5. Keep failures in a memory-only outbox supporting retry/edit/copy/discard.
6. Ship generic-command stdin and clipboard (`Copied`) adapters first.

Exit gate: routing precedence, snapshot, disconnect, queue, receipt, and outbox
tests pass against the adapter conformance suite.

## Slice 5: agent integrations and spoken status

1. Implement Codex app-server transport behind `AgentAdapter`, with managed
   generic-command/clipboard fallback and no Codex types in core UI/routing.
2. Add Claude Code and Hermes integrations using the identical conformance suite.
3. Implement MCP `initialize`, `tools/list`, and `tools/call` over stdio plus the
   equivalent `miri status` client.
4. Enforce 180 characters, preferred 18 words, rate limiting, deduplication,
   code/log/path/token rejection, and priority-aware interruption.
5. Supply safe lifecycle-hook templates for progress/input/approval/completion.

Exit gate: every adapter passes conformance tests and MCP-to-speaker integration.

## Slice 6: real speech providers

1. Integrate Moonshine Small Streaming, Pocket TTS, and Silero behind provider
   protocols with pinned versions/licenses. Keep deterministic providers for CI.
2. Stream partial/final transcripts and TTS chunks; cancellation must release the
   active session without unloading warm models.
3. Add Moonshine Tiny for eco and provider health/fallback diagnostics.
4. Add experimental openWakeWord, visible persistent listening state, Silero
   endpointing, and a hard utterance timeout. It stays disabled by default.

Exit gate: downloaded default models pass local capture/transcription/playback,
offline restart, corrupted-model, cancellation, and self-transcription tests.

## Slice 7: product UI and resilience

1. Build first-run onboarding, menu target selection/input mode/actions, Settings
   for audio/hotkeys/models/targets/privacy, config/log access, and data deletion.
2. Surface permission, device, model, worker, shortcut, adapter, and empty/low
   confidence failures with recovery actions.
3. Restore worker, device, config, and adapters independently after failures.
4. Verify keyboard navigation, VoiceOver, text scaling, Reduce Motion, visual
   non-color cues, Bluetooth changes, external monitors, and no focus stealing.

Exit gate: integration and manual release matrix in `scope.md` is signed off.

## Slice 8: performance and release

1. Record cold start, warm RSS, idle CPU, overlay response, final transcript p95,
   and first-audio p95 through a reproducible benchmark command.
2. Qualify Python only below the locked budgets; otherwise label it preview and
   retain the IPC boundary for a native v2 provider replacement.
3. Bundle the Python interpreter/worker/models bootstrap; users install no Python.
4. Harden/sign/notarize `Miri.app`, create a DMG/checksum/SBOM, publish a GitHub
   Release, and point the Homebrew Cask at that exact artifact/checksum.
5. Document privacy, configuration, adapters, model licenses, M4 validation, and
   M1 best-effort status until physical M1 results exist.

Exit gate: clean-machine install and offline use pass; artifacts are signed,
notarized, checksummed, and the release criteria in `scope.md` are all evidenced.

## Required automated suites

- Swift: IPC, configuration, state machine, hotkeys, target snapshots, routing,
  queue/outbox, status filtering, adapter capabilities, and worker restarts.
- Python: protocol validation, lifecycle, cancellation, transcript finalization,
  streamed audio, health, model checksums/resume, and malformed input.
- Contract: golden fixtures in both languages and one conformance suite per adapter.
- Integration: hold/release, cancellation, crash/restart, reload, failed delivery,
  outbox actions, interruption, download recovery, and MCP-to-speaker.

## Release blockers requiring real external systems

Model package APIs/weights and licenses must be pinned after a successful local
spike. Codex, Claude Code, and Hermes transports require their installed CLIs or
documented local protocols for live verification. Signing/notarization requires an
Apple Developer identity, credentials, and release repository access. M1/M4
performance gates require runs on both physical hardware classes.
