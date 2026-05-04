# Sampling Policy Manifests

Naming convention for static manifests:
- `<policy>_<budget>.yaml`
- policy: `baseline_head | baseline_tail`
- budget: `low | mid | high`

Static manifests in this folder:
- `baseline_head_{low,mid,high}.yaml`
- `baseline_tail_{low,mid,high}.yaml`

Policy details:
- `baseline_head` — fixed head sampling probability: low=1%, mid=10%, high=30%.
- `baseline_tail` — OTel `tail_sampling` processor with three OR-rules per budget:
  - latency threshold (500 / 300 / 200 ms)
  - status_code = ERROR
  - fallback probabilistic (1% / 10% / 30%)
- `my_policy` — generated at runtime by `scripts/04_apply_sampling_policy.sh` and then re-rendered by `scripts/volatility_tail_controller.py` whenever the controller switches profile (conservative / balanced / aggressive). Same processor as `baseline_tail`; only the parameters change.
- `reference` — generated inline as `probabilistic_sampler` at 100% (no static manifest).
- `no_tracing` — generated inline; OTel processor stripped, Istio Telemetry sampling set to 0.0.

Experiment-facing aliases accepted by `scripts/04_apply_sampling_policy.sh`:
- `head` -> `baseline_head`
- `tail` -> `baseline_tail`
- `my_policy` -> volatility-driven tail controller

Accepted `--policy` values: `head | tail | my_policy | reference | no_tracing` (canonical `baseline_head` / `baseline_tail` also accepted).

Apply with:
- `bash scripts/04_apply_sampling_policy.sh --policy head --budget low`
- `bash scripts/04_apply_sampling_policy.sh --policy tail --budget mid`
- `bash scripts/04_apply_sampling_policy.sh --policy my_policy --budget high`
