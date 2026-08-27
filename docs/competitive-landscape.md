# Competitive landscape

Research snapshot: 2026-07-16. This is product planning, not a claim that the
listed products share Miri's agent-session architecture.

| Product | Officially documented strengths | What Miri should learn |
| --- | --- | --- |
| [VoiceMode](https://github.com/mbailey/voicemode) | Open-source two-way Claude Code conversation, cross-platform support, silence detection, local Whisper/Kokoro or cloud fallback | Match its easy conversational setup and provider flexibility; retain Miri's exact-session routing and native macOS safety UI |
| [Paseo](https://paseo.sh/docs/providers) | Desktop/mobile/CLI agent orchestration, many native and ACP providers, remote access, worktrees, diffs, streaming, and notifications | This is the broadest agent product: Miri needs multi-session overview, richer adapter validation, and eventually remote/mobile continuity |
| [Superwhisper](https://superwhisper.com/docs/get-started/introduction) | Local/cloud models, custom processing modes, context awareness, file transcription, 100+ languages, guided onboarding | Add configurable prompt-cleanup modes and stronger onboarding after agent reliability ships |
| [Wispr Flow](https://wisprflow.ai/features) | Cross-app insertion, corrections/backtracking, filler removal, formatting, dictionary, snippets, app-specific styles, developer syntax/file awareness | Highest-value later work: vocabulary, corrections, snippets, developer-term bias |
| [Aqua Voice](https://aquavoice.com/info/faq) | Hotkey insertion in editors/terminals, destination-aware formatting, filler cleanup, grammar repair, multilingual auto-detection | Explore optional local transcript cleanup while preserving raw-mode privacy |
| [VoiceInk](https://tryvoiceink.com/docs/introduction) | Native macOS UI, local or optional cloud models, per-app modes, privacy-first positioning | Maintain local defaults; add per-target speech profiles rather than generic per-app guessing |

## Wispr Flow in detail

Checked 2026-08-26. Wispr Flow is the closest thing to a category leader in
dictation and the most common answer to "why not just use an existing tool?",
so it deserves a direct comparison rather than one table row.

**What it does better than Miri, honestly:**

- Dictation quality is its entire product, and it shows: filler removal
  ("um", "the the"), self-correction handling ("Friday — no, Monday"),
  punctuation, and tone-appropriate formatting per destination app.
- It types wherever the cursor is, so it works in every application with no
  configuration. Miri requires an explicitly configured target.
- 100+ languages; Miri is English-first.
- Mac, Windows, iPhone, and Android. Miri is macOS only.
- Custom dictionary, snippets, and per-app styles — all on Miri's backlog.
- $81M raised, SOC 2 Type II / ISO 27001 / HIPAA certifications, and a real
  free tier (2,000 words per week).

**The architectural difference:**

Wispr Flow is cloud-only. It has no offline mode on any platform: audio is
captured locally, sent to remote servers for transcription *and* for the LLM
reformatting that produces its polished output. That reformatting is precisely
why it cannot run locally — the cleanup quality depends on server-side models.
Without a connection it transcribes nothing.

Miri runs both directions of the loop on-device: Parakeet transcription on the
Apple Neural Engine, PocketTTS speech output on the GPU, both in-process. No
audio leaves
the machine and none of it crosses a process boundary. It works on a plane, on
a locked-down network, or under a policy that forbids sending source-adjacent
speech to third parties. The whole application is about 56 MB.

**Why someone would choose Miri instead:**

1. **Different job.** Wispr Flow inserts text at the cursor; it is a better
   keyboard. Miri delivers a transcript to a *snapshotted agent session* and
   speaks the agent's reply back. Dictating into Codex's input box is not the
   same as an agent asking a question aloud and receiving a spoken approval
   routed to the exact thread that asked.
2. **Offline and private by construction**, not by policy. The distinction
   matters where audio may discuss unreleased or regulated work.
3. **Bidirectional.** Wispr Flow has no audio output path. Miri's loop closes:
   agent speaks, user answers, answer returns to the originating session.
4. **Voice approval.** A Codex approval request can be accepted by an explicit
   spoken phrase and is declined on disconnect. No dictation product models
   agent approvals at all.
5. **No subscription.** $15/month, or $144/year, versus a free local tool.
6. **Agent-neutral and open.** Adapters for Codex, Claude Code, Hermes, generic
   commands, and Clipboard, with the contracts in the open.

**Where Miri genuinely loses:**

A user who wants to dictate email and Slack messages in five languages across
Mac and iPhone should use Wispr Flow. Miri is not a general dictation tool, it
does not clean up filler or self-corrections, and it does not type at the
cursor. These are different products that share an input device.

The honest positioning is *complementary*: Wispr Flow for prose everywhere,
Miri for talking to coding agents. Miri should not claim to beat it at
dictation, and should not chase 100+ languages or per-app formatting before the
agent loop is fully validated.

## Miri's current wedge

The market is strong at dictation. Miri 0.1.4 therefore focuses elsewhere:

- an explicit, snapshotted agent target and exact conversation/session;
- bidirectional STT and TTS rather than text insertion alone;
- target-bound questions and same-hotkey replies;
- direct Codex approval callbacks with fail-closed disconnect behavior;
- neutral adapters for Codex, Claude Code, Hermes, generic commands, and
  Clipboard;
- local inference, memory-only failure recovery, and no HTTP listener.

Unlike general dictation products, Miri does not infer the destination from
keyboard focus. Unlike a voice tool owned by one agent, its core contracts are
agent-neutral. Its strongest current differentiator is the closed interaction
loop: an agent can speak a filtered question through MCP, the next hotkey reply
returns to the exact snapshotted session, and a Codex approval callback can be
accepted only by an explicit phrase and is declined on disconnect.

## Where 0.1.4 is behind

- No mobile, web, remote relay, worktree, diff, or multi-agent dashboard like
  Paseo.
- Codex is the only fully live-validated interactive adapter; Claude Code and
  Hermes still need the same release-matrix depth.
- English-first speech, no 100+ language catalog, custom vocabulary, snippets,
  spoken correction/backtracking, file transcription, or per-app formatting.
- No optional cloud model fallback or broad model picker.
- Wake word remains experimental; push-to-talk is the release path.
- Free community builds are not notarized and need Gatekeeper Open Anyway.
- Smaller accessibility, device, and clean-machine compatibility matrix than
  mature commercial products.

## Later backlog, not 0.1.4 release scope

1. Custom vocabulary and developer-term bias.
2. Spoken correction/backtracking before delivery.
3. Reusable prompt snippets.
4. Optional local cleanup/formatting modes.
5. Per-target language and speech-model profiles.
6. Live partial transcript UI and direct text-field insertion.
