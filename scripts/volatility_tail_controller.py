#!/usr/bin/env python3
import argparse
import json
import math
import signal
import subprocess
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path


PROFILES = {
    "conservative": {
        "latency_threshold_ms": 500,
        "fallback_sampling_percentage": 1,
        "num_traces": 10000,
        "expected_new_traces_per_sec": 50,
    },
    "balanced": {
        "latency_threshold_ms": 300,
        "fallback_sampling_percentage": 10,
        "num_traces": 30000,
        "expected_new_traces_per_sec": 150,
    },
    "aggressive": {
        "latency_threshold_ms": 200,
        "fallback_sampling_percentage": 30,
        "num_traces": 80000,
        "expected_new_traces_per_sec": 300,
    },
}

PROFILE_BY_LEVEL = {
    "low": "conservative",
    "medium": "balanced",
    "high": "aggressive",
}

THRESHOLDS = {
    "error_rate": {"medium": 0.01, "high": 0.03},
    "p95_ratio": {"medium": 1.50, "high": 2.50},
    "request_surge_ratio": {"medium": 2.00, "high": 3.00},
}

STOP = False


def now_epoch_ms():
    return int(time.time() * 1000)


def iso_timestamp():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def signal_handler(signum, _frame):
    global STOP
    STOP = True


def run_command(command, input_text=None):
    return subprocess.run(
        command,
        input=input_text,
        text=True,
        capture_output=True,
        check=True,
    )


def mean(values):
    if not values:
        return None
    return sum(values) / len(values)


def median(values):
    if not values:
        return None
    s = sorted(values)
    n = len(s)
    if n % 2 == 1:
        return s[n // 2]
    return (s[n // 2 - 1] + s[n // 2]) / 2


def safe_ratio(current, baseline):
    if current is None or baseline in (None, 0):
        return None
    return current / baseline


def load_json(path):
    p = Path(path)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except Exception:
        return None


def query_scalar(prometheus_url, query):
    url = f"{prometheus_url.rstrip('/')}/api/v1/query?{urllib.parse.urlencode({'query': query})}"
    with urllib.request.urlopen(url, timeout=20) as resp:
        doc = json.loads(resp.read().decode("utf-8"))
    result = doc.get("data", {}).get("result", [])
    if not result:
        return None, doc
    raw_value = result[0].get("value", ["", None])[1]
    try:
        return float(raw_value), doc
    except (TypeError, ValueError):
        return None, doc


def build_queries(app_namespace, window_seconds):
    # Use max-per-service metrics instead of mesh-wide aggregates.
    # This prevents signal dilution: a fault on one service (e.g. 400ms delay
    # on productcatalogservice) is clearly visible as a per-service p95 spike,
    # whereas mesh-wide p95 barely moves because other healthy services dominate.
    return {
        "p95_latency_ms": (
            "max("
            "histogram_quantile(0.95, "
            f"sum by (le, destination_workload)(rate(istio_request_duration_milliseconds_bucket{{reporter=\"destination\",destination_workload_namespace=\"{app_namespace}\"}}[{window_seconds}s])))"
            ")"
        ),
        "error_rate": (
            "max("
            f"sum by (destination_workload)(rate(istio_requests_total{{reporter=\"destination\",destination_workload_namespace=\"{app_namespace}\",response_code=~\"5..\"}}[{window_seconds}s])) "
            f"/ clamp_min(sum by (destination_workload)(rate(istio_requests_total{{reporter=\"destination\",destination_workload_namespace=\"{app_namespace}\"}}[{window_seconds}s])), 0.0001)"
            ")"
        ),
        "request_rate": (
            f"sum(rate(istio_requests_total{{reporter=\"destination\",destination_workload_namespace=\"{app_namespace}\"}}[{window_seconds}s]))"
        ),
    }


def collect_metrics(prometheus_url, queries):
    values = {}
    raw_docs = {}
    for name, query in queries.items():
        value, raw_doc = query_scalar(prometheus_url, query)
        values[name] = value
        raw_docs[name] = raw_doc
    return values, raw_docs


def _finite(v):
    return v is not None and not (isinstance(v, float) and (math.isnan(v) or math.isinf(v)))


def compute_baselines(warmup_samples, current_metrics):
    p95_values = [item["p95_latency_ms"] for item in warmup_samples if _finite(item.get("p95_latency_ms"))]
    request_values = [item["request_rate"] for item in warmup_samples if _finite(item.get("request_rate"))]
    # Use MEDIAN instead of MEAN: robust to 1-2 outlier samples from OTel collector
    # restart recovery period that inflate p95 during early warmup.
    baseline_p95 = median(p95_values) if p95_values else None
    baseline_request_rate = median(request_values) if request_values else None
    if not _finite(baseline_p95):
        baseline_p95 = current_metrics.get("p95_latency_ms") if _finite(current_metrics.get("p95_latency_ms")) else None
    if not _finite(baseline_request_rate):
        baseline_request_rate = current_metrics.get("request_rate") if _finite(current_metrics.get("request_rate")) else None
    return baseline_p95, baseline_request_rate


def classify_state(metrics, baseline_p95, baseline_request_rate):
    error_rate = metrics.get("error_rate")
    p95_latency_ms = metrics.get("p95_latency_ms")
    request_rate = metrics.get("request_rate")
    p95_ratio = safe_ratio(p95_latency_ms, baseline_p95)
    request_surge_ratio = safe_ratio(request_rate, baseline_request_rate)

    matched_high = []
    matched_medium = []

    if error_rate is not None and error_rate >= THRESHOLDS["error_rate"]["high"]:
        matched_high.append("error_rate")
    elif error_rate is not None and error_rate >= THRESHOLDS["error_rate"]["medium"]:
        matched_medium.append("error_rate")

    if p95_ratio is not None and p95_ratio >= THRESHOLDS["p95_ratio"]["high"]:
        matched_high.append("p95_ratio")
    elif p95_ratio is not None and p95_ratio >= THRESHOLDS["p95_ratio"]["medium"]:
        matched_medium.append("p95_ratio")

    if request_surge_ratio is not None and request_surge_ratio >= THRESHOLDS["request_surge_ratio"]["high"]:
        matched_high.append("request_surge_ratio")
    elif request_surge_ratio is not None and request_surge_ratio >= THRESHOLDS["request_surge_ratio"]["medium"]:
        matched_medium.append("request_surge_ratio")

    if matched_high:
        level = "high"
        reasons = matched_high
    elif matched_medium:
        level = "medium"
        reasons = matched_medium
    else:
        level = "low"
        reasons = []

    return {
        "level": level,
        "reasons": reasons,
        "p95_ratio": p95_ratio,
        "request_surge_ratio": request_surge_ratio,
    }


def render_config(namespace, profile_name, budget_label):
    profile = PROFILES[profile_name]
    return f"""apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-collector-config
  labels:
    sampling.policy: my_policy
    sampling.budget: {budget_label}
    sampling.mode: volatility_controller
    sampling.profile: {profile_name}
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc:
          http:
    processors:
      tail_sampling:
        decision_wait: 10s
        num_traces: {profile['num_traces']}
        expected_new_traces_per_sec: {profile['expected_new_traces_per_sec']}
        policies:
          - name: error-traces
            type: status_code
            status_code:
              status_codes: [ERROR]
          - name: high-latency
            type: latency
            latency:
              threshold_ms: {profile['latency_threshold_ms']}
          - name: fallback-probability
            type: probabilistic
            probabilistic:
              sampling_percentage: {profile['fallback_sampling_percentage']}
      batch:
        timeout: 1s
    exporters:
      otlp/jaeger:
        endpoint: jaeger-collector.{namespace}.svc.cluster.local:4317
        tls:
          insecure: true
      prometheus:
        endpoint: 0.0.0.0:8889
    service:
      telemetry:
        metrics:
          address: 0.0.0.0:8888
      pipelines:
        traces:
          receivers: [otlp]
          processors: [tail_sampling, batch]
          exporters: [otlp/jaeger]
"""


def apply_profile(namespace, collector_deployment, rollout_timeout_seconds, budget_label, profile_name, config_history_dir):
    rendered = render_config(namespace, profile_name, budget_label)
    timestamp = time.strftime("%Y%m%d_%H%M%S", time.gmtime())
    snapshot_path = config_history_dir / f"{timestamp}_{profile_name}.yaml"
    snapshot_path.write_text(rendered, encoding="utf-8")
    run_command(["kubectl", "apply", "-n", namespace, "-f", "-"], input_text=rendered)
    run_command(["kubectl", "-n", namespace, "rollout", "restart", f"deployment/{collector_deployment}"])
    run_command(
        [
            "kubectl",
            "-n",
            namespace,
            "rollout",
            "status",
            f"deployment/{collector_deployment}",
            f"--timeout={rollout_timeout_seconds}s",
        ]
    )
    return snapshot_path


def write_event(events_path, event):
    with events_path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(event, ensure_ascii=True) + "\n")


def write_summary(summary_path, summary):
    summary_path.write_text(json.dumps(summary, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Volatility-driven tail-sampling parameter controller.")
    parser.add_argument("--prometheus-url", required=True)
    parser.add_argument("--app-namespace", required=True)
    parser.add_argument("--obs-namespace", required=True)
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--poll-interval-seconds", type=int, default=30)
    parser.add_argument("--window-seconds", type=int, default=120)
    parser.add_argument("--warmup-seconds", type=int, default=60)
    parser.add_argument("--collector-deployment", default="otel-collector")
    parser.add_argument("--initial-profile", choices=sorted(PROFILES), default="balanced")
    parser.add_argument("--budget-label", default="mid")
    parser.add_argument("--start-epoch-ms", type=int, default=0)
    parser.add_argument("--rollout-timeout-seconds", type=int, default=240)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    config_history_dir = output_dir / "collector_config_history"
    raw_metrics_dir = output_dir / "metrics_raw"
    config_history_dir.mkdir(parents=True, exist_ok=True)
    raw_metrics_dir.mkdir(parents=True, exist_ok=True)
    events_path = output_dir / "controller_events.jsonl"
    summary_path = output_dir / "controller_summary.json"

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    queries = build_queries(args.app_namespace, args.window_seconds)
    warmup_end_ms = args.start_epoch_ms + (args.warmup_seconds * 1000)
    warmup_samples = []
    baseline_p95 = None
    baseline_request_rate = None
    current_profile = args.initial_profile
    current_level = "warmup"
    level_counts = {"warmup": 0, "low": 0, "medium": 0, "high": 0}
    restart_count = 0
    iteration = 0
    last_event = None
    cooldown_until_iteration = 0  # skip classification for 1 poll after profile change

    summary = {
        "enabled": True,
        "status": "running",
        "poll_interval_seconds": args.poll_interval_seconds,
        "window_seconds": args.window_seconds,
        "warmup_seconds": args.warmup_seconds,
        "initial_profile": args.initial_profile,
        "current_profile": current_profile,
        "last_level": current_level,
        "level_counts": level_counts,
        "restart_count": restart_count,
        "thresholds": THRESHOLDS,
        "profiles": PROFILES,
        "baseline": {
            "p95_latency_ms": baseline_p95,
            "request_rate": baseline_request_rate,
        },
        "queries": queries,
        "last_event": last_event,
    }
    write_summary(summary_path, summary)

    while not STOP:
        iteration += 1
        iteration_started = time.time()
        timestamp_ms = now_epoch_ms()
        event = {
            "timestamp": iso_timestamp(),
            "timestamp_epoch_ms": timestamp_ms,
            "iteration": iteration,
            "action": "noop",
            "level": current_level,
            "profile": current_profile,
            "metrics": {},
            "baseline": {
                "p95_latency_ms": baseline_p95,
                "request_rate": baseline_request_rate,
            },
            "reasons": [],
            "config_snapshot": None,
            "error": None,
        }

        try:
            metrics, raw_docs = collect_metrics(args.prometheus_url, queries)
            event["metrics"] = metrics
            for name, raw_doc in raw_docs.items():
                raw_path = raw_metrics_dir / f"{iteration:04d}_{name}.json"
                raw_path.write_text(json.dumps(raw_doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
        except Exception as exc:
            event["action"] = "metrics_query_failed"
            event["error"] = str(exc)
            write_event(events_path, event)
            last_event = event
            summary.update(
                {
                    "status": "running",
                    "current_profile": current_profile,
                    "last_level": current_level,
                    "level_counts": level_counts,
                    "restart_count": restart_count,
                    "baseline": {
                        "p95_latency_ms": baseline_p95,
                        "request_rate": baseline_request_rate,
                    },
                    "last_event": last_event,
                }
            )
            write_summary(summary_path, summary)
            sleep_for = max(1, args.poll_interval_seconds - int(time.time() - iteration_started))
            time.sleep(sleep_for)
            continue

        if timestamp_ms < warmup_end_ms:
            warmup_samples.append(metrics)
            current_level = "warmup"
            event["level"] = current_level
            event["action"] = "warmup_observe"
            event["reasons"] = ["warmup"]
            level_counts["warmup"] += 1
        else:
            if baseline_p95 is None or baseline_request_rate is None:
                baseline_p95, baseline_request_rate = compute_baselines(warmup_samples, metrics)
            event["baseline"] = {
                "p95_latency_ms": baseline_p95,
                "request_rate": baseline_request_rate,
            }
            if all(metrics.get(name) is None for name in ("p95_latency_ms", "error_rate", "request_rate")):
                event["action"] = "metrics_missing"
                event["level"] = current_level
                event["profile"] = current_profile
            elif iteration <= cooldown_until_iteration:
                # Skip classification during cooldown after profile change.
                # OTel collector restart takes ~30-60s; metrics during this
                # window are noisy and can cause false triggers.
                event["action"] = "cooldown_after_restart"
                event["level"] = current_level
                event["profile"] = current_profile
            else:
                classification = classify_state(metrics, baseline_p95, baseline_request_rate)
                current_level = classification["level"]
                desired_profile = PROFILE_BY_LEVEL[current_level]
                event["level"] = current_level
                event["reasons"] = classification["reasons"]
                event["ratios"] = {
                    "p95_ratio": classification["p95_ratio"],
                    "request_surge_ratio": classification["request_surge_ratio"],
                }
                level_counts[current_level] += 1

                if desired_profile != current_profile:
                    try:
                        snapshot_path = apply_profile(
                            args.obs_namespace,
                            args.collector_deployment,
                            args.rollout_timeout_seconds,
                            args.budget_label,
                            desired_profile,
                            config_history_dir,
                        )
                        current_profile = desired_profile
                        restart_count += 1
                        event["action"] = "profile_changed"
                        event["profile"] = current_profile
                        event["config_snapshot"] = str(snapshot_path)
                        # Cooldown: skip next poll's classification to let
                        # OTel collector stabilize after restart.
                        cooldown_until_iteration = iteration + 1
                    except subprocess.CalledProcessError as exc:
                        event["action"] = "profile_change_failed"
                        event["error"] = exc.stderr or exc.stdout or str(exc)
                else:
                    event["action"] = "level_unchanged"
                    event["profile"] = current_profile

        write_event(events_path, event)
        last_event = event
        summary.update(
            {
                "status": "running",
                "current_profile": current_profile,
                "last_level": current_level,
                "level_counts": level_counts,
                "restart_count": restart_count,
                "baseline": {
                    "p95_latency_ms": baseline_p95,
                    "request_rate": baseline_request_rate,
                },
                "last_event": last_event,
            }
        )
        write_summary(summary_path, summary)
        sleep_for = max(1, args.poll_interval_seconds - int(time.time() - iteration_started))
        time.sleep(sleep_for)

    summary.update(
        {
            "status": "stopped",
            "stopped_at": iso_timestamp(),
            "current_profile": current_profile,
            "last_level": current_level,
            "level_counts": level_counts,
            "restart_count": restart_count,
            "baseline": {
                "p95_latency_ms": baseline_p95,
                "request_rate": baseline_request_rate,
            },
            "last_event": last_event,
        }
    )
    write_summary(summary_path, summary)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
