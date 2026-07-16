# Agent adapter setup

Adapters implement the neutral `AgentAdapter` interface. Delivery is successful
only after the adapter returns a receipt, and the target is snapshotted when
recording begins so focus changes cannot silently redirect a transcript.

## Available implementation status

- Clipboard is the simplest fallback and copies the transcript to the system
  pasteboard.
- Generic command starts an executable directly and writes the transcript to
  standard input. Miri does not interpolate transcripts into shell commands.
- Codex uses the installed app-server JSON-RPC protocol with explicit thread
  IDs; the managed CLI command remains a compatibility fallback. The current
  development implementation is verified against Codex CLI 0.144.5.
- Claude Code uses its documented print-mode `stream-json` CLI transport and
  extracts the final assistant result. Live CLI/version compatibility still
  requires release-matrix testing.
- Hermes uses the official local API server's addressable
  `/api/sessions/{id}/chat/stream` SSE operation. Configure an HTTP base URL,
  exact session ID, and `HERMES_API_SERVER_KEY` when the server requires it.
  Live compatibility still requires release-matrix testing.

The target schema is documented in `scope.md`. Miri creates a safe Clipboard
target on a new installation and live-reloads target edits from
`~/.config/miri/config.toml`. Settings lists recent interactive Codex threads
through `thread/list`; adding one creates a named target bound to its exact
thread ID and makes it the default. Frontmost Codex window never changes voice
routing. Clipboard and generic-command fallback remain part of the design.

Final agent answers are spoken automatically by default. Markdown code, links,
URLs, and private paths are removed before speech. Long answers are shortened at
a sentence boundary while full text stays available in Miri's memory-only
response viewer. Configure behavior under `[tts]`:

```toml
speak_agent_responses = true
agent_response_max_characters = 180
```

Agent status speech is exposed through either command after Miri is running:

```sh
miri status "Tests passed" --priority 1
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' | miri-mcp
```

Both commands forward to the private local control socket. Miri opens no local
HTTP port.

## Interactive Codex loop

In **Settings → Targets**, click **Install or Repair Miri MCP** and restart
Codex. Miri registers the bundled stdio helper through `codex mcp add`; it does
not edit the TOML itself and opens no network listener.

`voice_status` accepts `kind = progress | completion | question | blocker |
warning`. Questions carry the MCP process working directory. Miri resolves it
to a configured target, selects that exact thread, and routes the next global
hotkey transcript back there. Final Codex responses ending in a question mark
receive the same treatment even when the MCP tool was not called.

Miri-managed Codex app-server approval callbacks remain inside the adapter.
Miri speaks a command/file/permission summary without reading command contents
aloud. Voice approval accepts only `approve request` or `Miri approve request`;
voice denial accepts `deny request`, `decline request`, or their Miri-prefixed
form. Any other transcript leaves the request pending. Disconnecting defaults
all unresolved callbacks to decline.

Codex app-server is experimental. Voice prompts are persisted in the exact
configured thread, but an already-open Codex desktop view may need to be
reopened to refresh changes written by Miri's separate protocol client.
