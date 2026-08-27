# Performance benchmark protocol

> [!IMPORTANT]
> **The existing evidence is stale and must be recollected before 0.1.4 ships.**
> The only report on disk, `artifacts/benchmarks/m4-responsive.json`, was
> captured on 2026-07-16 at revision `d1e55b2`, which predates the removal of
> the Python worker (`534c228`). It measured a Swift app *plus a Python speech
> worker* across three PIDs. That process topology no longer exists: all speech
> now runs on CoreML inside the app. Its numbers do not describe the shipping
> build and must not be quoted in release notes.
>
> The report is also `incomplete` on its own terms: overlay response and final
> transcript have zero samples. Missing samples never count as passing.

## What must be recollected

A releasable M4 report must be captured from the current CoreML-only build with:

- 30 clean human push-to-talk utterances for overlay response;
- 30 clean human push-to-talk utterances for final transcript;
- 30 warm status phrases for first speech audio;
- at least five idle minutes of resource sampling;
- the **single** Miri PID plus any managed agent-server child. There is no
  longer a Python worker PID to include.

## Event stream

The app writes privacy-safe timing events to
`~/Library/Logs/Miri/performance.jsonl` (no audio or transcript text):

```json
{"metric":"overlay_response_ms","value":72.4,"session_id":"example"}
{"metric":"final_transcript_ms","value":841.0,"session_id":"example"}
{"metric":"first_audio_ms","value":311.2,"session_id":"example"}
{"metric":"cold_start_ms","value":918.5,"session_id":"launch-example"}
```

## Collecting a report

Capture resource usage from a warm, idle app and combine it with the event file:

```sh
pgrep -x Miri
baseline=$(wc -l < ~/Library/Logs/Miri/performance.jsonl)
python3 scripts/benchmark.py --pid <miri-pid> --duration 300 \
  --events ~/Library/Logs/Miri/performance.jsonl \
  --events-start-line "$baseline" \
  --output artifacts/benchmarks/m4.json
```

`scripts/benchmark.py` is a developer measurement harness run from your own
Python 3; it is not part of the shipped product and no Python is installed on a
user's machine.

Repeat `--pid` for any managed agent-server child that should be included in the
release measurement. The harness requires at least 30 samples for every gated
metric. Run the release build on AC power. Record cold start separately in
release notes; it is informative but not one of the locked gates. Do not mix M1
and M4 results in one report. Preserve the generated JSON, exact Git revision,
app/model versions, input device, output device, and whether Bluetooth was
active.

Resource and latency phases may be combined without fabricating samples. After
collecting human utterances, preserve the earlier resource gates with:

```sh
python3 scripts/benchmark.py \
  --events ~/Library/Logs/Miri/performance.jsonl --events-start-line "$baseline" \
  --base-report artifacts/benchmarks/m4.json \
  --output artifacts/benchmarks/m4.json
```

For a reproducible synthetic full-path run, grant the invoking terminal
Accessibility permission and run `scripts/benchmark-utterance.swift` 30 times
with varied phrases. It posts the real Option-Space hotkey and plays the phrase
through the selected output into the selected microphone. Label this evidence
`synthetic-loopback`; it catches regressions but does not replace the 30 spoken
human utterances required for release accuracy and real-world latency claims.

## Locked gates

| Gate | Rule | Limit |
| --- | --- | ---: |
| Overlay response | p95 | < 100 ms |
| Final transcript | p95 | < 1,000 ms |
| First speech audio | p95 | < 500 ms |
| Idle CPU (push-to-talk) | mean | < 1% |
| Warm RSS | maximum | < 1,280 MB |

The harness still emits a `wake_word_idle_cpu_percent` field. Wake word is not
selectable in 0.1.4, so that metric is always empty and is not a release gate.
The report's `profile` field is likewise vestigial: model lifecycle profiles are
no longer user-selectable.

## Evidence status

| Hardware | Evidence | Status |
| --- | --- | --- |
| Physical M4 / 16 GB | `artifacts/benchmarks/m4-responsive.json` | **Stale** — captured at `d1e55b2` against the removed Python worker, and incomplete. Recollect. |
| Physical M1 | not captured | Not measured; best-effort support |

## Historical record: pre-CoreML M4 partial run

Retained only for provenance. **Do not cite these figures for 0.1.4.**

Captured 2026-07-16 on a MacBook Air `Mac16,12`, Apple M4, 16 GB, macOS 26.5.1,
at revision `d1e55b2`. The run included the Swift app, the since-removed Python
speech worker, and a managed Codex app-server.

| Gate | Result | Limit | Status |
| --- | ---: | ---: | --- |
| First speech audio p95 | 251.258 ms | < 500 ms | Pass (obsolete topology) |
| Idle CPU mean | 0.077% | < 1% | Pass (obsolete topology) |
| Warm RSS maximum | 117.547 MB | < 1,280 MB | Pass (obsolete topology) |
| Overlay response p95 | no samples | < 100 ms | Incomplete |
| Final transcript p95 | no samples | < 1,000 ms | Incomplete |

These are engineering measurements, not competitor claims. The overall benchmark
is not passing and must not be described as passing.
