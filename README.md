# Miri

<p align="center">
  <strong>Speak to your coding agents. Keep control of the destination.</strong>
</p>

<p align="center">
  <a href="https://github.com/adityakanu/miri/actions/workflows/ci.yml"><img src="https://github.com/adityakanu/miri/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/adityakanu/miri/releases"><img src="https://img.shields.io/github/v/release/adityakanu/miri?display_name=tag&sort=semver" alt="Latest release"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/adityakanu/miri" alt="Apache-2.0 license"></a>
  <a href="https://github.com/adityakanu/miri/stargazers"><img src="https://img.shields.io/github/stars/adityakanu/miri?style=flat" alt="GitHub stars"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black?logo=apple" alt="macOS 14 or later">
  <img src="https://img.shields.io/badge/Apple%20Silicon-only-000000" alt="Apple Silicon only">
</p>

<p align="center">
  <img src="assets/miri-demo.gif" alt="Miri voice capture, target routing, and status-pill demo" width="760">
</p>

Miri is a local-first macOS voice bridge for coding agents. Hold a shortcut,
speak a prompt, and Miri routes the local transcript to the exact agent session
you selected. Agents can send short spoken progress, blocker, approval, and
completion updates back through Miri.

> [!CAUTION]
> Miri is early-access software. Preview downloads are unsigned and require a
> one-time macOS **Open Anyway** action. Use them only when downloaded from
> this repository’s GitHub Releases and verify the published checksum.

## Get Miri

### Preview DMG — easiest install

Once a preview release is published, download `Miri-<version>-preview.dmg` from
[GitHub Releases](https://github.com/adityakanu/miri/releases), then:

1. Open the DMG and drag **Miri.app** to Applications.
2. Open Miri once. macOS will block the unsigned preview.
3. Open **System Settings → Privacy & Security** and choose **Open Anyway**.
4. Launch Miri again, grant microphone access, and choose your shortcut.

The DMG drag-and-drop experience works without a paid Apple developer account;
the Gatekeeper confirmation is the trade-off. A checksum file accompanies every
release:

```sh
shasum -a 256 -c Miri-<version>-preview.sha256
```

### Build from source

For contributors and developers:

```sh
git clone https://github.com/adityakanu/miri.git
cd miri
make bootstrap
make models-dev
swift run Miri
```

Requires Apple Silicon, macOS 14+, Xcode, Homebrew, and `uv`.

## How it works

| Speak | Route | Hear |
| --- | --- | --- |
| Hold your global shortcut and speak. | Miri snapshots the active, default, or dedicated-hotkey target. | Get concise, filtered spoken agent updates. |
| Release to transcribe locally. | Never guesses from the frontmost terminal. | Interrupt speech by starting a new recording. |

- **Local speech:** Moonshine Streaming, Pocket TTS, Silero VAD, and optional
  experimental openWakeWord run behind replaceable provider interfaces.
- **Explicit agents:** Codex, Claude Code, Hermes, generic local commands, and
  a safe Clipboard fallback.
- **No focus stealing:** a compact notch-adjacent status pill stays out of your
  editor and terminal.
- **Recoverable delivery:** one-item target queues plus a memory-only outbox
  for retry, edit, copy, or discard.

## First use

1. Launch Miri from the menu bar.
2. Grant microphone permission when asked.
3. Select **Clipboard** for a safe first test, or add an exact Codex thread in
   **Settings → Targets**.
4. Hold `Option + Space`, speak, and release.
5. Watch the pill: listening → transcribing → sending → delivered.

Press `Escape` to cancel. Miri is half-duplex: starting a new recording stops
speech playback so it does not transcribe itself.

### Tell Miri to speak

Agents can request short status speech through the private local socket:

```sh
miri status "Tests passed; checking the package now." --priority question
```

Or use `miri-mcp` and its `voice_status` MCP tool. Miri applies length limits,
deduplication, rate limits, priority handling, and filters for obvious secrets,
logs, code, URLs, and private paths.

## Configure targets and speech

Configuration lives at `~/.config/miri/config.toml` and live-reloads after
valid edits. Start with [config.example.toml](config.example.toml).

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

| Target | What Miri needs |
| --- | --- |
| Clipboard | Nothing else — copies the transcript safely. |
| Codex | Working directory and exact thread ID. |
| Claude Code | Working directory and optional session ID. |
| Hermes | Local API-server URL and exact session ID. |
| Generic command | Local executable path; transcript goes to stdin. |

The initial production model direction is Moonshine Small Streaming for speech
recognition and Pocket TTS for speech. Preview users may need to configure local
model paths while the pinned download manifest is being finalized.

## Privacy

Miri is local-first:

- No analytics and no local HTTP server.
- Audio stays on your Mac.
- No persistent transcript history.
- Failed deliveries stay only in memory and disappear when Miri quits.
- Logs omit raw audio and full transcripts by default.

Read [privacy details](docs/privacy.md) before connecting third-party local
agent processes. Clipboard and generic-command targets disclose the transcript
to the process you explicitly choose.

## Project status

| Area | Status |
| --- | --- |
| Menu-bar app, hotkeys, overlay, routing, outbox | Implemented |
| Local worker, streamed STT/TTS contract, VAD/wake-word paths | Implemented |
| Codex thread targeting and agent speech | Implemented |
| Claude Code and Hermes live compatibility matrix | In validation |
| Signed/notarized DMG and official Homebrew Cask | Planned |
| Pinned production model manifest and M1/M4 evidence | In progress |

The formal gates are in [docs/release-checklist.md](docs/release-checklist.md).

## Documentation

- [Install and remove Miri](docs/installation.md)
- [Adapter setup](docs/adapters.md)
- [Architecture](docs/architecture.md)
- [IPC contract](docs/ipc.md)
- [Model and runtime licenses](docs/model-licenses.md)
- [Benchmark protocol](docs/benchmarks.md)

## Contributing

Issues and pull requests are welcome. Keep changes local-first, preserve the
agent-neutral contracts, add tests, and run:

```sh
make test
```

Please never include secrets, raw audio, or private transcripts in GitHub
issues, pull requests, or logs.

## License

Licensed under the [Apache License 2.0](LICENSE).
