# Miri

**A local-first voice bridge for coding agents on macOS.**

Miri lets you hold a global shortcut, speak a prompt, and send the resulting
local transcript to an explicitly selected agent session. Agents can also send
short, filtered spoken status updates back through Miri.

Miri is built for people who work with multiple coding agents and want voice
input without losing control of where a message goes.

> [!WARNING]
> Miri is pre-release software. The development build is usable, but a
> notarized public DMG, pinned model manifest, hardware benchmark evidence, and
> full adapter compatibility matrix are still in progress. Read the
> [current limitations](#current-status) before depending on it for daily work.

## What it does

- Push-to-talk with a configurable global shortcut.
- A compact, non-activating notch-adjacent status pill that does not steal
  focus from your editor or terminal.
- Local speech-to-text and text-to-speech through replaceable providers.
- Explicit target routing: active target, default target, or per-target
  hotkeys. A recording snapshots its destination before you speak.
- Codex thread selection, Claude Code CLI support, Hermes session support,
  generic-command delivery, and a safe Clipboard fallback.
- Agent status speech through `miri status` or the `miri-mcp` MCP server.
- Memory-only failed-delivery outbox with retry, edit, copy, and discard.
- Optional experimental wake-word mode with a visible listening indicator.
- Local configuration, logs, models, and no local HTTP server.

## Quick start: development build

### Requirements

- Apple Silicon Mac
- macOS 14 Sonoma or later
- Xcode with Swift 6
- [Homebrew](https://brew.sh/)

Clone the repository from GitHub, then bootstrap the development environment:

```sh
git clone <your-github-repository-url> miri
cd miri
make bootstrap
make models-dev
make test
swift run Miri
```

Miri appears in the menu bar, not the Dock. On first launch, grant microphone
access and choose a shortcut. The default is `Option + Space`.

`make models-dev` installs the optional local inference runtimes. Model weights
must still be supplied through your configuration until the first
checksum-pinned release manifest is published; see [Speech models](#speech-models).

## Using Miri

1. Launch Miri with `swift run Miri`.
2. Open its menu-bar item and select a target.
3. Hold the configured shortcut, speak, then release it.
4. Miri transcribes locally and sends the finished transcript to the target
   snapshotted at recording start.
5. Watch the status pill for transcription, sending, delivery, queueing, or
   error feedback.

Press `Escape` while recording to cancel. Pressing the listening shortcut while
Miri is speaking stops speech and starts recording, keeping interaction
half-duplex.

### First target

A new configuration starts with a **Clipboard** target. It copies the transcript
to the macOS pasteboard and reports `Copied`; it never simulates keystrokes or
pastes into another app.

For Codex, open **Settings → Targets**, refresh recent threads, and add the
exact conversation you want to control. Miri stores the thread ID as a named
target; it never guesses from the frontmost window.

You can verify the configured Codex transport from a terminal:

```sh
swift run miri agents test-codex
```

More adapter details are in [docs/adapters.md](docs/adapters.md).

### Spoken agent status

With Miri running, an agent or shell script can request a short spoken update:

```sh
swift run miri status "Tests passed; checking the release bundle now." --priority question
```

`miri-mcp` exposes the same capability to MCP-compatible agents through the
`voice_status` tool. Statuses are capped, deduplicated, rate-limited, and
filtered for obvious secrets, code, logs, URLs, and private paths.

```sh
swift run miri-mcp
```

Use voice for concise progress, blockers, approvals, questions, warnings, and
completion notices—not full responses or source code.

## Configuration

Miri reads and writes TOML at:

```text
~/.config/miri/config.toml
```

Copy [config.example.toml](config.example.toml) as a starting point. Miri
validates the complete file, reports line-specific errors, and live-reloads
valid external edits.

Minimal example:

```toml
version = 1
default_target = "clipboard"
input_mode = "push_to_talk"

[hotkeys]
active_target = "option+space"

[[targets]]
id = "clipboard"
name = "Clipboard"
adapter = "clipboard"
```

Useful target types:

| Adapter | Use case | Required target fields |
| --- | --- | --- |
| `clipboard` | Safe fallback; copies text | `id`, `name` |
| `codex` | One exact Codex thread | `working_directory`, `session` |
| `claude-code` | Claude Code CLI session | `working_directory`, optional `session` |
| `hermes` | Hermes local API-server session | `endpoint`, `session` |
| `generic-command` | Launch a local executable; transcript goes to stdin | `endpoint` executable path |

Dedicated target shortcuts use the target's `hotkey` field. If a target is busy,
Miri keeps at most one queued voice message and follows that target's
`queue_replacement` policy (`reject`, `replace`, or `confirm`).

## Speech models

Miri's default production direction is:

- **STT:** Moonshine Small Streaming
- **TTS:** Pocket TTS
- **Endpointing:** Silero VAD
- **Wake word:** openWakeWord, experimental and off by default

The Swift app owns capture, playback, routing, permissions, and UI. A separate
Python worker owns inference behind a versioned framed IPC contract, so speech
providers can be replaced without rewriting the product.

For local development, configure model paths in `config.toml`, then restart
Miri. The full example includes Moonshine, Pocket TTS, VAD, and wake-word
settings. Model downloads in a stable release will require explicit consent and
will use pinned URLs, byte sizes, checksums, resumable downloads, and reviewed
licenses.

See [Worker/README.md](Worker/README.md) and
[docs/model-licenses.md](docs/model-licenses.md) for provider and licensing
notes.

## Privacy and data

Miri is local-first by design.

- Audio stays on the Mac.
- Miri has no analytics and opens no HTTP port.
- Transcript history is not persisted.
- Failed deliveries live only in an in-memory outbox and disappear on quit.
- Logs exclude raw audio and full transcripts by default.
- The control socket is private to the current user under `$TMPDIR/miri`.

Configuration is stored in `~/.config/miri`; models and app data are under
`~/Library/Application Support/Miri`; logs are under `~/Library/Logs/Miri`.
Settings includes actions to delete downloaded models or reset all local Miri
data.

Clipboard and generic-command targets deliberately disclose the transcript to
the selected local application or process. Review the privacy posture of any
target you configure.

Read the full [privacy and security notes](docs/privacy.md).

## Installation from GitHub Releases

No stable DMG has been published yet. When releases are available, GitHub
Releases will be the canonical install location:

1. Download `Miri-<version>.dmg` and its matching `.sha256` file from the same
   GitHub Release.
2. Verify the checksum:

   ```sh
   shasum -a 256 -c Miri-<version>.sha256
   ```

3. Open the DMG and move `Miri.app` to Applications.
4. Launch Miri and complete first-run setup.

The release DMG will be signed and notarized. It will bundle its own Python
worker; end users will not need Python, `uv`, Xcode, or Homebrew.

A Homebrew Cask will install the exact same DMG and checksum after the first
notarized release is published.

## Development

Common commands:

```sh
make bootstrap       # install XcodeGen/uv if needed and sync Python tooling
make models-dev      # install optional local inference runtimes
make test            # Swift and Python tests
make generate        # regenerate the Xcode project with XcodeGen
swift run Miri       # run the menu-bar app
swift run miri status "Miri is ready"
```

Run test suites independently:

```sh
swift test
uv run --project Worker --no-sync pytest
```

The performance harness writes only timing metadata to
`~/Library/Logs/Miri/performance.jsonl`. See
[docs/benchmarks.md](docs/benchmarks.md) for the M1/M4 benchmark protocol.

## Architecture

```text
Swift macOS app
  ├─ menu bar, settings, hotkeys, notch overlay
  ├─ microphone capture and speaker playback
  ├─ target router and agent adapters
  └─ private control socket
             │ versioned local IPC
             ▼
Python speech worker
  ├─ STT / TTS / VAD / wake-word providers
  ├─ model lifecycle and health
  └─ streamed transcript and PCM events
```

Read [docs/architecture.md](docs/architecture.md) and
[docs/ipc.md](docs/ipc.md) for the contracts.

## Current status

Implemented and tested in the repository:

- Native menu-bar interaction, status overlay, push-to-talk, cancellation, and
  half-duplex playback.
- TOML validation, live reload, target snapshotting, queues, and in-memory
  outbox handling.
- Codex, Claude Code, Hermes, generic command, and Clipboard adapter paths.
- Local control socket, CLI, and MCP status speech interface.
- Python provider contracts, worker recovery, model-management protocol, and
  wake-word/VAD protocol paths.

Before a stable public release, the project still needs:

- A checked-in, reviewed, checksum-pinned production model manifest.
- Real-device benchmark evidence on M4 and M1 hardware.
- Live compatibility validation for Claude Code and Hermes installations.
- Clean-machine DMG, signing, notarization, and Homebrew Cask validation.

The [release checklist](docs/release-checklist.md) is the source of truth for
release gates.

## Contributing

Contributions are welcome. Before opening a pull request:

1. Keep changes local-first and avoid adding telemetry or network services.
2. Preserve the agent-neutral contracts in `MiriCore`.
3. Add or update Swift and Python tests for behavioral changes.
4. Run `make test`.
5. Update documentation when setup, configuration, protocol, privacy, or
   release behavior changes.

Please use GitHub Issues for reproducible bugs and feature proposals. Do not
include secrets, private transcripts, raw audio, or personal data in issues or
logs.

## License

Miri is licensed under the [Apache License 2.0](LICENSE).
