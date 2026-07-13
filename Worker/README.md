# Miri speech worker

The worker is an isolated Python process behind Miri IPC v1. Swift remains the
owner of capture, playback, UI, routing, and product policy. This package owns
speech inference lifecycle only.

The default `ReferenceSTTProvider` and `ReferenceTTSProvider` are deterministic
contract implementations. They make native integration, cancellation, crash
recovery, and protocol tests possible without downloading model weights. They do
not perform speech inference. Optional, lazily imported production adapters are
provided for Moonshine Small Streaming, Pocket TTS, Silero VAD, and the
experimental openWakeWord integration.

Install only the runtimes needed for development, for example:

```sh
uv sync --extra dev --extra moonshine --extra pocket-tts
```

Provider selection is environment-driven at the worker boundary. The defaults
remain the lightweight reference providers. Set `MIRI_STT_PROVIDER=moonshine`,
`MIRI_TTS_PROVIDER=pocket-tts`, `MIRI_VAD_PROVIDER=silero`, and/or
`MIRI_WAKE_WORD_PROVIDER=openwakeword`. Provider options use the
`MIRI_PROVIDER_` prefix; relevant names are documented by `ProviderConfig` and
include `MOONSHINE_MODEL_PATH`, `MOONSHINE_MODEL_ARCH`,
`POCKET_TTS_CONFIG_PATH`, `POCKET_TTS_VOICE`, and
`OPENWAKEWORD_MODEL_PATHS` (colon-separated on macOS).

The adapters never invoke an upstream model downloader unless
`MIRI_PROVIDER_ALLOW_MODEL_DOWNLOADS=true` has been set after explicit user
consent. The checked-in model manifest is deliberately a non-installable
template: release engineering must add real byte sizes and independently
verified SHA-256 checksums before managed downloads can be enabled.

Supported requests are `hello`, `health`, `audio.start`, `audio.chunk`,
`audio.stop`, `speech.start`, `speech.stop`, and `cancel`. Every response or event
retains its originating request ID and relevant session ID. Transcription emits
`transcript.partial` and `transcript.final`; synthesis emits raw 24 kHz mono
float32 `speech.chunk` frames followed by `speech.stop`.

Run the worker and tests with:

```sh
uv run miri-worker
uv run --extra dev pytest
```

`ModelManager` accepts a versioned manifest containing an exact byte size and
SHA-256 for every artifact. Downloads use `.partial` files, resume with HTTP
Range, are fsynced, and become visible atomically only after verification. A
local override is subject to the same size/checksum verification and is never
deleted by the manager.

Lifecycle profiles are:

- `responsive`: STT and TTS remain warm.
- `balanced`: STT remains warm and TTS may unload after five idle minutes.
- `eco`: both providers load on demand and may unload after 30 idle seconds.
