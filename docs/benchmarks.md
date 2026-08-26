# Performance benchmark protocol

An M4 partial report is recorded for 0.1.4. TTS and aggregate resource gates
pass; the report remains `incomplete` until 30 clean human push-to-talk samples
cover overlay and final-transcript latency. M1 remains best-effort until a
physical M1 report is checked in. Missing samples never count as passing.

The app writes privacy-safe timing events to
`~/Library/Logs/Miri/performance.jsonl` (no audio or transcript text):

```json
{"metric":"overlay_response_ms","value":72.4,"session_id":"example"}
{"metric":"final_transcript_ms","value":841.0,"session_id":"example"}
{"metric":"first_audio_ms","value":311.2,"session_id":"example"}
{"metric":"cold_start_ms","value":918.5,"session_id":"launch-example"}
```

Capture resource usage from a warm, idle app and combine it with the event file:

```sh
pgrep -x Miri
baseline=$(wc -l < ~/Library/Logs/Miri/performance.jsonl)
python3 scripts/benchmark.py --pid <app-pid> --pid <worker-pid> --duration 300 \
  --events ~/Library/Logs/Miri/performance.jsonl \
  --events-start-line "$baseline" \
  --output artifacts/benchmarks/m4-responsive.json
```

Repeat `--pid` so CPU and RSS include Swift, Python inference, and any managed
agent-server child included in the release measurement. The harness
requires at least 30 samples for every gated metric. Run at least 30
representative utterances for each latency p95, after models are
warm, on AC power with the release build and `responsive` profile. Record cold
start separately in release notes; it is informative but not one of the locked
gates. Do not mix M1/M4 results or profiles in one report. Preserve the generated
JSON, exact Git revision, app/model versions, input device, output device, and
whether Bluetooth was active.

For a reproducible synthetic full-path run, grant the invoking terminal
Accessibility permission and run `scripts/benchmark-utterance.swift` 30 times
with varied phrases. It posts the real Option-Space hotkey and plays the phrase
through the selected output into the selected microphone. Label this evidence
`synthetic-loopback`; it catches regressions but does not replace the 30 spoken
human utterances required for release accuracy and real-world latency claims.

Resource and latency phases may be combined without fabricating samples. After
collecting human utterances, preserve the earlier resource gates with:

```sh
python3 scripts/benchmark.py \
  --events ~/Library/Logs/Miri/performance.jsonl --events-start-line "$baseline" \
  --base-report artifacts/benchmarks/m4-responsive.json \
  --output artifacts/benchmarks/m4-responsive.json
```

Locked gates are p95 overlay under 100 ms, p95 final transcript under 1 second,
p95 first audio under 500 ms, mean push-to-talk idle CPU under 1%, and maximum
observed warm RSS under 1.25 GB. Wake-word idle CPU is reported separately and
must remain under 5% of one M-series core.

Evidence placeholders:

| Hardware | Profile | Evidence | Status |
| --- | --- | --- | --- |
| Physical M4 / 16 GB | responsive | `artifacts/benchmarks/m4-responsive.json` | Partial: TTS, CPU, RSS pass; STT/overlay pending |
| Physical M1 | responsive | `artifacts/benchmarks/m1-responsive.json` | Not measured; best-effort support |

## 0.1.4 M4 partial result

Captured 2026-07-16 on a MacBook Air `Mac16,12`, Apple M4, 16 GB, macOS
26.5.1. The run included the Swift app, Python speech worker, and managed Codex
app-server. Pocket TTS used 30 warm status phrases; resources used 293 samples
over five idle minutes.

| Gate | Result | Limit | Status |
| --- | ---: | ---: | --- |
| First speech audio p95 | 251.258 ms | < 500 ms | Pass |
| Idle CPU mean | 0.077% | < 1% | Pass |
| Warm RSS maximum | 117.547 MB | < 1,280 MB | Pass |
| Overlay response p95 | Missing | < 100 ms | Incomplete |
| Final transcript p95 | Missing | < 1,000 ms | Incomplete |

These are engineering measurements, not competitor claims. Do not describe the
overall benchmark as passing until the two missing human-input gates pass.
