# Privacy and security

Miri is designed for local audio processing after explicit model download. It
does not expose an HTTP server, enable analytics, or persist transcript history.
The private control socket is created below `$TMPDIR/miri` for the current user.

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
