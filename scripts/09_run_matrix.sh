#!/usr/bin/env bash
set -euo pipefail

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULTS_DIR="${ROOT_DIR}/results"
SPEC_FILE=""
MATRIX_ID=""

usage() {
  cat <<'EOF'
Usage:
  scripts/09_run_matrix.sh --spec experiments/mvp_matrix.json [--matrix-id custom_id]

Spec format (JSON):
  {
    "app": "bookinfo",
    "policies": ["no_tracing", "head", "tail", "my_policy", "reference"],
    "budgets": ["low", "medium", "high"],
    "load_levels": {"low": 50, "medium": 200, "high": 500},
    "faults": [
      {"type": "none"},
      {"type": "delay", "targets": ["service=reviews"], "fixed_delay_ms": 500, "percentage": 50}
    ],
    "duration_seconds": 120,
    "repeats": 1
  }
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --spec) SPEC_FILE="${2:-}"; shift 2 ;;
    --matrix-id) MATRIX_ID="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

[[ -n "${SPEC_FILE}" ]] || err "--spec is required"
command -v python3 >/dev/null 2>&1 || err "python3 not found"

case "${SPEC_FILE}" in
  /*) SPEC_PATH="${SPEC_FILE}" ;;
  *) SPEC_PATH="${ROOT_DIR}/${SPEC_FILE}" ;;
esac
[[ -f "${SPEC_PATH}" ]] || err "Spec file not found: ${SPEC_PATH}"

mkdir -p "${RESULTS_DIR}/matrix_runs" || err "Failed to create matrix results dir"
if [[ -z "${MATRIX_ID}" ]]; then
  MATRIX_ID="matrix_$(date +%Y%m%d_%H%M%S)"
fi
MATRIX_DIR="${RESULTS_DIR}/matrix_runs/${MATRIX_ID}"
RUN_LOG="${MATRIX_DIR}/runs.jsonl"
SUMMARY_JSON="${MATRIX_DIR}/matrix_summary.json"
mkdir -p "${MATRIX_DIR}" || err "Failed to create matrix output dir"

python3 - <<'PY' "${SPEC_PATH}" > "${MATRIX_DIR}/expanded_runs.jsonl"
import itertools
import json
import sys
from pathlib import Path

spec = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

app = spec["app"]
policies = list(spec["policies"])
if "reference" in policies:
    policies = ["reference"] + [item for item in policies if item != "reference"]
budgets = spec["budgets"]
load_levels = spec["load_levels"]
faults = spec["faults"]
duration = int(spec["duration_seconds"])
repeats = int(spec.get("repeats", 1))
namespaces = spec.get("namespaces", {})
notes = spec.get("notes")

run_index = 0
for policy, budget, (load_level, rps), fault, repeat_id in itertools.product(
    policies,
    budgets,
    load_levels.items(),
    faults,
    range(1, repeats + 1),
):
    fault_type = fault["type"]
    targets = fault.get("targets", [None])
    for target in targets:
        run_index += 1
        record = {
            "sequence": run_index,
            "app": app,
            "policy": policy,
            "budget": budget,
            "load_level": load_level,
            "rps": int(rps),
            "duration_seconds": duration,
            "fault_type": fault_type,
            "fault_target": target,
            "fault_target_type": fault.get("target_type"),
            "fixed_delay_ms": fault.get("fixed_delay_ms", 200),
            "http_status": fault.get("http_status", 500),
            "percentage": fault.get("percentage", 10),
            "repeat_id": repeat_id,
            "notes": notes,
            "namespaces": namespaces,
        }
        print(json.dumps(record, ensure_ascii=True))
PY

SUCCESS_COUNT=0
FAIL_COUNT=0

while IFS= read -r line; do
  [[ -n "${line}" ]] || continue
  sequence="$(python3 - <<'PY' "${line}"
import json
import sys
print(json.loads(sys.argv[1])["sequence"])
PY
)"
  app="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["app"])
PY
)"
  policy="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["policy"])
PY
)"
  budget="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["budget"])
PY
)"
  load_level="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["load_level"])
PY
)"
  rps="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["rps"])
PY
)"
  duration_seconds="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["duration_seconds"])
PY
)"
  fault_type="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["fault_type"])
PY
)"
  fault_target="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print("" if d["fault_target"] is None else d["fault_target"])
PY
)"
  fault_target_type="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print("" if d["fault_target_type"] is None else d["fault_target_type"])
PY
)"
  fixed_delay_ms="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["fixed_delay_ms"])
PY
)"
  http_status="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["http_status"])
PY
)"
  percentage="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["percentage"])
PY
)"
  repeat_id="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d["repeat_id"])
PY
)"
  app_ns="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d.get("namespaces", {}).get("app", "mesh-app"))
PY
)"
  obs_ns="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d.get("namespaces", {}).get("observability", "observability"))
PY
)"
  istio_ns="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print(d.get("namespaces", {}).get("istio", "istio-system"))
PY
)"
  notes="$(python3 - <<'PY' "${line}"
import json
import sys
d = json.loads(sys.argv[1])
print("" if d["notes"] is None else d["notes"])
PY
)"

  run_id="${MATRIX_ID}_$(printf '%03d' "${sequence}")"
  cmd=(bash "${ROOT_DIR}/scripts/08_run_experiment.sh"
    --app "${app}"
    --policy "${policy}"
    --budget "${budget}"
    --fault-type "${fault_type}"
    --rps "${rps}"
    --load-level "${load_level}"
    --duration "${duration_seconds}"
    --run-id "${run_id}"
    --repeat-id "${repeat_id}"
    --app-namespace "${app_ns}"
    --obs-namespace "${obs_ns}"
    --istio-namespace "${istio_ns}"
  )
  if [[ -n "${fault_target}" ]]; then
    cmd+=(--fault-target "${fault_target}")
  fi
  if [[ -n "${fault_target_type}" ]]; then
    cmd+=(--fault-target-type "${fault_target_type}")
  fi
  if [[ -n "${notes}" ]]; then
    cmd+=(--notes "${notes}")
  fi
  if [[ "${fault_type}" != "none" ]]; then
    cmd+=(--fixed_delay_ms "${fixed_delay_ms}" --http_status "${http_status}" --percentage "${percentage}")
  fi

  log "Running matrix item ${sequence}: policy=${policy} budget=${budget} load=${load_level} fault=${fault_type} target=${fault_target:-none}"
  if "${cmd[@]}"; then
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    status="success"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    status="failed"
    warn "Matrix item ${sequence} failed; continuing to next combination"
  fi

  python3 - <<'PY' "${RUN_LOG}" "${line}" "${run_id}" "${status}"
import json
import sys
from pathlib import Path

run_log_path, raw_record, run_id, status = sys.argv[1:5]
record = json.loads(raw_record)
record["run_id"] = run_id
record["status"] = status
with Path(run_log_path).open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(record, ensure_ascii=True) + "\n")
PY
done < "${MATRIX_DIR}/expanded_runs.jsonl"

python3 - <<'PY' "${SUMMARY_JSON}" "${SPEC_PATH}" "${RUN_LOG}" "${SUCCESS_COUNT}" "${FAIL_COUNT}" "${MATRIX_ID}"
import json
import sys
from pathlib import Path

summary_path, spec_path, run_log_path, success_count, fail_count, matrix_id = sys.argv[1:7]
runs = []
run_log = Path(run_log_path)
if run_log.exists():
    runs = [json.loads(line) for line in run_log.read_text(encoding="utf-8").splitlines() if line.strip()]

doc = {
    "matrix_id": matrix_id,
    "spec_file": spec_path,
    "success_count": int(success_count),
    "fail_count": int(fail_count),
    "runs_file": run_log_path,
    "runs": runs,
}
Path(summary_path).write_text(json.dumps(doc, ensure_ascii=True, indent=2) + "\n", encoding="utf-8")
PY

log "Matrix run completed: ${MATRIX_DIR}"
log "Success=${SUCCESS_COUNT}, Failed=${FAIL_COUNT}"
