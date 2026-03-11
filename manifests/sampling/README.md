# Sampling Policy Manifests

Naming convention:
- `<policy>_<budget>.yaml`
- policy: `baseline_head | baseline_tail | ours`
- budget: `low | mid | high`

Implemented sets:
- `baseline_head_{low,mid,high}.yaml`
- `baseline_tail_{low,mid,high}.yaml`
- `ours_{low,mid,high}.yaml`

Policy details:
- `baseline_head`: fixed head sampling probability (low=1%, mid=10%, high=30%).
- `baseline_tail`: tail sampling with required rules:
  - latency threshold
  - status_code = ERROR
  - fallback probabilistic policy
- `ours`: placeholder "service-granularity dynamic sampling", with per-service sampling rates.
- `reference`: generated at runtime by `scripts/04_apply_sampling_policy.sh` as a higher-sampling head-based config (no static manifest file).
- `no_tracing`: generated at runtime by `scripts/04_apply_sampling_policy.sh` and paired with Telemetry sampling `0.0`.

Experiment-facing aliases accepted by `scripts/04_apply_sampling_policy.sh`:
- `head` -> `baseline_head`
- `tail` -> `baseline_tail`
- `my_policy` -> `ours`

Apply with:
- `bash scripts/04_apply_sampling_policy.sh --policy baseline_head --budget low`
- `bash scripts/04_apply_sampling_policy.sh --policy baseline_tail --budget mid`
- `bash scripts/04_apply_sampling_policy.sh --policy ours --budget high`
