# Architecture

Miri separates native product behavior from replaceable inference. `MiriCore`
contains agent-neutral contracts, routing policy, and the speech engines.
`MiriApp` owns UI and audio. `MiriIPC` is the versioned framing layer for the
MCP helper and the private control socket — never for audio.

## Speech runs in-process on CoreML

All speech is Swift + CoreML through [FluidAudio](https://github.com/FluidInference/FluidAudio)
(pinned to `0.15.6` in `Package.resolved`). There is no Python runtime, no
worker subprocess, and no audio IPC anywhere in the product.

| Stage | Type | Model | Compute placement |
| --- | --- | --- | --- |
| Transcription | `ParakeetTranscriber` | NVIDIA Parakeet TDT v3 | Encoder runs on the Apple Neural Engine (`.cpuAndNeuralEngine`); the preprocessor runs CPU-only |
| Speech output | `FluidSpeechSynthesizer` | PocketTTS | FluidAudio's default placement, which is GPU-backed (`.cpuAndGPU`) — **not** the Neural Engine |

Do not describe TTS as running on the Neural Engine. Only the Parakeet encoder
is ANE-resident today.

Microphone samples reach the transcriber as a direct in-process call, so audio
is never serialised across a process boundary. PocketTTS emits 24 kHz mono
Float32 frames that `SpeechPCMPlayer` consumes directly.

Both engines are actors and share a single in-flight load task, because an
`await` inside the actor otherwise lets a second caller past the `manager == nil`
check and compiles the CoreML encoder twice.

## Model storage

The two engines use two different FluidAudio roots. Any "delete models"
operation must clear both or it leaves most of a gigabyte behind.

| Model | Location | Approximate size |
| --- | --- | --- |
| Parakeet TDT v3 | `~/Library/Application Support/FluidAudio/Models` | ~470 MB |
| PocketTTS voice | `~/.cache/fluidaudio/Models/pocket-tts` | ~520 MB |

Neither is embedded in the shipped bundle. Both are fetched from Hugging Face
after one explicit consent prompt covering the ~1 GB total. Without consent,
`ModelHub.offlineMode` is set and every network fetch is refused.

## Scope exposed in 0.1.4

Several types exist in the source for future work but are deliberately not
user-selectable in this release. The `supportedCases` arrays are the source of
truth, not the full enum cases.

- `STTBackend.supportedCases == [.parakeet]`. Parakeet is the only transcription
  backend a user can select. The `.cloud` OpenAI-compatible path
  (`CloudSTTProvider`, Keychain-backed key, Settings UI) is still compiled and
  tested, but it is not offered in the 0.1.4 picker.
- `MiriInputMode.supportedCases == [.pushToTalk]`. Wake word is not selectable;
  push-to-talk is the only input mode.
- `ModelLifecycleProfile` still exists as a type but has no picker in Settings,
  so users cannot choose responsive/balanced/eco in 0.1.4.

## Adapter capabilities

Capabilities are declared per adapter as `AdapterCapabilities` and must match
what the adapter actually implements.

| Adapter | Declared capabilities |
| --- | --- |
| Codex (`CodexAppServerAdapter`) | `cancellation`, `streaming`, `interactiveRequests` |
| Claude Code | `cancellation` |
| Hermes (`HermesAdapter`) | `cancellation` |
| Generic command | `cancellation` |
| Clipboard | none |

Hermes does **not** advertise streaming. Codex is the only adapter with
streaming and interactive-request support.

## Versioning

The single source of truth for the product version is
`MiriVersion.current` in `Sources/MiriCore/MiriVersion.swift`. It is consumed by
`miri-mcp`'s `serverInfo` and by the Codex adapter's `clientInfo`. Packaging
scripts set `CFBundleShortVersionString` from their `<version>` argument; that
argument must agree with `MiriVersion.current`.

## Packaging

`scripts/build-community.sh` builds the arm64-only `Miri.app` with XcodeGen and
Xcode, then installs the `miri` CLI and `miri-mcp` helper into
`Contents/Helpers/` and re-signs the completed bundle ad-hoc. The packaged
Release app is approximately **56 MB**, including both helpers. No inference
runtime and no model weights are embedded.

## Routing rules

No Codex-specific type is permitted in core routing or UI. Adapters belong in
separate modules and conform to `AgentAdapter`.
