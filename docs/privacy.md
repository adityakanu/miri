# Privacy and security

Miri defaults to local audio processing after explicit model download. It
does not expose an HTTP server, enable analytics, or persist transcript history.
The private control socket is created below `$TMPDIR/miri` for the current user.

## Transcription backends

- **Parakeet (recommended).** NVIDIA Parakeet TDT runs on the Apple Neural
  Engine inside Miri's own process. Audio never crosses a process boundary and
  never reaches the network. The CoreML bundles are downloaded once from
  Hugging Face after you approve it; `ModelHub.offlineMode` blocks every network
  fetch when you have not consented.
- **Moonshine.** The embedded-Python worker path. Also fully local.
- **Cloud.** Opt-in; see below.

## Cloud transcription is opt-in and off by default

The optional `stt.provider = "cloud"` setting sends recorded utterance audio to
a third-party OpenAI-compatible endpoint (Groq by default). When it is enabled,
Miri is no longer local-only:

- each utterance is uploaded as a 16 kHz mono WAV over TLS;
- the audio is subject to the chosen provider's retention and terms, not Miri's;
- transcription fails when the machine is offline, unlike the local providers.

The API key is stored in the macOS Keychain (service `dev.miri.speech`), entered
through **Settings → Speech**. Miri forwards it only to the worker child process
and never writes it to `config.toml`, which stores just the endpoint and model.
An exported `GROQ_API_KEY` still works as a fallback, but note that apps launched
from Finder do not inherit your shell environment, so the Keychain is the
reliable path. Choose the on-device provider for fully offline operation.

Expected data locations are:

- configuration: `~/.config/miri/config.toml`;
- models/application data: `~/Library/Application Support/Miri`;
- caches: `~/Library/Caches/Miri`;
- logs: `~/Library/Logs/Miri`.

Audio buffers are intended to be discarded after transcription. Failed
transcripts are held only in the in-memory outbox and disappear on quit. Normal
logs must not contain raw audio or complete transcripts. Agent speech passes
through length, repetition, code, and obvious-secret filters, but those filters
are defense in depth rather than a guarantee that arbitrary text is safe to say
aloud.

Generic command targets receive transcript text through standard input. That
text is disclosed to the configured local process and inherits that process's
privacy and network behavior. Clipboard targets place text on the macOS system
pasteboard, where other applications may be able to read it.

Model download is the exception to offline operation and requires explicit
consent. Moonshine artifacts use Miri's URL, byte-size, and SHA-256 manifest.
Pocket TTS 2.1.0 resolves model files from revision-pinned upstream
configuration after the same consent; its selected voice may carry separate
terms. Wake-word mode is experimental, uses only a user-supplied local model,
and must always show a visible listening indicator.
