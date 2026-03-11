#!/usr/bin/env python3
import argparse
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path


def fetch_json(url: str, params: dict) -> dict:
    query = urllib.parse.urlencode(params)
    with urllib.request.urlopen(f"{url}?{query}", timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def service_candidates(entry_service: str):
    candidates = [entry_service]
    if "." in entry_service:
        candidates.append(entry_service.split(".", 1)[0])
    # Preserve order while removing duplicates.
    seen = set()
    for item in candidates:
        if item and item not in seen:
            seen.add(item)
            yield item


def main():
    parser = argparse.ArgumentParser(description="Export Jaeger traces for one run window.")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--jaeger-url", required=True)
    parser.add_argument("--entry-service", required=True)
    parser.add_argument("--start-us", required=True, type=int)
    parser.add_argument("--end-us", required=True, type=int)
    parser.add_argument("--output-json", required=True)
    parser.add_argument("--output-meta", required=True)
    parser.add_argument("--limit", type=int, default=5000)
    args = parser.parse_args()

    output_json = Path(args.output_json)
    output_meta = Path(args.output_meta)
    output_json.parent.mkdir(parents=True, exist_ok=True)
    output_meta.parent.mkdir(parents=True, exist_ok=True)

    last_error = None
    selected_service = None
    response_doc = None
    trace_count = 0
    truncated = False

    for candidate in service_candidates(args.entry_service):
        selected_service = candidate
        params = {
            "service": candidate,
            "start": args.start_us,
            "end": args.end_us,
            "limit": args.limit,
            "lookback": "custom",
        }
        try:
            response_doc = fetch_json(f"{args.jaeger_url.rstrip('/')}/api/traces", params)
            trace_count = len(response_doc.get("data", []))
            truncated = trace_count >= args.limit
            if trace_count > 0:
                break
        except Exception as exc:  # noqa: BLE001
            last_error = str(exc)
            response_doc = {"data": []}

    if response_doc is None:
        output_json.write_text(
            json.dumps({"data": [], "status": "error", "reason": last_error or "query_failed"}, ensure_ascii=True, indent=2) + "\n",
            encoding="utf-8",
        )
        output_meta.write_text(
            json.dumps(
                {
                    "run_dir": args.run_dir,
                    "entry_service_requested": args.entry_service,
                    "entry_service_used": None,
                    "start_us": args.start_us,
                    "end_us": args.end_us,
                    "limit": args.limit,
                    "trace_count": 0,
                    "truncated": False,
                    "status": "error",
                    "reason": last_error or "query_failed",
                },
                ensure_ascii=True,
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        sys.exit(1)

    output_json.write_text(json.dumps(response_doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
    output_meta.write_text(
        json.dumps(
            {
                "run_dir": args.run_dir,
                "entry_service_requested": args.entry_service,
                "entry_service_used": selected_service,
                "start_us": args.start_us,
                "end_us": args.end_us,
                "limit": args.limit,
                "trace_count": trace_count,
                "truncated": truncated,
                "status": "ok" if trace_count > 0 else "empty",
                "reason": None if trace_count > 0 else "no_traces_found",
            },
            ensure_ascii=True,
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
