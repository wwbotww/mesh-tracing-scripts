#!/usr/bin/env python3
"""
Pareto Analysis / Frontier Visualization for Mesh Tracing Sampling Experiments.

Generates four figures, each conveying one clear conclusion:

  1. rca_tradeoff_delay   — Adaptive sampling Pareto-dominates tail at mid/high budgets
  2. rca_tradeoff_abort   — Mixed cost-utility trade-off under abort faults (tail/low optimal)
  3. top3_hit_heatmap     — RCA Top-3 hit/miss across all (policy, budget, fault) combos
  4. top5_hit_heatmap     — RCA Top-5 hit/miss across all (policy, budget, fault) combos
  5. critical_path_nofault — All strategies preserve critical-path fidelity at vastly
                             different costs

Usage:
    python3 scripts/plot_pareto.py \\
        --matrix-dir results/matrix_runs/matrix_20260328_022053 \\
        --output-dir results/figures
"""

import argparse
import json
import pathlib
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.lines as mlines
import numpy as np


# ---------------------------------------------------------------------------
# Visual encoding (consistent across ALL figures)
#   policy  → colour (only)
#   budget  → marker shape (only)
# ---------------------------------------------------------------------------

POLICY_COLOR = {
    "head":      "#2196F3",
    "tail":      "#F44336",
    "my_policy": "#4CAF50",
}
POLICY_LABEL = {
    "head":      "head",
    "tail":      "tail",
    "my_policy": "adaptive (ours)",
}

BUDGET_MARKER = {"low": "o", "mid": "^", "high": "s"}
BUDGET_LABEL  = {"low": "low", "mid": "mid", "high": "high"}

MARKER_SIZE = 90

TARGET_SERVICE = "productcatalogservice"


# ---------------------------------------------------------------------------
# Data loading  (unchanged from original)
# ---------------------------------------------------------------------------

def load_run(run_dir: pathlib.Path) -> dict | None:
    summary_path = run_dir / "summary.json"
    if not summary_path.exists():
        return None
    try:
        with open(summary_path) as f:
            s = json.load(f)
    except Exception as e:
        print(f"  [warn] cannot read {summary_path}: {e}", file=sys.stderr)
        return None

    policy = s.get("policy", {}).get("canonical", "")
    if policy == "reference":
        return None

    budget = s.get("policy", {}).get("budget_canonical", "")
    fault_type = s.get("fault", {}).get("type", "none")

    tv = s.get("cost_metrics", {}).get("trace_volume", {})
    sr = tv.get("effective_sampling_ratio")
    if sr is None:
        return None

    rca = s.get("utility_metrics", {}).get("rca_topk", {})
    target_score = _get_target_score(rca)
    t3_hit = rca.get("service_top3_hit")
    t5_hit = rca.get("service_top5_hit")

    # Fallback: if summary.json was generated before compute_rca.py gained top5,
    # read the field directly from the per-run rca_ranking.json on disk.
    if t5_hit is None and t3_hit is not None:
        rca_ranking_path = run_dir / "utility" / "rca_ranking.json"
        if rca_ranking_path.exists():
            try:
                with open(rca_ranking_path) as rf:
                    rca_disk = json.load(rf)
                t5_hit = rca_disk.get("service_top5_hit")
            except Exception:
                pass

    cpf = s.get("utility_metrics", {}).get("critical_path_fidelity", {})
    jaccard = cpf.get("jaccard")

    return {
        "run_id": s.get("run_id", ""),
        "policy": policy,
        "budget": budget,
        "fault_type": fault_type,
        "sampling_ratio": sr,
        "target_score": target_score,
        "t3_hit": t3_hit,
        "t5_hit": t5_hit,
        "jaccard": jaccard,
    }


def _get_target_score(rca: dict) -> float | None:
    ranking = rca.get("service_ranking", [])
    for entry in ranking:
        if entry.get("service") == TARGET_SERVICE:
            return entry.get("score_total")
    return None


def load_matrix_data(matrix_dir: pathlib.Path) -> list[dict]:
    summary_path = matrix_dir / "matrix_summary.json"
    if not summary_path.exists():
        sys.exit(f"[error] {summary_path} not found")

    with open(summary_path) as f:
        msummary = json.load(f)

    results_root = matrix_dir.parent.parent
    runs_root = results_root / "runs"

    records = []
    for run_entry in msummary.get("runs", []):
        run_id = run_entry.get("run_id")
        if not run_id:
            continue
        rec = load_run(runs_root / run_id)
        if rec:
            records.append(rec)

    print(f"Loaded {len(records)} runs (excluding reference policy)")
    return records


# ---------------------------------------------------------------------------
# Pareto frontier
# ---------------------------------------------------------------------------

def compute_pareto_frontier(points: list[tuple[float, float]]) -> set[int]:
    """Return indices of Pareto-optimal points (minimise cost, maximise utility).

    A point is Pareto-optimal if no other point has both lower-or-equal cost
    AND higher-or-equal utility (with at least one strictly better).
    """
    if not points:
        return set()
    n = len(points)
    optimal = set(range(n))
    for i in range(n):
        if i not in optimal:
            continue
        for j in list(optimal):
            if i == j:
                continue
            ci, ui = points[i]
            cj, uj = points[j]
            if ci <= cj and ui >= uj and (ci < cj or ui > uj):
                optimal.discard(j)
    return optimal


# ---------------------------------------------------------------------------
# Shared legend builders
# ---------------------------------------------------------------------------

def _policy_handles():
    return [
        mpatches.Patch(facecolor=POLICY_COLOR[p], label=POLICY_LABEL[p])
        for p in ("head", "tail", "my_policy")
    ]


def _budget_handles():
    return [
        mlines.Line2D([], [], color="grey", marker=BUDGET_MARKER[b],
                       linestyle="None", markersize=8,
                       label=f"budget = {BUDGET_LABEL[b]}")
        for b in ("low", "mid", "high")
    ]


def _pareto_handle():
    return mlines.Line2D([], [], color="black", marker="o", linestyle="None",
                          markersize=6, markeredgewidth=2, markerfacecolor="none",
                          label="Pareto-optimal")


# ---------------------------------------------------------------------------
# Figure: RCA tradeoff scatter (one per fault type)
# ---------------------------------------------------------------------------

def plot_rca_tradeoff(records: list[dict], fault_type: str,
                      output_dir: pathlib.Path):
    """One clean scatter per fault scenario: cost vs RCA target score."""
    subset = [r for r in records if r["fault_type"] == fault_type]
    if not subset:
        return

    fig, ax = plt.subplots(figsize=(7, 5))

    fault_desc = {"delay": "delay (250 ms / 50%)",
                  "abort": "abort (HTTP 500 / 20%)"}
    titles = {
        "delay": "Adaptive sampling Pareto-dominates tail at mid/high budgets",
        "abort": "Mixed cost-utility trade-off under abort faults",
    }
    ax.set_title(
        f"{titles.get(fault_type, fault_type)}\nFault: {fault_desc.get(fault_type, fault_type)}",
        fontsize=13, fontweight="bold", pad=10,
    )

    # Collect (cost, utility) for Pareto computation
    pts: list[tuple[float, float]] = []
    meta: list[dict] = []
    for rec in subset:
        x, y = rec["sampling_ratio"], rec.get("target_score")
        if x is None or y is None:
            continue
        pts.append((x, y))
        meta.append(rec)

    pareto_idx = compute_pareto_frontier(pts)

    for i, (rec, (x, y)) in enumerate(zip(meta, pts)):
        color = POLICY_COLOR.get(rec["policy"], "grey")
        marker = BUDGET_MARKER.get(rec["budget"], "o")
        is_pareto = i in pareto_idx

        ax.scatter(x, y, color=color, marker=marker, s=MARKER_SIZE,
                   edgecolors="black" if is_pareto else "white",
                   linewidths=2.0 if is_pareto else 0.6,
                   zorder=4 if is_pareto else 3, alpha=0.95)

    ax.set_xlabel("Effective Sampling Ratio (lower = cheaper)", fontsize=11)
    ax.set_ylabel("RCA Target Score (higher = better fault localization)",
                  fontsize=11)
    ax.set_xlim(left=0)
    ax.grid(True, alpha=0.25, linewidth=0.5)

    handles = _policy_handles() + _budget_handles() + [_pareto_handle()]
    ax.legend(handles=handles, loc="upper left", bbox_to_anchor=(1.02, 1),
              fontsize=8, framealpha=0.9, borderaxespad=0)
    fig.tight_layout()
    _save(fig, output_dir, f"rca_tradeoff_{fault_type}")


# ---------------------------------------------------------------------------
# Figure: Top-k hit heatmap (reusable for any k)
# ---------------------------------------------------------------------------

def _plot_topk_heatmap(records: list[dict], k: int, hit_field: str,
                       title: str, output_dir: pathlib.Path, filename: str):
    """Heatmap: rows = policy, columns = budget x fault, cells = hit/miss."""
    from matplotlib.colors import ListedColormap

    policies = ["head", "tail", "my_policy"]
    budgets  = ["low", "mid", "high"]
    faults   = ["delay", "abort"]

    col_labels = [f"{b}-{f}" for f in faults for b in budgets]
    col_keys   = [(b, f)     for f in faults for b in budgets]

    lookup: dict[tuple[str, str, str], bool | None] = {}
    for rec in records:
        key = (rec["policy"], rec["budget"], rec["fault_type"])
        lookup[key] = rec.get(hit_field)

    n_rows, n_cols = len(policies), len(col_keys)
    matrix = np.full((n_rows, n_cols), np.nan)
    for ri, pol in enumerate(policies):
        for ci, (bud, flt) in enumerate(col_keys):
            val = lookup.get((pol, bud, flt))
            if val is not None:
                matrix[ri, ci] = 1.0 if val else 0.0

    fig, ax = plt.subplots(figsize=(8, 3.5))
    ax.set_title(title, fontsize=13, fontweight="bold", pad=30)

    cmap = ListedColormap(["#FFCDD2", "#C8E6C9"])
    ax.imshow(matrix, aspect="auto", cmap=cmap, vmin=0, vmax=1)

    ax.set_xticks(range(n_cols))
    ax.set_xticklabels(col_labels, fontsize=9, rotation=30, ha="right")
    ax.set_yticks(range(n_rows))
    ax.set_yticklabels([POLICY_LABEL[p] for p in policies], fontsize=10)

    for ri in range(n_rows):
        for ci in range(n_cols):
            val = matrix[ri, ci]
            if np.isnan(val):
                txt, clr = "—", "grey"
            elif val == 1.0:
                txt, clr = "HIT", "#2E7D32"
            else:
                txt, clr = "miss", "#C62828"
            ax.text(ci, ri, txt, ha="center", va="center",
                    fontsize=9, fontweight="bold", color=clr)

    ax.axvline(x=len(budgets) - 0.5, color="grey", linewidth=1.5, linestyle="-")

    ax.text(len(budgets) / 2 - 0.5, -0.75, "delay faults",
            ha="center", va="center", fontsize=10, fontweight="bold", color="dimgrey",
            clip_on=False)
    ax.text(len(budgets) + len(budgets) / 2 - 0.5, -0.75, "abort faults",
            ha="center", va="center", fontsize=10, fontweight="bold", color="dimgrey",
            clip_on=False)

    ax.tick_params(top=False, bottom=True, labeltop=False, labelbottom=True)
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.set_xticks([c - 0.5 for c in range(1, n_cols)], minor=True)
    ax.set_yticks([r - 0.5 for r in range(1, n_rows)], minor=True)
    ax.grid(which="minor", color="white", linewidth=2)
    ax.tick_params(which="minor", length=0)

    fig.tight_layout()
    _save(fig, output_dir, filename)


def plot_topk_heatmaps(records: list[dict], output_dir: pathlib.Path):
    """Generate Top-3 and Top-5 heatmaps."""
    _plot_topk_heatmap(
        records, k=3, hit_field="t3_hit",
        title="RCA Top-3 hit rate: adaptive matches head, both beat tail",
        output_dir=output_dir, filename="top3_hit_heatmap",
    )
    _plot_topk_heatmap(
        records, k=5, hit_field="t5_hit",
        title="RCA Top-5 hit rate across all fault scenarios",
        output_dir=output_dir, filename="top5_hit_heatmap",
    )


# ---------------------------------------------------------------------------
# Figure: No-fault critical path (grouped dot plot)
# ---------------------------------------------------------------------------

def plot_nofault_critical_path(records: list[dict], output_dir: pathlib.Path):
    """Grouped dot plot: most strategies preserve high Jaccard — cost differs."""
    subset = [r for r in records if r["fault_type"] == "none"]
    if not subset:
        return

    policies = ["head", "tail", "my_policy"]
    budgets  = ["low", "mid", "high"]

    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.set_title("All strategies preserve critical-path fidelity;\ncost is the real differentiator",
                 fontsize=13, fontweight="bold", pad=10)

    # x-axis: SR, y-axis: Jaccard
    for rec in subset:
        x = rec.get("sampling_ratio")
        y = rec.get("jaccard")
        if x is None or y is None:
            continue
        color = POLICY_COLOR.get(rec["policy"], "grey")
        marker = BUDGET_MARKER.get(rec["budget"], "o")
        ax.scatter(x, y, color=color, marker=marker, s=MARKER_SIZE,
                   edgecolors="white", linewidths=0.6, zorder=3, alpha=0.9)

    ax.set_xlabel("Effective Sampling Ratio (lower = cheaper)", fontsize=11)
    ax.set_ylabel("Critical Path Jaccard (higher = better)", fontsize=11)
    ax.set_ylim(0.5, 1.08)
    ax.set_xlim(left=0)
    ax.grid(True, alpha=0.25, linewidth=0.5)

    # Reference line at Jaccard=1
    ax.axhline(y=1.0, color="grey", linewidth=0.8, linestyle=":", alpha=0.6)

    handles = _policy_handles() + _budget_handles()
    ax.legend(handles=handles, loc="upper left", bbox_to_anchor=(1.02, 1),
              fontsize=8, framealpha=0.9, borderaxespad=0)
    fig.tight_layout()
    _save(fig, output_dir, "critical_path_nofault")


# ---------------------------------------------------------------------------
# Save helper
# ---------------------------------------------------------------------------

def _save(fig, output_dir: pathlib.Path, stem: str):
    output_dir.mkdir(parents=True, exist_ok=True)
    for ext in ("png", "pdf"):
        path = output_dir / f"{stem}.{ext}"
        dpi = 300 if ext == "png" else None
        fig.savefig(path, dpi=dpi, bbox_inches="tight")
        print(f"  Saved: {path}")
    plt.close(fig)


# ---------------------------------------------------------------------------
# Console summary table
# ---------------------------------------------------------------------------

def print_summary(records: list[dict]):
    header = (f"{'Policy':<12} {'Budget':<6} {'Fault':<8} "
              f"{'SR':>6}  {'RCA Score':>10}  {'T3':>4}  {'T5':>4}  {'Jaccard':>8}")
    print("\n" + header)
    print("-" * len(header))
    for r in sorted(records, key=lambda x: (x["policy"], x["budget"], x["fault_type"])):
        sr  = f"{r['sampling_ratio']:.3f}" if r["sampling_ratio"] is not None else " n/a"
        sc  = f"{r['target_score']:.4f}"   if r["target_score"]   is not None else "      n/a"
        t3  = ("T" if r["t3_hit"] else "F") if r["t3_hit"] is not None else " -"
        t5  = ("T" if r["t5_hit"] else "F") if r.get("t5_hit") is not None else " -"
        jac = f"{r['jaccard']:.3f}"        if r["jaccard"]        is not None else "   n/a"
        print(f"{r['policy']:<12} {r['budget']:<6} {r['fault_type']:<8} "
              f"{sr:>6}  {sc:>10}  {t3:>4}  {t5:>4}  {jac:>8}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Generate Pareto analysis figures for mesh tracing experiments."
    )
    parser.add_argument(
        "--matrix-dir", required=True,
        help="Path to matrix run directory, e.g. results/matrix_runs/matrix_20260328_022053"
    )
    parser.add_argument(
        "--output-dir", default="results/figures",
        help="Directory to write output figures (PNG + PDF)"
    )
    parser.add_argument(
        "--no-summary", action="store_true",
        help="Skip printing the data summary table to stdout"
    )
    args = parser.parse_args()

    matrix_dir = pathlib.Path(args.matrix_dir).expanduser().resolve()
    output_dir = pathlib.Path(args.output_dir).expanduser().resolve()

    print(f"Loading data from: {matrix_dir}")
    records = load_matrix_data(matrix_dir)

    if not records:
        sys.exit("[error] No records loaded. Check the matrix directory path.")

    if not args.no_summary:
        print_summary(records)

    print(f"\nGenerating figures → {output_dir}")

    plot_rca_tradeoff(records, "delay", output_dir)
    plot_rca_tradeoff(records, "abort", output_dir)
    plot_topk_heatmaps(records, output_dir)
    plot_nofault_critical_path(records, output_dir)

    print("\nDone.")


if __name__ == "__main__":
    main()
