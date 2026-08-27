# Privacy and security

Miri processes audio locally after an explicit, one-time model download. It does
not expose an HTTP server, enable analytics, or persist transcript history. The
private control socket is created below `$TMPDIR/miri` for the current user.

## Speech runs inside the app

Both directions of the voice loop are CoreML models running in Miri's own
process, via FluidAudio:

- **Transcription:** NVIDIA Parakeet TDT v3. The encoder runs on the Apple
  Neural Engine.
- **Speech output:** PocketTTS. It runs at FluidAudio's default compute
  placement, which is GPU-backed rather than on the Neural Engine.

There is no Python runtime, no worker subprocess, and no local IPC for audio.
Microphone samples reach the model as an in-process function call and are never
serialised across a process boundary.

## Model download requires explicit consent

Miri ships no model weights. On first use it asks once for permission to
download about **1 GB** from Hugging Face:

| Model | Location | Approximate size |
| --- | --- | --- |
| Parakeet transcription | `~/Library/Application Support/FluidAudio/Models` | ~470 MB |
| PocketTTS voice | `~/.cache/fluidaudio/Models/pocket-tts` | ~520 MB |

One consent prompt covers both, so an incoming agent reply can never silently
start a download on its own. Until you consent, `ModelHub.offlineMode` is set
and every network fetch is refused; speech simply reports that the model is not
installed. After the download, transcription and speech synthesis work with no
network access at all.

**Delete Models** and **Reset All Data** both remove *both* roots above, not
just the Application Support tree.

## Transcription is on-device

Parakeet is the only transcription backend. The OpenAI-compatible cloud path was
deleted along with the Python worker: there is no cloud provider, no
Keychain-stored API key, and no network egress on the transcription path. No
utterance audio leaves your Mac.

If a future release introduces cloud transcription, it will be opt-in and off by
default, each utterance will be uploaded over TLS, that audio will be governed
by the chosen provider's retention terms rather than Miri's, and any API key
will be stored in the macOS Keychain rather than in `config.toml`.

## Dictation to the focused app

The optional dictation target types your transcript into whichever application
currently has keyboard focus. It uses synthesized key events, so your clipboard
is never read or overwritten, and it requires macOS Accessibility permission —
without that permission Miri refuses to send rather than silently dropping the
text. Nothing is captured from the target application; the flow is one-way.

## Data locations

- configuration: `~/.config/miri/config.toml`
- application data: `~/Library/Application Support/Miri`
- Parakeet models: `~/Library/Application Support/FluidAudio/Models`
- PocketTTS voice: `~/.cache/fluidaudio/Models`
- caches: `~/Library/Caches/Miri`
- logs: `~/Library/Logs/Miri`

Audio buffers are discarded after transcription. Failed transcripts are held
only in the in-memory outbox and disappear on quit. Normal logs must not contain
raw audio or complete transcripts. Agent speech passes through length,
repetition, code, and obvious-secret filters, but those filters are defense in
depth rather than a guarantee that arbitrary text is safe to say aloud.

## What you disclose by choosing a target

Generic command targets receive transcript text through standard input. That
text is disclosed to the configured local process and inherits that process's
privacy and network behavior. Clipboard targets place text on the macOS system
pasteboard, where other applications may be able to read it. Codex, Claude Code,
and Hermes targets disclose the transcript to those agents and to whatever model
providers they are themselves configured to use.

## Input mode

Push-to-talk is the only input mode: Miri captures audio only while you
hold the configured shortcut. Wake word was removed with the Python worker, so
there is no always-listening path to audit.
