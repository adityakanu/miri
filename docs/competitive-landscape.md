# Competitive landscape

Research snapshot: 2026-07-16. This is product planning, not a claim that the
listed products share Miri's agent-session architecture.

| Product | Officially documented strengths | What Miri should learn |
| --- | --- | --- |
| [Superwhisper](https://superwhisper.com/docs/get-started/introduction) | Local/cloud models, custom processing modes, context awareness, file transcription, 100+ languages, guided onboarding | Add configurable prompt-cleanup modes and stronger onboarding after agent reliability ships |
| [Wispr Flow](https://wisprflow.ai/features) | Cross-app insertion, corrections/backtracking, filler removal, formatting, dictionary, snippets, app-specific styles, developer syntax/file awareness | Highest-value later work: vocabulary, corrections, snippets, developer-term bias |
| [Aqua Voice](https://aquavoice.com/info/faq) | Hotkey insertion in editors/terminals, destination-aware formatting, filler cleanup, grammar repair, multilingual auto-detection | Explore optional local transcript cleanup while preserving raw-mode privacy |
| [VoiceInk](https://tryvoiceink.com/docs/introduction) | Native macOS UI, local or optional cloud models, per-app modes, privacy-first positioning | Maintain local defaults; add per-target speech profiles rather than generic per-app guessing |

## Miri's current wedge

The market is strong at dictation. Miri 0.1.4 therefore focuses elsewhere:

- an explicit, snapshotted agent target and exact conversation/session;
- bidirectional STT and TTS rather than text insertion alone;
- target-bound questions and same-hotkey replies;
- direct Codex approval callbacks with fail-closed disconnect behavior;
- neutral adapters for Codex, Claude Code, Hermes, generic commands, and
  Clipboard;
- local inference, memory-only failure recovery, and no HTTP listener.

## Later backlog, not 0.1.4 release scope

1. Custom vocabulary and developer-term bias.
2. Spoken correction/backtracking before delivery.
3. Reusable prompt snippets.
4. Optional local cleanup/formatting modes.
5. Per-target language and speech-model profiles.
6. Live partial transcript UI and direct text-field insertion.
