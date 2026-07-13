#!/usr/bin/env python3
"""Capture reproducible Miri resource samples and evaluate release budgets.

Latency samples come from an instrumentation JSONL file rather than fabricated
wall-clock proxies. Each line is an object such as:
  {"metric":"final_transcript_ms","value":742.1,"session_id":"..."}
"""

from __future__ import annotations

import argparse
import json
import math
import platform
import statistics
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BUDGETS = {
    "overlay_response_ms": ("max_p95", 100.0),
    "final_transcript_ms": ("max_p95", 1000.0),
    "first_audio_ms": ("max_p95", 500.0),
    "idle_cpu_percent": ("max_mean", 1.0),
    "warm_rss_mb": ("max_max", 1280.0),
}
INFORMATIONAL_METRICS = {"cold_start_ms", "wake_word_idle_cpu_percent"}
MINIMUM_SAMPLES = 30


def percentile(values: list[float], fraction: float) -> float:
    if not values:
        raise ValueError("no samples")
    ordered = sorted(values)
    index = max(0, math.ceil(len(ordered) * fraction) - 1)
    return ordered[index]


def read_events(path: Path | None) -> dict[str, list[float]]:
    samples: dict[str, list[float]] = {}
    if path is None:
        return samples
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, 1):
            if not line.strip():
                continue
            record = json.loads(line)
            metric, value = record.get("metric"), record.get("value")
            if metric not in BUDGETS and metric not in INFORMATIONAL_METRICS:
                raise ValueError(f"{path}:{line_number}: unknown metric")
            if not isinstance(value, (int, float)):
                raise ValueError(f"{path}:{line_number}: invalid metric sample")
            samples.setdefault(metric, []).append(float(value))
    return samples


def ps_sample(pid: int) -> tuple[float, float] | None:
    result = subprocess.run(
        ["/bin/ps", "-o", "%cpu=,rss=", "-p", str(pid)],
        check=False,
        capture_output=True,
        text=True,
    )
    fields = result.stdout.split()
    if result.returncode or len(fields) != 2:
        return None
    return float(fields[0]), float(fields[1]) / 1024.0


def hardware() -> dict[str, str]:
    def sysctl(name: str) -> str:
        result = subprocess.run(
            ["/usr/sbin/sysctl", "-n", name], check=False, capture_output=True, text=True
        )
        return result.stdout.strip() or "unknown"

    return {
        "machine": platform.machine(),
        "model": sysctl("hw.model"),
        "chip": sysctl("machdep.cpu.brand_string"),
        "memory_bytes": sysctl("hw.memsize"),
        "macos": platform.mac_ver()[0],
    }


def git_revision() -> str:
    result = subprocess.run(
        ["/usr/bin/git", "rev-parse", "HEAD"], check=False, capture_output=True, text=True
    )
    return result.stdout.strip() if result.returncode == 0 else "uncommitted"


def summarize(samples: dict[str, list[float]]) -> tuple[dict, dict]:
    summaries, gates = {}, {}
    for metric, (rule, limit) in BUDGETS.items():
        values = samples.get(metric, [])
        if not values:
            summaries[metric] = {"sample_count": 0}
            gates[metric] = {"status": "missing", "rule": rule, "limit": limit}
            continue
        summary = {
            "sample_count": len(values),
            "mean": round(statistics.fmean(values), 3),
            "max": round(max(values), 3),
            "p95": round(percentile(values, 0.95), 3),
        }
        if len(values) < MINIMUM_SAMPLES:
            summaries[metric] = summary
            gates[metric] = {
                "status": "insufficient",
                "rule": rule,
                "limit": limit,
                "minimum_samples": MINIMUM_SAMPLES,
            }
            continue
        measured = summary[{"max_p95": "p95", "max_mean": "mean", "max_max": "max"}[rule]]
        summaries[metric] = summary
        gates[metric] = {
            "status": "pass" if measured < limit else "fail",
            "rule": rule,
            "limit": limit,
            "measured": measured,
        }
    for metric in sorted(INFORMATIONAL_METRICS):
        values = samples.get(metric, [])
        summaries[metric] = {"sample_count": len(values)}
        if values:
            summaries[metric].update(
                mean=round(statistics.fmean(values), 3),
                max=round(max(values), 3),
                p95=round(percentile(values, 0.95), 3),
            )
    return summaries, gates


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, help="sample an already-running Miri process")
    parser.add_argument("--duration", type=float, default=30.0)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--events", type=Path, help="instrumentation JSONL with latency samples")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--profile", choices=("responsive", "balanced", "eco"), default="responsive")
    args = parser.parse_args()

    samples = read_events(args.events)
    if args.pid:
        deadline = time.monotonic() + args.duration
        while time.monotonic() < deadline:
            sample = ps_sample(args.pid)
            if sample is None:
                break
            cpu, rss = sample
            samples.setdefault("idle_cpu_percent", []).append(cpu)
            samples.setdefault("warm_rss_mb", []).append(rss)
            time.sleep(args.interval)

    summaries, gates = summarize(samples)
    status = "incomplete" if any(g["status"] in {"missing", "insufficient"} for g in gates.values()) else (
        "pass" if all(g["status"] == "pass" for g in gates.values()) else "fail"
    )
    report = {
        "schema_version": 1,
        "captured_at": datetime.now(timezone.utc).isoformat(),
        "revision": git_revision(),
        "profile": args.profile,
        "hardware": hardware(),
        "measurement": {"duration_seconds": args.duration, "interval_seconds": args.interval},
        "metrics": summaries,
        "gates": gates,
        "overall_status": status,
        "notes": "Missing or insufficient samples make this report incomplete; they never count as passing.",
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {args.output} ({status})")
    return 1 if status == "fail" else 0


if __name__ == "__main__":
    raise SystemExit(main())
