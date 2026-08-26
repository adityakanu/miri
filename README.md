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

<p align="center">
  <a href="https://github.com/FluidInference/FluidAudio">
    <img src="https://assets.inference.plus/fi-badge.png" alt="Powered by Fluid Inference" height="64">
  </a>
</p>

> [!CAUTION]
> Miri currently uses a free ad-hoc signature and requires a
> one-time macOS **Open Anyway** action. Use them only when downloaded from
> this repository’s GitHub Releases and verify the published checksum.

## Get Miri

### DMG — easiest install

Download `Miri-<version>.dmg` from
[GitHub Releases](https://github.com/adityakanu/miri/releases), then:

1. Open the DMG and drag **Miri.app** to Applications.
2. Open Miri once. macOS will block the unnotarized app.
3. Open **System Settings → Privacy & Security** and choose **Open Anyway**.
4. Launch Miri again, grant microphone access, and choose your shortcut.

The DMG drag-and-drop experience works without a paid Apple developer account;
the Gatekeeper confirmation is the trade-off. A checksum file accompanies every
release:

```sh
shasum -a 256 -c Miri-<version>.sha256
```

### Build from source

For contributors and developers:

```sh
git clone https://github.com/adityakanu/miri.git
cd miri
make bootstrap
swift run miri-app
```

Requires Apple Silicon, macOS 14+, Xcode, and Homebrew. Speech models download
after explicit consent on first use; no Python runtime or separate worker is
needed.

## How it works

| Speak | Route | Hear |
| --- | --- | --- |
| Hold your global shortcut and speak. | Miri snapshots the active, default, or dedicated-hotkey target. | Get concise, filtered spoken agent updates. |
| Release to transcribe locally. | Never guesses from the frontmost terminal. | Interrupt speech by starting a new recording. |

- **Local speech:** NVIDIA Parakeet TDT v3 transcription and PocketTTS speech
  synthesis run through FluidAudio/CoreML on the Apple Neural Engine, inside
  Miri's own process.
- **Optional cloud STT:** connect Groq, OpenAI, OpenRouter, a local server, or
  any OpenAI-compatible `/audio/transcriptions` endpoint from Settings.
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
4. In **Settings → Targets**, choose **Install or Repair Miri MCP**. Restart
   Codex after registration.
5. Hold `Option + Space`, speak, and release.
6. Watch the pill: listening → transcribing → sending → delivered.

When an agent asks a question, the next global-hotkey recording is pinned to
that same target and thread. For a Codex permission prompt, say exactly
`approve request` or `deny request`; vague phrases such as “yes” never approve.

Press `Escape` to cancel. Miri is half-duplex: starting a new recording stops
speech playback so it does not transcribe itself.

### Tell Miri to speak

Agents can request short status speech through the private local socket:

```sh
miri status "Which option should I use?" --kind question --priority 1
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

FluidAudio downloads the Parakeet and PocketTTS CoreML weights only after
first-run consent and stores them under Application Support. Model weights are
not embedded in the DMG. The application itself is about 22 MB.

## Privacy

Miri is local-first:

- No analytics and no local HTTP server.
- Audio stays on your Mac with the default Parakeet backend; cloud
  transcription is explicit and opt-in.
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
| In-process Parakeet STT and PocketTTS on CoreML/ANE | Implemented |
| Codex exact-thread targeting, speech, questions, and approvals | Implemented |
| Claude Code and Hermes live compatibility matrix | In validation |
| Signed/notarized DMG and official Homebrew Cask | Planned |
| Optional OpenAI-compatible cloud transcription | Implemented |

The formal gates are in [docs/release-checklist.md](docs/release-checklist.md).

## Documentation

- [Install and remove Miri](docs/installation.md)
- [Adapter setup](docs/adapters.md)
- [Architecture](docs/architecture.md)
- [IPC contract](docs/ipc.md)
- [Model and runtime licenses](docs/model-licenses.md)
- [Benchmark protocol](docs/benchmarks.md)
- [Competitive landscape](docs/competitive-landscape.md)

## Acknowledgments

Miri's local speech stack is powered by
[FluidAudio](https://github.com/FluidInference/FluidAudio), an Apache-2.0 Swift
framework from the FluidInference Team. Miri uses FluidAudio's CoreML model
management, Parakeet TDT v3 ASR, PocketTTS streaming synthesis, and Apple Neural
Engine execution. This is the foundation that lets Miri ship without Python
and keep microphone audio in-process and on-device.

Parakeet TDT v3 was created by NVIDIA and converted to CoreML by
FluidInference. PocketTTS was created by Kyutai and converted to CoreML by
FluidInference. Model downloads remain subject to their CC-BY-4.0 terms.

See [Third-party notices](THIRD-PARTY-NOTICES.md) and the
[model/runtime license inventory](docs/model-licenses.md) for complete source,
license, and attribution links.

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
