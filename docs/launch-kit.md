# Miri launch kit

A reference brief for any agent (or human) producing launch materials for
Miri: blog post, Product Hunt listing, X/Twitter thread, launch video script,
Show HN post, Reddit post, etc. It exists so five different agents working in
parallel produce consistent, accurate, non-embarrassing copy without each one
re-deriving facts from the codebase or inventing claims.

**Read this whole file before writing anything.** Section 1 is a hard gate —
do not skip to the channel briefs.

---

## 1. Go/no-go — check this before writing a word

Miri is **not cleared to launch yet**. `AGENTS.md` at the repo root is the
live source of truth for release status; this section is a snapshot and will
go stale. Re-read `AGENTS.md`'s "Remaining 0.1.4 release work" section before
publishing anything, and do not draft copy that assumes blockers are closed
until the person running this kit confirms they are.

As of this writing, the following are **not yet done** and must not be
implied as done in any launch material:

- Real-hardware acceptance test (install from DMG, 5x consecutive voice loop,
  rapid hotkey re-entry, no crash report) — not yet run.
- 30-sample human benchmark evidence for overlay response and final
  transcript — not collected. Do not quote latency numbers beyond the ones
  marked "verified" in Section 4.
- Fresh-machine (no Xcode) install test — not yet run.
- Microphone permission denial/recovery, Bluetooth, accessibility
  (VoiceOver, Reduce Motion) testing — not yet run.
- License/SBOM review — not yet done.
- Signed, tagged `v0.1.4` release — does not exist yet. Only pre-release
  (`-rcN`) DMGs exist as of this writing.

**Do not draft materials that reference a specific ship date, a live GitHub
Release URL, or "available now" until the person directing this work confirms
gates are closed and a real tag exists.** It is fine to draft copy now with
placeholders (`[RELEASE_URL]`, `[LAUNCH_DATE]`) — that is the intended use of
this kit — but flag those placeholders explicitly in your output rather than
inventing values.

---

## 2. The one-line, one-paragraph, one-page pitch

Use these verbatim or lightly adapted. Do not rewrite the core claims — they
are calibrated to be defensible (see Section 5 for what NOT to claim).

**One line (tagline):**
> Speak to your coding agents. Keep control of the destination.

**Alt taglines** (pick per channel, do not mix metaphors within one piece):
- "A local voice bridge for coding agents."
- "Hold a key, talk to your agent, hear it talk back — nothing leaves your Mac."
- "Push-to-talk for Codex, Claude Code, and Hermes. Fully offline."

**One paragraph:**
> Miri is a local-first macOS menu-bar app that lets you talk to your coding
> agents. Hold a global hotkey, speak a prompt, and Miri routes the transcript
> to the exact agent session you picked — not whatever terminal happens to be
> frontmost. Agents can talk back too: short spoken progress updates,
> questions, and approval requests, routed to the same session that asked.
> Speech recognition and synthesis both run on-device via Apple Neural Engine
> and CoreML — no audio ever leaves the Mac, no cloud dependency, no
> subscription.

**One page (elevator pitch with substance, for blog intros / video scripts):**
> Coding agents like Codex increasingly work autonomously for stretches, then
> stop to ask a question or request approval for a risky action. Right now
> that means alt-tabbing back to a terminal, reading a wall of text, and
> typing a one-word reply. Miri turns that into a voice loop: the agent's
> question is spoken to you through a small macOS status pill, you answer by
> holding a hotkey and talking, and your reply goes back to the exact agent
> session that asked — not just "whichever terminal is focused." Approval
> requests get their own explicit voice phrase ("approve request" / "deny
> request") so a mumbled "yeah" can't accidentally authorize a command.
> Everything runs locally: Parakeet (NVIDIA, Apache/CC-BY licensed) does
> transcription on the Apple Neural Engine, PocketTTS (Kyutai) does speech
> synthesis, both in-process via CoreML. No account, no API key, no
> subscription, no audio leaving the machine. It's free, open source
> (Apache-2.0), and about 56 MB.

---

## 3. Who this is for (audience / positioning)

**Primary audience:** developers who already use an agentic coding CLI
(Codex is the only *live-validated* one — see Section 4) and who work in
long autonomous sessions where the agent periodically needs a
decision/approval from a human who has stepped away from the keyboard.

**Explicitly not the audience (say so if asked, don't oversell):**
- People who want general dictation across every Mac app in many languages —
  that's Wispr Flow, Superwhisper, etc. Miri is agent-session-specific, not a
  system-wide dictation replacement (though it does have a `cursor` dictation
  target as one option, it's not the headline feature).
- People who want a multi-device / mobile / remote agent dashboard — that's
  Paseo. Miri is a single-Mac, session-scoped voice loop, no remote access.
- Windows/Linux users. Miri is Apple Silicon macOS only, full stop.

**The wedge, in one sentence:** Miri is the only tool that turns a coding
agent's stop-and-ask moment into an actual two-way spoken conversation
routed to the exact session that asked — not a general dictation tool, not a
multi-agent dashboard.

See `docs/competitive-landscape.md` for the full comparison table and the
detailed Wispr Flow comparison if you need comparison copy (e.g. a "how is
this different from X" FAQ answer or HN comment reply). Do not invent
competitor claims not in that file — it was researched and dated, re-verify
before quoting anything from it if it's more than a month old at launch time.

---

## 4. Facts and proof points — use only what's verified

Split deliberately into **verified** (safe to state as fact) and **claimed
but not yet proven** (do not state as fact; if mentioned, hedge explicitly).

### Verified (safe to state)

- Native SwiftUI/AppKit menu-bar app, Apple Silicon only, macOS 14+.
- Speech runs fully on-device: Parakeet TDT (NVIDIA, CC-BY-4.0) for
  transcription on the Apple Neural Engine, PocketTTS (Kyutai) for synthesis,
  both via FluidAudio (Apache-2.0) CoreML — no Python runtime anywhere in the
  product.
- Packaged app is ~56 MB (arm64-only); no model weights bundled — downloaded
  after one explicit consent prompt covering ~1 GB total.
- No local HTTP server; private Unix domain socket only.
- No persistent transcript history; failed deliveries live in memory only.
- Open source, Apache-2.0 licensed, source on GitHub.
- Free — no subscription, no account, no API key required for local speech.
- Codex integration: exact-thread targeting, spoken agent status/questions,
  voice-driven approval ("approve request"/"deny request"), and a blocking
  `voice_ask` MCP tool that lets an agent ask a question mid-turn and resume
  with the spoken answer instead of ending its turn cold. This is the
  **live-validated** path.
- 162 automated tests passing (`swift test`), 0 failures, at time of writing
  — this number changes; check `AGENTS.md`/CI before quoting it.
- CI (GitHub Actions) green on `main` at time of writing.
- Community distribution is ad-hoc signed, not notarized — Gatekeeper's
  "Open Anyway" is required. This must be disclosed, not hidden, in every
  piece of launch copy (see Section 5).

### Claimed but not yet independently proven — hedge or omit

- **Specific latency numbers.** The only benchmark evidence on disk predates
  the CoreML pivot and is explicitly marked stale in `docs/benchmarks.md`.
  Do not quote "251ms" or any other number from that historical section as a
  current claim. If you want a performance claim, use qualitative language
  ("designed for sub-second responses," "the developer's target is under
  100ms overlay response") and mark it as a target, not a measured result,
  until Section 1's benchmark gate closes.
- **"Rock solid" / crash-free claims.** Multiple real bugs (mic left
  recording, approval schema mismatches, a SIGPIPE crash) were found and
  fixed in code during hardening, but the real-hardware acceptance test
  (repeated voice loops, rapid hotkey re-entry) has not been run yet as of
  this writing. Do not claim "battle-tested" or "production-hardened"
  language until that's done — say "actively hardened" or "in final
  testing" instead.
- **Claude Code and Hermes support.** These adapters exist in code but have
  no live compatibility evidence. Launch copy must label them
  "experimental" exactly like the docs do — never imply they're as solid as
  Codex.
- **Notarization.** Never say or imply the app is notarized, "Apple
  verified," or from the Mac App Store. It is ad-hoc signed. Always mention
  the Gatekeeper Open Anyway step when describing installation.

---

## 5. Hard guardrails — do not say these things

These are not style preferences, they are factually wrong or legally risky
claims that would embarrass the project if said publicly:

1. **Do not call it notarized, App Store-available, or "verified by Apple."**
   It is ad-hoc signed. Every install mention needs the Gatekeeper caveat.
2. **Do not claim cross-platform.** Apple Silicon macOS only. No Windows, no
   Linux, no Intel Mac. Say so plainly, don't bury it.
3. **Do not claim cloud transcription, wake word, or a model picker exist.**
   They were removed/are not available in 0.1.4. If asked, say "not in this
   release" rather than silently omitting.
4. **Do not claim Claude Code or Hermes are as validated as Codex.** Say
   "experimental" every time they're named next to Codex.
5. **Do not invent specific benchmark numbers.** See Section 4.
6. **Do not claim it beats Wispr Flow / Superwhisper / other dictation tools
   at dictation.** It doesn't try to — it's a different product (agent voice
   loop, not general dictation). Positioning against them should be
   "different job," not "better at their job."
7. **Do not claim funding, team size, revenue, or user counts** unless
   explicitly given real numbers by the person directing this work. If none
   are given, omit — do not write "thousands of developers" or similar filler.
8. **Do not promise a specific launch date** unless told one explicitly.
9. **Do not use "AI-generated" filler stats** ("saves you 10 hours a week") —
   there is no data behind that. Keep claims to what's demonstrably true
   about the mechanism (routes to exact session, runs locally, etc.), not
   invented productivity math.
10. **Security/privacy claims stay literal.** "No audio leaves your Mac" is
    true and provable (no HTTP server, local-only socket). Don't upgrade this
    to "enterprise-grade security" or "HIPAA compliant" — those are
    unverified/false claims (see the Wispr Flow comparison — HIPAA/SOC2 is
    something *they* have, not Miri).

---

## 6. Voice and tone

Match the existing docs, not generic startup marketing voice:

- Direct, technical, no hype adjectives ("revolutionary," "game-changing,"
  "seamless"). Look at how `README.md` and `docs/competitive-landscape.md`
  are written — plain declarative sentences, specific numbers where known,
  honest about limitations in the same breath as features.
- Confident about the actual differentiator (exact-session routing,
  bidirectional voice, local-only) without oversell.
- Comfortable naming limitations. The existing docs literally have "Where
  0.1.4 is behind" and "Where Miri genuinely loses" sections — that honesty
  is a feature of Miri's voice, not something to sand off for launch copy.
  A launch post that admits "Claude Code support is experimental" or "this
  isn't notarized yet, here's the one-time Gatekeeper step" reads as more
  credible to the target audience (developers) than a post that hides it.
- Developer-to-developer register. Assume the reader knows what MCP,
  push-to-talk, and a coding agent are. Don't over-explain basics; do explain
  Miri-specific concepts (target snapshotting, the attention queue, exact
  thread binding) since those are the actual differentiators.

---

## 7. Existing assets

- `assets/miri-demo.gif` (784 KB) — voice capture, target routing, status
  pill demo. Already embedded in README. Reuse for blog/PH/Twitter unless a
  better one is recorded for launch.
- `assets/miri-demo.png` (72 KB) — static frame equivalent.
- No existing screenshots of Settings UI, no professionally shot video, no
  logo/icon file located outside the app bundle as of this writing — flag to
  the person directing this work if channel-specific assets (PH gallery
  needs 3-5 images minimum, Twitter benefits from a vertical clip) are
  needed and don't exist yet; do not fabricate placeholder images.
- GitHub repo: `https://github.com/adityakanu/miri` (confirm this is the
  intended public URL before publishing — it's the `origin` remote as of
  this writing).
- License: Apache-2.0. `THIRD-PARTY-NOTICES.md` and `docs/model-licenses.md`
  have full attribution if a legal/licensing question comes up publicly.

---

## 8. Channel briefs

Each brief is a structure + must-include list, not final copy — the agent
executing it should write real prose following Section 6's voice, using only
Section 4's verified facts, respecting Section 5's guardrails.

### 8.1 Blog post (launch announcement)

**Structure:**
1. Open with the problem: agents increasingly stop mid-task to ask a
   question or request approval; today that means alt-tabbing and typing.
2. Introduce Miri as the answer — one paragraph from Section 2.
3. Walk through the actual loop with specifics: hold hotkey → speak → Miri
   snapshots the target session → transcript delivered → agent replies →
   spoken back → for approvals, explicit "approve request"/"deny request"
   phrase, decline-on-disconnect fail-closed behavior.
4. One section on *why local-only matters* (offline, no audio leaves the
   Mac, works on a locked-down network) — this is a real architectural
   differentiator, not marketing fluff, so give it real explanation.
5. One honest section on current scope: Codex is the validated adapter,
   Claude Code/Hermes are experimental, Apple Silicon only, ad-hoc signed
   (Gatekeeper Open Anyway required this release).
6. Install instructions or link to README's Get Miri section.
7. Close with what's next (only if the person directing this work gives you
   a real roadmap item — otherwise omit rather than invent one).

**Must include:** the Gatekeeper/ad-hoc-signing disclosure, the "Codex is
validated, others are experimental" line, a link to the GitHub repo.
**Length:** 600-1000 words is enough; this is a technical audience, not a
listicle audience.

### 8.2 Product Hunt listing

**Tagline (≤60 chars):** pick one from Section 2's "alt taglines," trim to
fit. Example: "Talk to your coding agent. Nothing leaves your Mac." (fits).

**Description:** 1-2 short paragraphs, front-load the mechanism (hold key,
speak, routes to exact session, agent talks back) before the local-only
pitch. PH audience reads fast — lead with what it does, not why it's special.

**First comment (maker comment):** Write this as a real "why I built this"
note, first-person, from the perspective of a maker who wanted to stop
alt-tabbing to check on long agent runs. Be honest about it being an early,
free, ad-hoc-signed community release — PH audiences respond well to candor
about early-stage software, badly to overclaiming polish.

**Gallery:** needs 3-5 images/GIFs. Only `miri-demo.gif`/`.png` exist today
— flag to the person directing this work that more assets (Settings UI
screenshot, the status pill states, an approval-flow screenshot) would
strengthen the listing, but do not fabricate mockups presented as real
screenshots.

**Topics/categories to consider:** Developer Tools, Productivity, macOS,
Artificial Intelligence, Open Source. (Suggest; final call is the launcher's.)

### 8.3 X/Twitter launch thread

**Structure (aim for 5-8 tweets):**
1. Hook tweet: the problem in one line + one line of what Miri does. Attach
   `miri-demo.gif` here — this is the highest-leverage single asset.
2. How it works: hold hotkey, speak, exact-session routing (not "whichever
   terminal is focused" — this is the concrete differentiator, say it
   explicitly).
3. The bidirectional part: agent asks a question or wants approval, speaks
   it to you, you answer by voice, reply routes back to that exact agent
   turn.
4. The approval safety mechanism specifically — this is a genuinely unusual
   feature worth its own tweet: explicit phrase required, fail-closed on
   disconnect.
5. Local-only / privacy angle: on-device Parakeet + PocketTTS via CoreML, no
   audio leaves the Mac, no subscription.
6. Honest scope tweet: Codex validated, Claude Code/Hermes experimental,
   Apple Silicon macOS only, free and open source (Apache-2.0), link to
   GitHub. This tweet is not optional — see Section 5's guardrails.
7. Call to action: link to GitHub Releases (once a real link exists — use a
   placeholder until then) and/or Product Hunt page if launching same-day.

**Tone:** more casual than the blog post is fine, but do not drop the
guardrails from Section 5 just because it's a shorter format — the "Apple
Silicon only, ad-hoc signed, Codex-validated" facts still need to appear
somewhere in the thread.

### 8.4 Show HN post

**Title format:** `Show HN: Miri – a local voice bridge for coding agents`
(HN prefers plain, low-hype titles; do not add adjectives like "revolutionary").

**Body:** 2-4 short paragraphs. HN readers are unusually likely to ask about
architecture, privacy, and "why not just use X" — pre-empt with:
- One sentence on the local inference stack (Parakeet on ANE, PocketTTS,
  CoreML, no Python, no cloud).
- One sentence on how routing/target-snapshotting works, since "how do you
  know which agent session to send this to" is the first HN question.
- Explicit acknowledgment of ad-hoc signing / Gatekeeper, unprompted — HN
  readers penalize hiding this far more than the fact itself costs you.
- Link to GitHub, not a landing page — HN prefers source.

**Anticipate these HN comments and have honest answers ready** (don't
pre-write comment replies, but know the honest answer):
- "Why not just use Wispr Flow / Superwhisper?" → different job, see Section 3.
- "Why isn't this notarized?" → ad-hoc signing is free, notarization needs a
  paid Apple Developer account; this is community/free-tier for now.
- "Does this send my code to a server?" → No — architecture answer from
  Section 4's verified facts.
- "Why macOS only / why Apple Silicon only?" → Neural Engine dependency;
  honest technical answer, not deflection.

### 8.5 Reddit (r/macapps, r/LocalLLaMA, r/programming as relevant)

Adapt the Show HN body per subreddit norms — r/LocalLLaMA cares most about
the on-device model stack (Parakeet/PocketTTS/CoreML specifics, model sizes,
license), r/macapps cares most about the install experience and Gatekeeper
step, r/programming cares about the architecture (adapters, exact-session
routing, MCP). Do not cross-post identical copy — tailor the lead paragraph
to what that community actually wants first, keep Section 5's guardrails in
every version.

### 8.6 Launch video script (60-90 second demo)

**Structure:**
1. (0-10s) Cold open on the problem: an agent mid-task, stopped, waiting —
   show a terminal with a pending approval/question, cursor idle.
2. (10-25s) Hold hotkey, speak a prompt, show the status pill states
   (listening → transcribing → sending → delivered) — this is the visual
   heart of the demo, use screen capture, not a mockup.
3. (25-45s) Agent responds; show a spoken status/question coming back,
   demonstrate answering by voice, reply routing back to the same session.
4. (45-60s) Approval moment: agent requests approval, show saying "approve
   request" explicitly (not just "yes") — this sells the safety mechanism
   visually in a way prose can't.
5. (60-75s) Quick cut to Settings/target list to show exact-session
   selection (the "not just whichever terminal is frontmost" claim, shown
   not told).
6. (75-90s) Close on: free, open source, local-only, Apple Silicon, link on
   screen.

**Do not** use synthesized/AI voiceover claiming to be a real user testimonial.
**Do not** show fabricated performance numbers on screen — if a stat overlay
is wanted, use only Section 4 "verified" facts (56 MB, on-device, etc.), not
latency numbers.
**Screen recording, not stock footage** — this is a screen-capture demo
product, authenticity matters more than production polish for this audience.

---

## 9. FAQ / objection handling

Reusable answers for comment replies, PH Q&A, etc. Keep these consistent
across every channel rather than improvising differently each time.

**"Is my audio sent anywhere?"**
No. Transcription (Parakeet) and synthesis (PocketTTS) both run on-device via
CoreML. Miri opens no HTTP server; the only IPC is a private Unix domain
socket used by the bundled CLI helpers. No analytics.

**"Does it work with Claude Code / Hermes / other agents?"**
Adapters exist for both, but only Codex has live end-to-end validation as of
0.1.4. Claude Code and Hermes are labeled experimental — try them, but expect
rough edges until they get the same validation depth.

**"Why isn't it notarized / why do I need Open Anyway?"**
Apple notarization requires a paid Developer ID account; this release is a
free, community, ad-hoc-signed build. The one-time Gatekeeper override is the
trade-off for a free artifact. Verify the published checksum before
overriding, and only do this for a DMG downloaded from the official GitHub
Releases page.

**"Windows/Linux support?"**
Not planned for this release. Transcription depends on the Apple Neural
Engine, which doesn't exist outside Apple Silicon.

**"How is this different from [Wispr Flow / Superwhisper / dictation tool]?"**
Different job. Those tools insert text wherever your cursor is, across any
app. Miri routes a transcript to a specific, snapshotted agent session and
lets that agent talk back — including asking questions and requesting
approval by voice. See `docs/competitive-landscape.md` for the full
comparison if a longer answer is needed.

**"Is this free forever / what's the business model?"**
State only what's actually true: it's open source (Apache-2.0), free, no
subscription for local speech. Do not speculate about future monetization
unless the person directing this work gives an actual answer to use.

---

## 10. Boilerplate (for author bios, footers, about sections)

> Miri is an open-source (Apache-2.0), local-first macOS app that lets you
> talk to your coding agents. It routes voice to the exact agent session
> you're working in and speaks filtered status, questions, and approval
> requests back — all with on-device speech recognition and synthesis, no
> cloud dependency. Apple Silicon, macOS 14+.

---

## 11. Before you publish — final checklist

Run this against any draft before it goes out:

- [ ] Every specific number (size, test count, latency) traces to Section 4
      "verified," not invented or pulled from the stale historical benchmark.
- [ ] Ad-hoc signing / Gatekeeper Open Anyway is disclosed if installation is
      discussed at all.
- [ ] Codex is described as validated; Claude Code/Hermes as experimental,
      if mentioned at all.
- [ ] No cross-platform, notarization, cloud-transcription, or wake-word
      claims.
- [ ] No invented user counts, funding, dates, or productivity stats.
- [ ] Links point to the real GitHub repo, not a placeholder — or the
      placeholder is clearly marked `[NEEDS LINK]` rather than a fake URL.
- [ ] Re-read Section 1 — if gates are still open, the draft says "coming
      soon" / uses placeholders rather than "available now."
