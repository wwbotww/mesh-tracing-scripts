#!/usr/bin/env python3
import argparse
import json
import math
from collections import defaultdict
from pathlib import Path

EPSILON = 1e-6
N_MIN = 20


def normalize_service(value):
    if not value:
        return None
    value = str(value).strip()
    if not value:
        return None
    return value.split(".", 1)[0]


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def percentile(values, q):
    if not values:
        return 0.0
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(q * len(ordered)) - 1))
    return float(ordered[index])


def tag_map(span):
    result = {}
    for item in span.get("tags", []):
        key = item.get("key")
        if key:
            result[key] = item.get("value")
    return result


def is_error_span(tags):
    if str(tags.get("error", "")).lower() in {"true", "1", "yes"}:
        return True
    for key in ("http.status_code",):
        if key in tags:
            try:
                if int(tags[key]) >= 500:
                    return True
            except (TypeError, ValueError):
                pass
    for key in ("grpc.status_code", "rpc.grpc.status_code"):
        if key in tags:
            value = str(tags[key]).strip().upper()
            if value not in {"0", "OK", ""}:
                return True
    if str(tags.get("otel.status_code", "")).upper() == "ERROR":
        return True
    if str(tags.get("status.code", "")).upper() == "ERROR":
        return True
    return False


def span_service(trace, span):
    tags = tag_map(span)
    for key in ("istio.canonical_service", "service.name"):
        if key in tags:
            value = normalize_service(tags[key])
            if value:
                return value
    process = trace.get("processes", {}).get(span.get("processID"), {})
    value = normalize_service(process.get("serviceName"))
    if value:
        return value
    return None


def extract_edges(trace_doc):
    traces = trace_doc.get("data", []) if isinstance(trace_doc, dict) else []
    aggregated = defaultdict(lambda: {"count": 0, "error_count": 0, "durations_ms": []})
    for trace in traces:
        spans = trace.get("spans", [])
        by_id = {span.get("spanID"): span for span in spans if span.get("spanID")}
        for child in spans:
            child_service = span_service(trace, child)
            if not child_service:
                continue
            parent_id = None
            for ref in child.get("references", []):
                if ref.get("refType") == "CHILD_OF" and ref.get("spanID") in by_id:
                    parent_id = ref.get("spanID")
                    break
            if not parent_id:
                continue
            parent = by_id[parent_id]
            parent_service = span_service(trace, parent)
            if not parent_service:
                continue
            if parent_service == child_service:
                continue  # Skip self-loop edges (Istio inbound/outbound spans on same service)
            edge = f"{parent_service}->{child_service}"
            duration_ms = float(child.get("duration", 0) or 0) / 1000.0
            # Check BOTH parent and child spans for errors. Istio VirtualService
            # fault injection (abort) creates errors at the destination sidecar;
            # the error tag appears on the caller's (parent) span response, not
            # necessarily on the callee's (child) span.
            child_tags = tag_map(child)
            parent_tags = tag_map(parent)
            edge_has_error = is_error_span(child_tags) or is_error_span(parent_tags)
            aggregated[edge]["count"] += 1
            aggregated[edge]["error_count"] += 1 if edge_has_error else 0
            aggregated[edge]["durations_ms"].append(duration_ms)
    return traces, aggregated


def finalize_edge_stats(raw_stats):
    finalized = {}
    for edge, stats in raw_stats.items():
        count = int(stats["count"])
        error_count = int(stats["error_count"])
        finalized[edge] = {
            "count": count,
            "error_rate": (error_count / count) if count else 0.0,
            "p95_latency_ms": percentile(stats["durations_ms"], 0.95),
        }
    return finalized


def score_latency(current_latency, reference_latency):
    return min(1.0, max(0.0, (current_latency - reference_latency) / (reference_latency + EPSILON)))


def score_error(current_error_rate, reference_error_rate):
    return max(0.0, current_error_rate - reference_error_rate)


def score_missing(current_count, reference_count, trace_ratio=1.0):
    """Score how many spans are 'missing' on this edge relative to expectation.

    trace_ratio = len(current_traces) / len(reference_traces) normalises for
    different sampling rates so that the score reflects genuinely absent spans
    (e.g. Istio abort dropping callee spans) rather than lower sample volume.
    """
    if reference_count < N_MIN:
        return 0.0
    expected = reference_count * trace_ratio
    if expected < 5:          # too few expected observations to be meaningful
        return 0.0
    return max(0.0, (expected - current_count) / (expected + EPSILON))


def write_json(path, doc):
    Path(path).write_text(json.dumps(doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def extract_ground_truth(context):
    fault = context.get("fault", {})
    target_type = fault.get("target_type")
    target = fault.get("target")
    source_service = normalize_service(fault.get("source_service"))
    target_service = normalize_service(fault.get("target_service"))
    edge_target = None
    service_target = None

    if target_type == "edge" and source_service and target_service:
        edge_target = f"{source_service}->{target_service}"
        service_target = target_service
    elif target_type == "service":
        if target_service:
            service_target = target_service
        elif isinstance(target, str) and target.startswith("service="):
            service_target = normalize_service(target.split("=", 1)[1])

    return {
        "target_type": target_type,
        "target": target,
        "source_service": source_service,
        "target_service": target_service,
        "edge": edge_target,
        "service": service_target,
    }


def build_empty_result(run_id, reference_run_id, ground_truth, status, reason):
    return {
        "run_id": run_id,
        "reference_run_id": reference_run_id,
        "ground_truth": ground_truth,
        "scoring_method": "simple_edge_weighted_sum_v1",
        "edge_ranking": [],
        "service_ranking": [],
        "edge_top1_hit": None,
        "edge_top3_hit": None,
        "service_top1_hit": None,
        "service_top3_hit": None,
        "status": status,
        "reason": reason,
    }


def main():
    parser = argparse.ArgumentParser(description="Compute simple edge-aware RCA ranking.")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--current-traces", required=True)
    parser.add_argument("--reference-traces")
    parser.add_argument("--reference-run-id", default=None)
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    utility_dir = run_dir / "utility"
    features_path = utility_dir / "rca_features.json"
    ranking_path = utility_dir / "rca_ranking.json"

    context = load_json(run_dir / "run_context.json")
    run_id = context.get("run_id")
    ground_truth = extract_ground_truth(context)
    current_policy = ((context.get("policy") or {}).get("canonical"))

    if current_policy == "reference":
        write_json(features_path, {"run_id": run_id, "status": "not_applicable", "reason": "current_policy_is_reference", "edges": []})
        write_json(ranking_path, build_empty_result(run_id, None, ground_truth, "not_applicable", "current_policy_is_reference"))
        return

    if not args.reference_traces:
        write_json(features_path, {"run_id": run_id, "status": "insufficient_data", "reason": "reference_missing", "edges": []})
        write_json(ranking_path, build_empty_result(run_id, None, ground_truth, "insufficient_data", "reference_missing"))
        return

    current_doc = load_json(args.current_traces)
    reference_doc = load_json(args.reference_traces)
    current_traces, current_raw_stats = extract_edges(current_doc)
    reference_traces, reference_raw_stats = extract_edges(reference_doc)

    if len(current_traces) < 10:
        write_json(features_path, {"run_id": run_id, "status": "insufficient_data", "reason": "too_few_traces", "edges": []})
        write_json(ranking_path, build_empty_result(run_id, args.reference_run_id, ground_truth, "insufficient_data", "too_few_traces"))
        return

    if len(reference_traces) < 10:
        write_json(features_path, {"run_id": run_id, "status": "insufficient_data", "reason": "too_few_reference_traces", "edges": []})
        write_json(ranking_path, build_empty_result(run_id, args.reference_run_id, ground_truth, "insufficient_data", "too_few_reference_traces"))
        return

    current_stats = finalize_edge_stats(current_raw_stats)
    reference_stats = finalize_edge_stats(reference_raw_stats)

    supported_edges = [edge for edge, stats in reference_stats.items() if stats["count"] >= N_MIN]
    if not supported_edges:
        write_json(features_path, {"run_id": run_id, "status": "insufficient_data", "reason": "no_supported_edges", "edges": []})
        write_json(ranking_path, build_empty_result(run_id, args.reference_run_id, ground_truth, "insufficient_data", "no_supported_edges"))
        return

    # Normalise for sampling-rate difference between current and reference runs.
    trace_ratio = len(current_traces) / max(len(reference_traces), 1)

    W_LAT, W_ERR, W_MISS = 0.5, 0.3, 0.2

    edge_features = []
    service_scores = defaultdict(list)
    for edge, ref in reference_stats.items():
        cur = current_stats.get(edge, {"count": 0, "error_rate": 0.0, "p95_latency_ms": 0.0})
        lat_score = score_latency(cur["p95_latency_ms"], ref["p95_latency_ms"])
        err_score = score_error(cur["error_rate"], ref["error_rate"])
        miss_score = score_missing(cur["count"], ref["count"], trace_ratio)
        total_score = W_LAT * lat_score + W_ERR * err_score + W_MISS * miss_score
        caller, callee = edge.split("->", 1)
        feature = {
            "edge": edge,
            "caller_service": caller,
            "callee_service": callee,
            "count_cur": cur["count"],
            "count_ref": ref["count"],
            "error_rate_cur": cur["error_rate"],
            "error_rate_ref": ref["error_rate"],
            "p95_latency_cur_ms": cur["p95_latency_ms"],
            "p95_latency_ref_ms": ref["p95_latency_ms"],
            "score_latency": lat_score,
            "score_error": err_score,
            "score_missing": miss_score,
            "score_total": total_score,
        }
        edge_features.append(feature)
        service_scores[caller].append(feature)
        service_scores[callee].append(feature)

    edge_ranking = sorted(
        edge_features,
        key=lambda item: (
            -item["score_total"],
            -item["score_error"],
            -item["score_latency"],
            -item["count_ref"],
            item["edge"],
        ),
    )

    service_ranking = []
    for service, features in service_scores.items():
        top_feature = sorted(
            features,
            key=lambda item: (-item["score_total"], -item["score_error"], item["edge"]),
        )[0]
        service_ranking.append(
            {
                "service": service,
                "score_total": top_feature["score_total"],
                "max_score_error": top_feature["score_error"],
                "supporting_edge": top_feature["edge"],
            }
        )
    service_ranking.sort(key=lambda item: (-item["score_total"], -item["max_score_error"], item["service"]))

    edge_names = [item["edge"] for item in edge_ranking]
    service_names = [item["service"] for item in service_ranking]
    ground_truth_edge = ground_truth.get("edge")
    ground_truth_service = ground_truth.get("service")
    target_type = ground_truth.get("target_type")

    edge_top1_hit = None
    edge_top3_hit = None
    service_top1_hit = None
    service_top3_hit = None

    if target_type == "edge" and ground_truth_edge:
        edge_top1_hit = edge_names[:1] == [ground_truth_edge]
        edge_top3_hit = ground_truth_edge in edge_names[:3]
        if ground_truth_service:
            service_top1_hit = service_names[:1] == [ground_truth_service]
            service_top3_hit = ground_truth_service in service_names[:3]
    elif target_type == "service" and ground_truth_service:
        service_top1_hit = service_names[:1] == [ground_truth_service]
        service_top3_hit = ground_truth_service in service_names[:3]

    features_doc = {
        "run_id": run_id,
        "reference_run_id": args.reference_run_id,
        "status": "ok",
        "reason": None,
        "trace_counts": {
            "current": len(current_traces),
            "reference": len(reference_traces),
        },
        "constants": {
            "epsilon": EPSILON,
            "n_min": N_MIN,
            "trace_ratio": trace_ratio,
            "score_weights": {
                "latency": W_LAT,
                "error": W_ERR,
                "missing": W_MISS,
            },
        },
        "edges": edge_ranking,
    }

    ranking_doc = {
        "run_id": run_id,
        "reference_run_id": args.reference_run_id,
        "ground_truth": ground_truth,
        "scoring_method": "S_edge=0.5*S_lat+0.3*S_err+0.2*S_miss",
        "edge_ranking": edge_ranking,
        "service_ranking": service_ranking,
        "edge_top1_hit": edge_top1_hit,
        "edge_top3_hit": edge_top3_hit,
        "service_top1_hit": service_top1_hit,
        "service_top3_hit": service_top3_hit,
        "status": "ok",
        "reason": None,
    }

    write_json(features_path, features_doc)
    write_json(ranking_path, ranking_doc)


if __name__ == "__main__":
    main()
