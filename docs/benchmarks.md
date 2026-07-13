# Performance benchmark protocol

No performance result is recorded yet. M4 is the intended validated platform;
M1 remains best-effort until a physical M1 report is checked in. Missing samples
produce an `incomplete` report and never count as a passing gate.

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
python3 scripts/benchmark.py --pid <pid> --duration 300 \
  --events ~/Library/Logs/Miri/performance.jsonl \
  --output artifacts/benchmarks/m4-responsive.json
```

The harness requires at least 30 samples for every gated metric. Run at least 30
representative utterances for each latency p95, after models are
warm, on AC power with the release build and `responsive` profile. Record cold
start separately in release notes; it is informative but not one of the locked
gates. Do not mix M1/M4 results or profiles in one report. Preserve the generated
JSON, exact Git revision, app/model versions, input device, output device, and
whether Bluetooth was active.

Locked gates are p95 overlay under 100 ms, p95 final transcript under 1 second,
p95 first audio under 500 ms, mean push-to-talk idle CPU under 1%, and maximum
observed warm RSS under 1.25 GB. Wake-word idle CPU is reported separately and
must remain under 5% of one M-series core.

Evidence placeholders:

| Hardware | Profile | Evidence | Status |
| --- | --- | --- | --- |
| Physical M4 / 16 GB | responsive | `artifacts/benchmarks/m4-responsive.json` | Not measured |
| Physical M1 | responsive | `artifacts/benchmarks/m1-responsive.json` | Not measured; best-effort support |
