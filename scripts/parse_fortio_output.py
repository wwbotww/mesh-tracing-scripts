#!/usr/bin/env python3
import json
import re
import sys
from pathlib import Path


def parse_duration_seconds(token: str):
    token = token.strip()
    if not token:
        return None
    if token.endswith("s") and re.fullmatch(r"[0-9.]+s", token):
        try:
            return float(token[:-1])
        except ValueError:
            return None

    total = 0.0
    matched = False
    for value, unit in re.findall(r"([0-9]+(?:\.[0-9]+)?)(h|m|s|ms)", token):
        matched = True
        value_f = float(value)
        if unit == "h":
            total += value_f * 3600.0
        elif unit == "m":
            total += value_f * 60.0
        elif unit == "s":
            total += value_f
        elif unit == "ms":
            total += value_f / 1000.0
    return total if matched else None


def maybe_float(value: str):
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def maybe_int(value: str):
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def main():
    if len(sys.argv) != 2:
        print("Usage: parse_fortio_output.py <fortio_stdout.log>", file=sys.stderr)
        sys.exit(2)

    path = Path(sys.argv[1])
    text = path.read_text(encoding="utf-8", errors="replace")
    lines = text.splitlines()

    requested_qps = None
    target_url = None
    total_calls = None
    achieved_qps = None
    average_latency_ms = None
    duration_seconds = None
    warmup_calls = None
    error_cases = None
    status_codes = {}
    latency_ms = {"p50": None, "p75": None, "p90": None, "p95": None, "p99": None, "p999": None}

    in_function_histogram = False
    for line in lines:
        if "running at" in line and "queries per second" in line:
            match = re.search(r"running at ([0-9.]+) queries per second.*for ([^:]+):\s+(.*)$", line)
            if match:
                requested_qps = maybe_float(match.group(1))
                duration_seconds = parse_duration_seconds(match.group(2))
                target_url = match.group(3).strip()
            continue

        if line.startswith("Aggregated Function Time"):
            in_function_histogram = True
            avg_match = re.search(r"avg ([0-9.]+)", line)
            if avg_match:
                average_latency_ms = round(float(avg_match.group(1)) * 1000.0, 6)
            continue

        if in_function_histogram and line.startswith("Error cases"):
            in_function_histogram = False
            error_cases = line.split(":", 1)[1].strip() if ":" in line else line.strip()
            continue

        if in_function_histogram and line.startswith("# target "):
            target_match = re.search(r"# target ([0-9.]+)% ([0-9.]+)", line)
            if target_match:
                pct = target_match.group(1)
                value_ms = round(float(target_match.group(2)) * 1000.0, 6)
                if pct == "50":
                    latency_ms["p50"] = value_ms
                elif pct == "75":
                    latency_ms["p75"] = value_ms
                elif pct == "90":
                    latency_ms["p90"] = value_ms
                elif pct == "95":
                    latency_ms["p95"] = value_ms
                elif pct == "99":
                    latency_ms["p99"] = value_ms
                elif pct in {"99.9", "99.90"}:
                    latency_ms["p999"] = value_ms
            continue

        ended_match = re.search(r"Ended after ([^:]+)\s+: ([0-9]+) calls\. qps=([0-9.]+)", line)
        if ended_match:
            duration_seconds = parse_duration_seconds(ended_match.group(1))
            total_calls = maybe_int(ended_match.group(2))
            achieved_qps = maybe_float(ended_match.group(3))
            continue

        done_match = re.search(r"All done ([0-9]+) calls \(plus ([0-9]+) warmup\) ([0-9.]+) ms avg, ([0-9.]+) qps", line)
        if done_match:
            total_calls = maybe_int(done_match.group(1))
            warmup_calls = maybe_int(done_match.group(2))
            average_latency_ms = maybe_float(done_match.group(3))
            achieved_qps = maybe_float(done_match.group(4))
            continue

        code_match = re.search(r"^Code ([0-9]{3})\s*:\s*([0-9]+)", line)
        if code_match:
            status_codes[code_match.group(1)] = maybe_int(code_match.group(2))

    status_total = sum(v for v in status_codes.values() if isinstance(v, int))
    success_total = sum(
        count for code, count in status_codes.items()
        if isinstance(count, int) and code and code[0] in {"2", "3"}
    )
    error_total = sum(
        count for code, count in status_codes.items()
        if isinstance(count, int) and code and code[0] in {"4", "5"}
    )

    doc = {
        "target_url": target_url,
        "requested_qps": requested_qps,
        "achieved_qps": achieved_qps,
        "duration_seconds": duration_seconds,
        "total_calls": total_calls,
        "warmup_calls": warmup_calls,
        "average_latency_ms": average_latency_ms,
        "latency_ms": latency_ms,
        "status_codes": status_codes,
        "http_success_rate": round(success_total / status_total, 6) if status_total else None,
        "http_error_rate": round(error_total / status_total, 6) if status_total else None,
        "error_cases": error_cases,
        "raw_log": str(path),
    }
    print(json.dumps(doc, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()
