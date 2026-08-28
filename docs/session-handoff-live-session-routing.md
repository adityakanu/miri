# Miri session handoff — live session routing

Branch: `fix/live-session-routing`, cut from `feature/release-readiness-agent-hud`.

## The problem

Miri had **three independent session concepts** that never exchanged data:

| Source | Refreshed | Consumed by |
|---|---|---|
| `liveSessions` (`LiveSessionScanner`, process table) | every 4 s | menu bar only |
| `discoveredSessions` (`refreshAllSessions`, transcripts/RPC/REST) | manual button only | Settings only |
| `sessionPresence` (`noteAgentActivity`) | on agent event/delivery | `ContextResolver` only |

The scanner is the one component that knows what is genuinely running, and its
output reached exactly one menu section. `ContextResolver` — the component that
decides where an utterance goes — never saw it. The result was a picker that
looked live but routed off stale, partial information.

## What changed

### Explicit selection now wins (the headline bug)

`AppController` passed the user's chosen target to `ContextResolver` as
`pinnedDefault` — its **lowest**-priority rule — and never populated
`explicitTarget`. Any agent with a pending question outranked a deliberate pick,
so the utterance silently went somewhere the user had not selected.

`activeTargetWasChosenByUser` now distinguishes a deliberate pick from a value
inherited from configuration or claimed by an agent. Only a real choice is
passed as `explicitTarget`. Every selection path sets or clears it:
`selectTarget` and session adoption set it; config reload, an agent claiming the
selection for a question, and target removal clear it.

Settings binds through `activeTargetSelection` rather than `$activeTargetID`, so
picking there records the choice exactly as the menu bar does instead of writing
a raw ID that routing cannot interpret.

Covered by `testAChosenTargetBeatsAWaitingRequestAndTheConfiguredDefault`, with
`testPassingAChoiceAsThePinnedDefaultLosesToAPendingRequest` pinning the old
behaviour so the regression cannot return quietly.

### The foreground rule now exists

`ContextResolver.foregroundTargetIDs` was accepted but never supplied by any
caller, so the `.foregroundContext` branch was unreachable dead code.

`ProcessAncestry` (new) answers it exactly rather than by heuristic: if Terminal
is frontmost and `codex` was launched from one of its tabs, that process is a
descendant of Terminal. Window titles and working-directory string matching
guess; ancestry does not. The walk is child → parent, so it is O(depth) and a
cycle in a malformed map terminates via the visited set.

### The scanner's data reaches routing

`noteLiveSessions` records presence for every running agent process, so a
session the user has never spoken to is still visible to the resolver. It
deliberately does **not** touch `lastUserInteractionAt` — being alive is not the
same as having been spoken to, and only the latter should win the recency rule.

Presence for a session whose process has exited is expired immediately rather
than lingering for the remaining 15-minute window. This is gated on
`LiveSessionScanner.canDetectLiveness`: Hermes runs one process for all its
conversations, so its absence from a scan means nothing and must never be read
as "not running".

### Settings shows what is actually running

`SessionCatalog` (new, pure) merges live and discovered sessions, running ones
first. Settings previously read raw `discoveredSessions`, which for Claude Code
is ranked by transcript **mtime** — the exact heuristic the scanner's own doc
comment says cannot tell a finished conversation from a running one. A live
session discovery has not indexed yet is still listed, since a conversation
started seconds ago is the one you most likely want.

Truncation now states `Showing 12 of N` instead of silently cutting the list,
and the sidebar badge shows `running/total`.

### Codex writer conflicts are explained, not suffered

A live Codex session is live *because* a Codex process holds its thread-store
writer, so `thread/resume` on it always loses. The code worked around the error
by deferring connection, which only moved the failure to the first utterance.

`CodexAppServerError.threadBusyElsewhere` classifies the writer error into one
actionable sentence, and Settings warns on the row **before** the user speaks.
Classification matches on the server's message and falls back to the generic
error, so a wording change downgrades this rather than hiding a real failure.

### Smaller fixes

- **Disabled targets were a silent trap.** `TargetRegistry.target(id:)` returns
  `nil` for a disabled target, so selecting one fell through to the configured
  default without saying so. They are no longer selectable, say why, and offer
  an Enable button (`setTargetEnabled`) instead of requiring a config.toml edit.
- **Per-agent panes, one global selection.** `activeTargetID` is global while
  the panes are per-agent, so a pane now states plainly when the active target
  belongs to a different agent instead of showing "Use configured default" as
  though nothing were selected anywhere.
- **Scanner dedup was arbitrary.** A supervisor and its child both hold the
  transcript open, and `proc_listpids` order is not meaningful, so the retained
  process — and its working directory, which is the session's label — was
  arbitrary. `preferred(_:_:)` resolves it: a known directory beats an unknown
  one, then the higher PID (the child actually running the conversation).
- **Hermes discovery was circular.** The endpoint came only from an existing
  Hermes target, but a target is what you build *from* discovery. A `[hermes]
  endpoint` setting is now honoured first, allowlisted in the parser, and
  documented in `config.example.toml`.
- **"Add" became "Speak to This".** Adding a target and then selecting it
  separately was two steps for one intent; `selectCatalogedSession` adopts and
  selects in one click.
- `TargetSummaryRow` no longer draws an always-empty radio circle — that was the
  same decorative-selector mistake this pane set out to remove.

## Verification

New pure types were built and run on Swift 6.0.3 (Linux, in isolation from the
macOS-only targets): **36 tests, 0 failures.**

Following this repo's standard, every fix was verified by reverting it and
watching a *named* test fail, not by trusting a green suite:

| Reverted | Failing test |
|---|---|
| liveness ranking | `testARunningSessionOutranksAMoreRecentlyModifiedDeadOne` |
| foreground resolution | `testAgentLaunchedFromTheFrontmostTerminalIsForeground` |
| writer-conflict classification | `testAWriterConflictBecomesAnActionableError` |
| scanner dedup preference | `testTheChildProcessWinsWhenBothKnowTheirDirectory` |
| `[hermes]` allowlist entry | `testAHermesEndpointSectionParsesCleanly` |

All touched files pass `swiftc -parse`.

## Not verified — do this before merging

The development machine is Linux, so the macOS-only targets could not be built
here. **`MiriApp` and the AppKit/CoreML halves of `MiriCore` have not been
compiled.** On a Mac, run first:

```sh
swift build
swift test
```

Then the behaviour that no test can cover:

1. Select a Codex target in Settings while a *different* agent has a question
   pending, then speak. The utterance must reach the target you picked. This is
   the headline bug and it needs a real hardware check.
2. With Terminal frontmost running `codex`, and no explicit selection, confirm
   the foreground rule routes there — check `routing target=… reason=foreground_context`
   in the log.
3. Confirm a running session appears at the top of its Settings pane marked
   "Running now", and that the count badge shows `running/total`.
4. Pick a running Codex session and confirm the writer warning appears before
   speaking, and that the spoken failure is the actionable sentence rather than
   the raw RPC error.
5. Quit an agent and confirm its presence expires promptly rather than staying
   routable, and that a Hermes target is *not* expired by the same sweep.

## Known gaps left deliberately

- **Hermes still has no liveness signal.** It runs one process for every
  conversation, so the scanner cannot see it. Only the discovery chicken-and-egg
  was fixed; a session running in Hermes cannot be distinguished from a stale one.
- **Foreground detection needs the agent to be a descendant of the frontmost
  app.** An agent in a detached tmux/screen session, or one whose parent exited,
  will not match. That is a correct miss rather than a wrong guess: it falls
  through to the next rule.
- `processParents` is refreshed on the 4 s scan tick, so a just-launched agent
  can miss the foreground rule for up to one tick.
