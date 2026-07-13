# Miri: macOS Voice Bridge

## Version 1 Product Scope

Status: Draft  
Target platform: Apple Silicon MacBook  
Initial operating system: macOS 14 Sonoma or newer  
Distribution: Open source, local-first, outside the Mac App Store initially

## 1. Product vision

Miri is a lightweight background macOS application that gives coding and AI agents a shared local voice interface.

The user can hold a configurable global hotkey, speak a prompt, and route the resulting transcript to a selected agent session. Agents can deliberately speak short progress updates, blockers, approval requests, questions, and completion notices through a small local text-to-speech service.

Miri must not narrate complete agent responses. Voice is a concise interaction channel, while the terminal or agent UI remains the authoritative place for detailed output.

The guiding principle is:

> Hotkey in, short status out, with an unmistakable destination.

## 2. Version 1 goals

Version 1 will:

- Run as a native macOS menu-bar application.
- Target Apple Silicon MacBooks first.
- Perform speech recognition and speech synthesis locally after model download.
- Support push-to-talk with user-configurable global hotkeys.
- Offer an optional, clearly visible wake-word mode.
- Display a compact animated notch-adjacent status pill.
- Route transcripts to an explicitly selected, addressable agent session.
- Support a default target and optional per-target hotkeys.
- Provide adapters for Codex, Claude Code, Hermes Agent, generic commands, and clipboard fallback.
- Let agents request short spoken updates through a local tool/API.
- Keep idle resource usage negligible in push-to-talk mode.
- Keep speech engines modular so users can replace models without changing the application.

## 3. Version 1 non-goals

The following are intentionally outside version 1:

- Narrating complete agent answers.
- Full-duplex conversation or acoustic echo cancellation.
- Automatically guessing the destination from the frontmost terminal.
- Multiple simultaneous sessions for the same configured target.
- Arbitrary custom wake-word training.
- Speaker diarization.
- Cloud speech-to-text or text-to-speech.
- Transcript history, search, or cloud synchronization.
- A mobile companion application.
- Windows or Linux support.
- Intel Mac optimization.
- A voice-cloning enrollment UI.
- Network discovery of agents.
- Mac App Store distribution.

## 4. Supported platform

The first supported configuration is:

- MacBook with an M1 processor or newer.
- macOS 14 Sonoma or newer.
- Built-in or user-selected microphone and speakers.
- English speech recognition and synthesis as the release-tested language.
- No GPU requirement.
- No network connection after required models are installed.

External monitors and MacBooks without a notch remain supported through a top-center overlay fallback.

## 5. User experience

### 5.1 Primary push-to-talk interaction

1. The user presses and holds a global shortcut.
2. Miri snapshots the current target session.
3. The notch pill appears immediately and shows the target name.
4. Audio bars indicate that Miri is listening.
5. The user releases the shortcut.
6. Miri finalizes the transcript and routes it to the snapshotted target.
7. The pill shows delivery progress and a receipt.
8. The pill closes automatically.

Escape cancels an active recording without sending it.

Pressing a listening hotkey while speech is playing stops playback and starts a new recording. Version 1 is half-duplex: speech recognition pauses while Miri is speaking so the assistant does not transcribe itself.

### 5.2 Hotkey modes

Miri supports two routing patterns:

#### Active-target hotkey

A single shortcut routes speech to whichever target the user selected from the menu bar.

Example:

```text
Option + Space -> active target
```

#### Per-target hotkeys

Each target can optionally define a dedicated shortcut.

Example:

```text
Option + Shift + C -> Codex / Miri project
Option + Shift + A -> Claude Code / website project
Option + Shift + H -> Hermes / personal session
```

The application should not claim common shortcuts automatically. The first-launch flow asks the user to choose shortcuts and warns about conflicts.

### 5.3 Wake-word mode

Wake-word mode is experimental in version 1 and is disabled by default.

When enabled:

- One configured wake-word model runs locally.
- A visible menu-bar or notch indicator shows that passive listening is enabled.
- The wake word opens one utterance.
- Voice activity detection determines when that utterance ends.
- The utterance is sent to the active/default target.
- A configurable timeout prevents indefinite recording.
- The menu bar provides an immediate Disable Wake Word action.

Version 1 accepts a prebuilt wake-word model and threshold through configuration. It does not train arbitrary wake words.

## 6. Notch status pill

The interface is a custom notch-adjacent overlay, not an Apple Dynamic Island API.

Implementation requirements:

- Use a small borderless, non-activating `NSPanel`.
- Position it using `NSScreen.safeAreaInsets` and auxiliary top screen geometry.
- Never steal keyboard focus from the active agent or terminal.
- Remain above ordinary windows only while relevant.
- Use a top-center floating pill on screens without a notch.
- Prefer the active display, with a configuration option to pin a display.

### 6.1 Visual states

| State | Minimal presentation |
| --- | --- |
| Hidden | No overlay |
| Listening | Target name/icon and animated audio bars |
| Transcribing | Moving dots or a small spinner |
| Sending | Directional arrow toward the target |
| Delivered | Brief checkmark followed by dismissal |
| Queued | Clock symbol and target name |
| Agent speaking | A differently colored waveform |
| Needs input | Amber pulse with a short label |
| Error | Red pulse with a concise error |
| Cancelled | Immediate fade-out |

The standard presentation should contain only an animation and the target label:

```text
[waveform] Codex - Miri
```

Full transcript display is disabled by default. Users may enable a one-line final-transcript preview.

## 7. Agent routing

Miri distinguishes an agent type from an addressable target session.

```text
Agent type: Codex
Target: Codex - Miri project
Session: One specific connected local session
```

Selecting only an agent type is insufficient because several projects or sessions may be open simultaneously.

### 7.1 Target definition

Each configured target contains:

- Stable target ID.
- User-facing name.
- Agent type.
- Adapter type.
- Working directory or project identity.
- Session or endpoint address when required.
- Optional dedicated hotkey.
- Enabled state.
- Delivery capabilities.

### 7.2 Routing priority

At recording start, Miri resolves the destination in this order:

1. The target bound to the pressed per-target hotkey.
2. The target selected in the menu bar.
3. The configured default target.
4. No target: keep the transcript locally and show an actionable error.

The destination is snapshotted when recording begins. Changing the active target during recording affects only the next utterance.

Miri never silently reroutes a message when delivery fails.

### 7.3 Target states

Adapters report one of these states:

- Available
- Busy but steerable
- Busy and queueable
- Waiting for user
- Disconnected
- Misconfigured

Version 1 permits at most one queued voice message per target. A newer queued message can replace the old one only after explicit user confirmation or a configured replacement policy.

## 8. Agent adapters

All agent integrations implement a shared interface:

```text
connect()
status()
send_user_message(text)
cancel_current_turn()
subscribe_to_events()
disconnect()
```

### 8.1 Initial adapters

Version 1 includes:

- Codex adapter.
- Claude Code adapter.
- Hermes Agent adapter.
- Generic command adapter.
- Clipboard-only fallback.

The preferred adapters use supported agent protocols or app-server connections. Existing arbitrary terminal sessions cannot always accept external user turns reliably; those cases must use an app-managed/addressable session or fall back to clipboard delivery.

### 8.2 Generic command adapter

The generic adapter launches a configured executable and sends the transcript through standard input. Transcripts must never be interpolated into a shell command string.

### 8.3 Clipboard fallback

The clipboard adapter copies the transcript and reports `Copied`, not `Delivered`. It must not simulate keystrokes or paste into an unknown application in version 1.

## 9. Agent-to-user speech

Miri exposes a local tool and equivalent HTTP/Unix-socket operation:

```text
voice_status(
    text,
    priority = "progress",
    interruptible = true
)
```

Agents use this only for:

- Meaningful progress during longer work.
- Approval requests.
- Questions and blockers.
- Warnings.
- Completion notices.

The service enforces:

- Maximum 180 characters.
- Prefer fewer than 18 spoken words.
- No code blocks.
- No raw logs.
- No secrets or authentication tokens.
- No complete final-answer narration.
- Rate limiting.
- Duplicate suppression.
- Priority-aware interruption.

Recommended agent instruction:

> Use `voice_status` only for meaningful progress, blockers, approval requests, questions, and completion. Keep it under 18 spoken words. Never narrate the full response, source code, logs, paths, or secrets.

Lifecycle hooks can generate safe templates such as `Codex needs approval`. The explicit tool produces contextual messages such as `The tests pass. I am checking the package now.`

## 10. Speech model strategy

Speech engines are providers selected through configuration. Provider-specific dependencies run behind the same internal interface.

### 10.1 Text-to-speech candidates

| Provider | Approximate size | Key capabilities | Intended role |
| --- | ---: | --- | --- |
| Pocket TTS | 100M parameters | CPU streaming, low first-chunk latency, voice cloning, six languages | Version 1 example and initial default |
| MOSS-TTS-Nano | 100M parameters | CPU real-time generation, multilingual voice cloning, approximately 20 languages | Multilingual candidate |
| Kokoro | 82M parameters | Lightweight, natural preset voices, permissive weights | Stable non-cloning fallback |
| KittenTTS | 15M-80M parameters | ONNX CPU inference, 25-80 MB variants | Eco/ultra-light mode |
| Piper | Voice-dependent | Mature local CPU synthesis and broad voice catalog | Compatibility and embedded fallback |
| Qwen3-TTS | 600M-1.7B parameters | Expressive control, voice design, cloning, ten languages | Optional premium quality tier, not resident by default |

Version 1 uses Pocket TTS as the worked example because it provides true streaming, voice cloning, and concrete low-core CPU performance while remaining much smaller than the premium models.

Qwen3-TTS is treated only as an optional provider candidate. Miri has no dependency on any previous ComfyUI integration or node system.

### 10.2 Speech-to-text candidates

| Provider | Approximate size | Key capabilities | Intended role |
| --- | ---: | --- | --- |
| Moonshine Tiny Streaming | 34M parameters | Very low compute, streaming English recognition | Eco mode |
| Moonshine Small Streaming | 123M parameters | Better accuracy with low streaming latency | Version 1 example and initial default |
| Moonshine Medium Streaming | 245M parameters | Higher accuracy while remaining edge-oriented | Accuracy mode |
| whisper.cpp Tiny/Base | 39M/74M parameters before quantization | Proven portability, quantization, broad platform support | Compatibility fallback |
| SenseVoice Small | Approximately 234M parameters | Fast non-autoregressive multilingual recognition | Multilingual/Asian-language candidate |
| Fun-ASR Nano | Approximately 0.6B decoder plus encoder | Strong multilingual and service features | Optional higher-compute tier |
| Parakeet Unified | Approximately 0.6B parameters | Strong English accuracy and streaming support | Optional higher-accuracy tier |

Version 1 uses Moonshine Small Streaming as the worked example. Moonshine Tiny is the configurable low-power profile, while whisper.cpp Base remains the first compatibility fallback.

### 10.3 Voice activity and wake-word candidates

- Silero VAD is the initial voice-activity detector.
- openWakeWord is the initial wake-word framework candidate.
- Push-to-talk bypasses continuous STT and is always the default.

### 10.4 Provider contracts

Text-to-speech providers implement:

```text
load()
prepare_voice()
stream(text, voice, options)
stop()
unload()
health()
```

Speech-to-text providers implement:

```text
load()
start_stream(sample_rate)
accept_audio(samples)
partial_transcript()
finish_stream()
cancel()
unload()
health()
```

## 11. Version 1 example configuration

Miri uses TOML for human-editable configuration.

```toml
version = 1
default_target = "codex-miri"
input_mode = "push_to_talk"

[ui]
overlay = "notch"
show_transcript_preview = false
display = "active"
animation = "waveform"

[audio]
input_device = "default"
output_device = "default"
pause_stt_while_speaking = true
speech_volume = 0.85

[hotkeys]
active_target = "option+space"
cancel = "escape"
stop_speaking = "option+shift+space"

[stt]
provider = "moonshine"
model = "small-streaming"
language = "en"
transcription_interval_ms = 500

[tts]
provider = "pocket-tts"
model = "default"
voice = "alba"
max_characters = 180

[vad]
provider = "silero"
threshold = 0.5
minimum_silence_ms = 500

[wakeword]
enabled = false
provider = "openwakeword"
model_path = "~/.miri/models/wakeword.onnx"
threshold = 0.55
utterance_timeout_seconds = 20

[[targets]]
id = "codex-miri"
name = "Codex - Miri"
adapter = "codex"
working_directory = "~/Developer/miri"
hotkey = "option+shift+c"

[[targets]]
id = "claude-website"
name = "Claude Code - Website"
adapter = "claude-code"
working_directory = "~/Developer/website"
hotkey = "option+shift+a"

[[targets]]
id = "hermes-personal"
name = "Hermes - Personal"
adapter = "hermes"
endpoint = "ws://127.0.0.1:9000"
hotkey = "option+shift+h"
```

Configuration requirements:

- Validate the entire file at startup.
- Report errors with file and line information.
- Reload automatically after valid external edits.
- Keep the Settings UI and file synchronized.
- Warn about unknown keys rather than ignoring them silently.
- Use atomic writes from the Settings UI.
- Offer `Open Config File` from the menu bar.

## 12. Menu-bar application

The native menu contains:

```text
Miri
--------------------------------
Active Target
  [x] Codex - Miri
  [ ] Claude Code - Website
  [ ] Hermes - Personal

Listen Now
Stop Speaking
--------------------------------
Input Mode
  [x] Push to Talk
  [ ] Wake Word

Mute Agent Speech
Open Settings...
Open Config File
View Logs
Quit Miri
```

Miri should normally run as an accessory application without a Dock icon. The menu bar remains the durable control surface; the notch pill is transient feedback.

## 13. Technical architecture

```text
Native Swift macOS application
|-- Menu bar and settings
|-- Notch overlay
|-- Global hotkeys
|-- Audio capture and playback
|-- Target/session router
`-- Local service supervisor
          |
          | Unix-domain socket, versioned JSON messages
          v
Local speech service
|-- VAD and wake-word providers
|-- STT provider registry
|-- TTS provider registry
|-- Model lifecycle and downloads
`-- Audio/transcript event stream
          |
          v
Agent adapters
|-- Codex
|-- Claude Code
|-- Hermes Agent
|-- Generic command
`-- Clipboard
```

### 13.1 Native application

Use Swift, SwiftUI, and AppKit for:

- Menu-bar lifecycle.
- Settings.
- Notch positioning.
- Non-activating overlay behavior.
- Global shortcuts.
- Permission onboarding.
- Audio-device selection.
- Worker supervision.

### 13.2 Speech worker

The first implementation may use a local Python worker for Pocket TTS and Moonshine. It communicates only over a local Unix-domain socket.

The worker:

- Runs independently of the UI process.
- Loads only configured providers.
- Keeps the selected models warm.
- Streams partial transcripts and audio chunks.
- Can restart without terminating the macOS application.
- Uses a versioned message protocol.
- Verifies downloaded model checksums.

Provider interfaces allow later replacement with MLX, Core ML, ONNX, Rust, or C++ implementations without changing agent adapters or UI behavior.

## 14. Local protocol

The Unix-socket protocol uses newline-delimited JSON or length-prefixed JSON messages with an explicit protocol version.

Representative events:

```text
hello
health
audio.start
audio.chunk
audio.stop
transcript.partial
transcript.final
speech.start
speech.chunk
speech.stop
model.progress
error
```

Every request includes:

- Protocol version.
- Request ID.
- Session ID where relevant.
- Timestamp.

No socket is exposed beyond the local user account by default.

## 15. Privacy and security

Version 1 privacy requirements:

- Audio remains on the local machine.
- No analytics by default.
- No recording history by default.
- Temporary audio buffers are discarded after transcription.
- Wake-word mode is always visibly indicated.
- Logs omit raw audio and full transcripts by default.
- Debug transcript logging requires explicit opt-in.
- Spoken agent messages are filtered for obvious secrets.
- Generic commands receive transcripts through standard input.
- Agent targets are never silently changed.
- The user can delete downloaded models and all local Miri data.

The macOS application includes the required microphone usage description and audio-input entitlement. The onboarding flow explains why microphone access is required before requesting it.

## 16. Error handling

Miri provides actionable failures for:

- Microphone permission denied.
- Input device unavailable.
- Model missing or corrupted.
- Speech worker unavailable.
- Shortcut conflict.
- Target disconnected.
- Adapter authentication or connection failure.
- Transcript empty or below confidence threshold.
- TTS generation failure.

Failed transcripts remain in a temporary local outbox until copied, retried, edited, or discarded. Miri never reports `Delivered` without an adapter receipt.

## 17. Performance budgets

Release targets on warm Apple Silicon hardware:

- Hotkey-to-listening animation: under 100 ms.
- Release-to-final-transcript: under 1 second at p95 for a normal utterance.
- Spoken-status request to first audio: under 500 ms at p95.
- Push-to-talk idle CPU: below 1%.
- Wake-word idle target: below 5% of one M-series CPU core.
- Warm resident memory target: below 1.25 GB for the default profile.
- No GPU requirement.
- No network use after model installation.
- No self-transcription during speech playback.

Performance must be measured on at least an M1 and an M4 machine before version 1 release.

## 18. Accessibility

Version 1 includes:

- Reduce Motion support.
- High-contrast overlay colors.
- System text scaling in Settings.
- VoiceOver labels for menu-bar and Settings controls.
- Optional sound cues for listening start, cancellation, and delivery.
- Visual state changes that do not depend only on color.
- Fully keyboard-accessible Settings.

## 19. Testing strategy

### 19.1 Unit tests

- TOML parsing and migration.
- Target routing priority.
- Hotkey conflict detection.
- Speech-status length and secret filtering.
- Adapter state transitions.
- Protocol message validation.
- Queue replacement policy.

### 19.2 Integration tests

- Microphone capture to final transcript.
- Transcript delivery to each supported adapter.
- Agent `voice_status` to streamed playback.
- Worker crash and restart.
- Target disconnect during recording.
- Configuration live reload.
- Model download interruption and resume.

### 19.3 Manual release matrix

- M1 MacBook.
- M4 MacBook.
- Built-in microphone.
- Bluetooth headset.
- External monitor.
- Notched and non-notched screen behavior.
- Codex, Claude Code, and Hermes targets.
- Push-to-talk and wake-word modes.

## 20. Delivery milestones

### M0: technical spike

- Native notch overlay.
- Hold/release global shortcut.
- Microphone capture.
- Moonshine Small Streaming transcription.
- Pocket TTS streaming playback.
- Initial M1 performance measurements.

### M1: local voice loop

- Complete state machine and animations.
- Speech-worker supervision.
- Cancellation and error recovery.
- TOML loading and live reload.
- Menu-bar application.
- Model download and health status.

### M2: target routing

- Target registry.
- Default target selection.
- Per-target hotkeys.
- Generic command adapter.
- Clipboard fallback.
- Delivery receipts and disconnected states.

### M3: agent integrations

- Codex adapter and `voice_status` integration.
- Claude Code adapter and lifecycle hooks.
- Hermes adapter and lifecycle hooks.
- Adapter conformance test suite.

### M4: wake word and release polish

- openWakeWord provider.
- Silero VAD endpointing.
- Settings window.
- First-launch permission flow.
- Signing and notarization.
- Installation and adapter documentation.
- M1/M4 release benchmark report.

## 21. Version 1 release criteria

Version 1 is complete when:

1. A user can install Miri on an Apple Silicon Mac.
2. The first-launch flow configures microphone permission and at least one hotkey.
3. The user can configure Codex, Claude Code, and Hermes targets.
4. Holding a hotkey starts recording without stealing focus.
5. The notch pill clearly identifies the snapshotted destination.
6. Releasing the hotkey produces a local transcript and routes it to the correct live target.
7. Delivery success is based on an adapter receipt.
8. An agent can speak a concise status through `voice_status`.
9. Complete agent answers are never narrated automatically.
10. Push-to-talk idle resource usage stays within budget.
11. No user audio or transcript leaves the machine.
12. The application recovers from a crashed speech worker.
13. The default Pocket TTS and Moonshine Small Streaming profile meets the latency targets on M1 and M4 hardware.

## 22. Decisions recorded for version 1

- Project name: Miri.
- Platform: Apple Silicon macOS first.
- Primary interaction: hold-to-talk.
- Optional interaction: experimental wake word.
- UI: transient notch-adjacent pill plus persistent menu bar.
- Routing: explicit addressable targets, not automatic frontmost-app guessing.
- Default example TTS: Pocket TTS.
- Default example STT: Moonshine Small Streaming.
- Default VAD: Silero VAD.
- Wake-word candidate: openWakeWord.
- Audio mode: half-duplex.
- Configuration: TOML.
- Processing: local after model download.
- Distribution: open source and outside the Mac App Store initially.
