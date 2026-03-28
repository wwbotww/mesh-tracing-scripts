#!/usr/bin/env python3
import argparse
import json
from collections import Counter, defaultdict
from pathlib import Path

SUPPORT_THRESHOLD = 0.1
MIN_TRACE_COUNT = 10


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path, doc):
    Path(path).write_text(json.dumps(doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")


def normalize_service(value):
    if not value:
        return None
    value = str(value).strip()
    if not value:
        return None
    return value.split(".", 1)[0]


def tag_map(span):
    result = {}
    for item in span.get("tags", []):
        key = item.get("key")
        if key:
            result[key] = item.get("value")
    return result


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


def build_span_graph(trace):
    spans = trace.get("spans", [])
    by_id = {span.get("spanID"): span for span in spans if span.get("spanID")}
    children = defaultdict(list)
    indegree = defaultdict(int)

    for span_id in by_id:
        indegree.setdefault(span_id, 0)

    for child in spans:
        child_id = child.get("spanID")
        if not child_id:
            continue
        for ref in child.get("references", []):
            if ref.get("refType") == "CHILD_OF" and ref.get("spanID") in by_id:
                parent_id = ref.get("spanID")
                children[parent_id].append(child_id)
                indegree[child_id] += 1
                break
    return by_id, children, indegree


def span_duration_ms(span):
    return float(span.get("duration", 0) or 0) / 1000.0


def trace_topological_order(span_ids, children, indegree):
    queue = sorted([span_id for span_id in span_ids if indegree.get(span_id, 0) == 0])
    order = []
    local_indegree = dict(indegree)
    while queue:
        current = queue.pop(0)
        order.append(current)
        for child in children.get(current, []):
            local_indegree[child] = local_indegree.get(child, 0) - 1
            if local_indegree[child] == 0:
                queue.append(child)
                queue.sort()
    if len(order) != len(span_ids):
        # Fallback: preserve deterministic order even if the graph is malformed.
        remaining = [span_id for span_id in span_ids if span_id not in order]
        order.extend(sorted(remaining))
    return order


def longest_span_path(trace):
    by_id, children, indegree = build_span_graph(trace)
    if not by_id:
        return []

    order = trace_topological_order(list(by_id.keys()), children, indegree)
    best_score = {}
    predecessor = {}

    for span_id in order:
        current_span = by_id[span_id]
        current_weight = span_duration_ms(current_span)
        current_best = best_score.get(span_id, current_weight)
        best_score[span_id] = current_best

        for child_id in children.get(span_id, []):
            child_weight = span_duration_ms(by_id[child_id])
            candidate = current_best + child_weight
            if candidate > best_score.get(child_id, float("-inf")):
                best_score[child_id] = candidate
                predecessor[child_id] = span_id

    end_span = max(order, key=lambda span_id: (best_score.get(span_id, 0.0), span_id))
    path = [end_span]
    while end_span in predecessor:
        end_span = predecessor[end_span]
        path.append(end_span)
    path.reverse()
    return [by_id[span_id] for span_id in path]


def compress_services(trace, span_path):
    services = []
    for span in span_path:
        service = span_service(trace, span)
        if not service:
            continue
        if not services or services[-1] != service:
            services.append(service)
    return services


def service_edges_from_services(services):
    edges = []
    for idx in range(len(services) - 1):
        src = services[idx]
        dst = services[idx + 1]
        if not src or not dst or src == dst:
            continue
        edges.append(f"{src}->{dst}")
    return edges


def extract_critical_path_edges(trace_doc):
    traces = trace_doc.get("data", []) if isinstance(trace_doc, dict) else []
    edge_counter = Counter()
    path_edge_lists = []
    traces_with_paths = 0

    for trace in traces:
        span_path = longest_span_path(trace)
        if not span_path:
            continue
        services = compress_services(trace, span_path)
        edges = service_edges_from_services(services)
        if not edges:
            continue
        traces_with_paths += 1
        unique_edges = []
        seen = set()
        for edge in edges:
            if edge not in seen:
                seen.add(edge)
                unique_edges.append(edge)
        for edge in unique_edges:
            edge_counter[edge] += 1
        path_edge_lists.append(unique_edges)

    support_map = {}
    if traces_with_paths > 0:
        for edge, count in edge_counter.items():
            support_map[edge] = {
                "support_count": count,
                "support_ratio": count / traces_with_paths,
            }

    selected_edges = sorted(
        [edge for edge, data in support_map.items() if data["support_ratio"] >= SUPPORT_THRESHOLD]
    )

    return {
        "trace_count_total": len(traces),
        "trace_count_used": traces_with_paths,
        "edge_support": support_map,
        "critical_edges": selected_edges,
        "trace_paths": path_edge_lists,
    }


def build_empty_doc(run_id, reference_run_id, status, reason):
    return {
        "run_id": run_id,
        "reference_run_id": reference_run_id,
        "method": "run_level_critical_edge_set_jaccard_v1",
        "trace_counts": {
            "current_total": 0,
            "current_used": 0,
            "reference_total": 0,
            "reference_used": 0,
        },
        "support_threshold": SUPPORT_THRESHOLD,
        "critical_path_edges": [],
        "reference_edges": [],
        "current_edge_support": {},
        "reference_edge_support": {},
        "intersection_edges": [],
        "union_edges": [],
        "jaccard": None,
        "precision": None,
        "recall": None,
        "status": status,
        "reason": reason,
    }


def main():
    parser = argparse.ArgumentParser(description="Compute critical path fidelity from current/reference traces.")
    parser.add_argument("--run-dir", required=True)
    parser.add_argument("--current-traces", required=True)
    parser.add_argument("--reference-traces")
    parser.add_argument("--reference-run-id", default=None)
    args = parser.parse_args()

    run_dir = Path(args.run_dir)
    context = load_json(run_dir / "run_context.json")
    run_id = context.get("run_id")
    current_policy = ((context.get("policy") or {}).get("canonical"))
    output_path = run_dir / "utility" / "critical_path.json"

    if current_policy == "reference":
        write_json(output_path, build_empty_doc(run_id, None, "not_applicable", "current_policy_is_reference"))
        return

    if not args.reference_traces:
        write_json(output_path, build_empty_doc(run_id, None, "insufficient_data", "reference_missing"))
        return

    current_doc = load_json(args.current_traces)
    reference_doc = load_json(args.reference_traces)
    current_data = extract_critical_path_edges(current_doc)
    reference_data = extract_critical_path_edges(reference_doc)

    if current_data["trace_count_total"] < MIN_TRACE_COUNT:
        write_json(output_path, build_empty_doc(run_id, args.reference_run_id, "insufficient_data", "too_few_traces"))
        return

    if reference_data["trace_count_total"] < MIN_TRACE_COUNT:
        write_json(output_path, build_empty_doc(run_id, args.reference_run_id, "insufficient_data", "too_few_reference_traces"))
        return

    if not current_data["critical_edges"] or not reference_data["critical_edges"]:
        write_json(output_path, build_empty_doc(run_id, args.reference_run_id, "insufficient_data", "no_critical_edges"))
        return

    current_set = set(current_data["critical_edges"])
    reference_set = set(reference_data["critical_edges"])
    intersection = sorted(current_set & reference_set)
    union = sorted(current_set | reference_set)

    doc = {
        "run_id": run_id,
        "reference_run_id": args.reference_run_id,
        "method": "run_level_critical_edge_set_jaccard_v1",
        "trace_counts": {
            "current_total": current_data["trace_count_total"],
            "current_used": current_data["trace_count_used"],
            "reference_total": reference_data["trace_count_total"],
            "reference_used": reference_data["trace_count_used"],
        },
        "support_threshold": SUPPORT_THRESHOLD,
        "critical_path_edges": current_data["critical_edges"],
        "reference_edges": reference_data["critical_edges"],
        "current_edge_support": current_data["edge_support"],
        "reference_edge_support": reference_data["edge_support"],
        "intersection_edges": intersection,
        "union_edges": union,
        "jaccard": (len(intersection) / len(union)) if union else None,
        "precision": (len(intersection) / len(current_set)) if current_set else None,
        "recall": (len(intersection) / len(reference_set)) if reference_set else None,
        "status": "ok",
        "reason": None,
    }
    write_json(output_path, doc)


if __name__ == "__main__":
    main()
