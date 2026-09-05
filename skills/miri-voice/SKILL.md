---
name: miri-voice
description: Use when working under Miri voice control. Report progress and ask blocking questions by voice.
---

# Working with the user by voice through Miri

The user is not reading your output. They spoke to you, walked away, and are
listening. Everything they learn about this task arrives as speech, so what you
say through Miri is the entire interface.

Two tools:

- `voice_ask` — say something and **block until the user answers**. Returns
  their spoken reply.
- `voice_status` — say something and return immediately. Fire and forget.

## The rule

**If you need an answer, use `voice_ask`. Never end your turn to ask a
question.**

Ending your turn throws away everything you worked out. The user's reply comes
back as a fresh request and you start cold, re-reading files you already read.
`voice_ask` holds your turn open, so the answer arrives mid-thought and you
carry straight on with full context.

```jsonc
// Blocked on a decision. Blocks until they answer.
{"name": "voice_ask", "arguments": {
  "text": "The migration will drop the sessions table. Should I go ahead, or write a backfill first?"
}}
// -> "write the backfill first"  — you keep going, same turn
```

## When to speak

Speak at the boundaries of long work, not throughout it.

| Moment | Tool | Example |
|---|---|---|
| Starting work >2 min | `voice_status` progress | "Starting the refactor. About twenty files." |
| Every few minutes of long work | `voice_status` progress | "Eight files done, still going." |
| Need a decision | **`voice_ask`** | "Tests pass but coverage dropped four percent. Continue or investigate?" |
| Genuinely stuck | **`voice_ask`** kind=blocker | "The staging credentials are rejected. Do you want to fix them, or should I skip staging?" |
| Work finished | `voice_status` completion | "Done. Sixteen files changed, all tests pass." |
| Something they must know | `voice_status` warning | "Heads up, I had to downgrade the parser to make the build work." |

Progress pings matter more than they look: each one tells Miri you are alive,
which keeps your session routable so the user's reply comes back to *you*
rather than to whichever agent spoke most recently.

Do not narrate every step. A 30-minute task wants perhaps four or five
messages. If you would not say it aloud to someone in the room, do not send it.

## Writing for the ear

The text is spoken by a synthesiser and capped at 180 characters. Miri rejects
anything that looks like code, a secret, or an absolute path.

- Say "the auth module", not `src/auth/handlers/oauth2.ts`.
- Say "the tests fail on the null case", not the stack trace.
- Say "port 8080", not `PORT=8080`.
- One idea per message. No lists, no markdown, no symbols.

Asking well is the difference between a two-second answer and a confused pause:

- Ask **one** question. Two questions in one breath cannot be answered in one.
- Name the options: "Postgres or SQLite?" beats "what database?"
- Give the fact that forces the decision, then ask. "The API returns 500 on
  empty input. Should I fix the API or guard the caller?"
- Never ask something you can safely decide yourself. Every question costs the
  user their attention.

## Handling the answer

The reply is a raw voice transcript. It will be casual, sometimes clipped, and
occasionally misheard.

- "yeah go ahead", "yep", "do it" all mean yes.
- If it is ambiguous or clearly a mis-transcription, ask once more with the
  options named. Do not guess on anything destructive.
- If the result says **no answer arrived**, the user did not respond. That is
  **not** approval. Stop and leave things in a safe state, or do the reversible
  half of the work and report what you skipped. Never read silence as consent.

Timeout is 10 minutes by default, 30 maximum. Set `timeout_seconds` higher when
they may be away from the desk — a blocked agent waiting quietly is much better
than one that guessed wrong.

## Approvals are separate

If your own tooling raises a permission prompt (running a command, editing
files), Miri handles that itself and speaks it to the user. Do not use
`voice_ask` to re-ask for permission you have already requested through your
normal approval mechanism — the user would be asked twice for the same thing.

## Worked example

A 25-minute task, five messages total:

1. `voice_status` progress — "Starting the payments refactor. Roughly twenty
   minutes."
2. `voice_status` progress — "Interfaces are done, moving on to the tests."
3. `voice_ask` — "Two tests assume the old retry behaviour. Update them to
   match, or keep the old behaviour?" → *"update them"*
4. `voice_ask` kind=blocker — "The integration suite needs a Stripe test key I
   do not have. Do you want to add one, or should I skip those tests?" →
   *"skip them for now"*
5. `voice_status` completion — "Done. Payments refactored, unit tests pass,
   integration tests skipped as agreed."

The user heard five sentences over 25 minutes, made two decisions, and never
opened a screen.
