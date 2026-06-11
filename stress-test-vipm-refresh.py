#!/usr/bin/env python3
"""Stress-test `vipm refresh` to measure its success/failure rate.

Runs `vipm refresh` back-to-back for a fixed duration (default 1 hour),
treating a non-zero exit code OR a hang past the timeout as a failure, then
writes a report of success/failure rates and failure details.

Usage:
    python stress-test-vipm-refresh.py
    python stress-test-vipm-refresh.py --duration 3600 --timeout 120
"""

from __future__ import annotations

import argparse
import json
import subprocess
import time
from collections import Counter
from datetime import datetime, timedelta
from pathlib import Path

DEFAULT_VIPM = r"C:\Program Files\JKI\VI Package Manager\support\vipm.exe"


def run_once(vipm: str, timeout: int) -> dict:
    """Run a single `vipm refresh`; return a structured result record."""
    start = time.monotonic()
    record = {
        "started": datetime.now().isoformat(timespec="seconds"),
        "duration_s": None,
        "exit_code": None,
        "status": None,        # "success" | "failure" | "timeout"
        "stdout_tail": "",
        "stderr_tail": "",
    }
    try:
        proc = subprocess.run(
            [vipm, "refresh"],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        record["exit_code"] = proc.returncode
        record["stdout_tail"] = proc.stdout.strip()[-500:]
        record["stderr_tail"] = proc.stderr.strip()[-500:]
        record["status"] = "success" if proc.returncode == 0 else "failure"
    except subprocess.TimeoutExpired as e:
        record["status"] = "timeout"
        record["exit_code"] = "TIMEOUT"
        record["stdout_tail"] = (e.stdout or "").strip()[-500:] if isinstance(e.stdout, str) else ""
        record["stderr_tail"] = (e.stderr or "").strip()[-500:] if isinstance(e.stderr, str) else ""
    except Exception as e:  # noqa: BLE001 - record any launch failure
        record["status"] = "failure"
        record["exit_code"] = "EXCEPTION"
        record["stderr_tail"] = repr(e)
    record["duration_s"] = round(time.monotonic() - start, 1)
    return record


def write_report(path: Path, results: list[dict], cfg: dict) -> None:
    total = len(results)
    by_status = Counter(r["status"] for r in results)
    successes = by_status.get("success", 0)
    failures = total - successes
    durations = [r["duration_s"] for r in results if r["duration_s"] is not None]
    fail_records = [r for r in results if r["status"] != "success"]

    def pct(n: int) -> str:
        return f"{(100 * n / total):.1f}%" if total else "n/a"

    lines = [
        "# vipm refresh stress-test report",
        "",
        f"- Generated: {datetime.now().isoformat(timespec='seconds')}",
        f"- VIPM: `{cfg['vipm']}`",
        f"- Planned duration: {cfg['duration']}s | Per-call timeout: {cfg['timeout']}s",
        "",
        "## Summary",
        "",
        f"- Total iterations: **{total}**",
        f"- Successes: **{successes}** ({pct(successes)})",
        f"- Failures: **{failures}** ({pct(failures)})",
        f"  - non-zero exit: {by_status.get('failure', 0)}",
        f"  - timeouts (hang > {cfg['timeout']}s): {by_status.get('timeout', 0)}",
    ]
    if durations:
        lines += [
            "",
            "## Timing (seconds)",
            "",
            f"- min / avg / max: {min(durations):.1f} / "
            f"{sum(durations) / len(durations):.1f} / {max(durations):.1f}",
        ]

    lines += ["", "## Failures", ""]
    if not fail_records:
        lines.append("None. 🎉")
    else:
        lines.append("| # | started | status | exit | dur(s) | stderr/stdout tail |")
        lines.append("|---|---------|--------|------|--------|--------------------|")
        for i, r in enumerate(fail_records, 1):
            tail = (r["stderr_tail"] or r["stdout_tail"] or "").replace("\n", " ").replace("|", "\\|")
            lines.append(
                f"| {i} | {r['started']} | {r['status']} | {r['exit_code']} | "
                f"{r['duration_s']} | {tail[:200]} |"
            )

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--duration", type=int, default=3600, help="total run time in seconds (default 3600)")
    ap.add_argument("--timeout", type=int, default=120, help="per-call timeout in seconds (default 120)")
    ap.add_argument("--vipm", default=DEFAULT_VIPM, help="path to vipm.exe")
    ap.add_argument("--report", default="vipm-refresh-report.md", help="markdown report output path")
    ap.add_argument("--jsonl", default="vipm-refresh-results.jsonl", help="raw per-iteration results")
    args = ap.parse_args()

    if not Path(args.vipm).exists():
        raise SystemExit(f"vipm.exe not found at {args.vipm}")

    report_path = Path(args.report)
    jsonl_path = Path(args.jsonl)
    jsonl_path.write_text("", encoding="utf-8")  # truncate

    end_at = datetime.now() + timedelta(seconds=args.duration)
    print(f"Stress-testing `vipm refresh` until {end_at:%H:%M:%S} "
          f"(timeout {args.timeout}s/call)...", flush=True)

    results: list[dict] = []
    i = 0
    while datetime.now() < end_at:
        i += 1
        rec = run_once(args.vipm, args.timeout)
        results.append(rec)
        with jsonl_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(rec) + "\n")
        marker = {"success": "OK", "failure": "FAIL", "timeout": "HANG"}[rec["status"]]
        print(f"[{i:4d}] {marker:4s} exit={rec['exit_code']} {rec['duration_s']}s", flush=True)
        # Rewrite the report each iteration so partial results survive a crash.
        write_report(report_path, results,
                     {"vipm": args.vipm, "duration": args.duration, "timeout": args.timeout})

    print(f"\nDone. {len(results)} iterations. Report: {report_path}", flush=True)


if __name__ == "__main__":
    main()
