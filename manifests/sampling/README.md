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
- `my_policy`: generated at runtime by `scripts/04_apply_sampling_policy.sh` as a volatility-driven tail-sampling base config. A controller process can later adjust its latency threshold and fallback probability during the run.
- `ours`: historical placeholder "service-granularity dynamic sampling", with per-service sampling rates. The files remain in this folder for reference but are no longer the experiment-facing `my_policy` implementation.
- `reference`: generated at runtime by `scripts/04_apply_sampling_policy.sh` as a higher-sampling head-based config (no static manifest file).
- `no_tracing`: generated at runtime by `scripts/04_apply_sampling_policy.sh` and paired with Telemetry sampling `0.0`.

Experiment-facing aliases accepted by `scripts/04_apply_sampling_policy.sh`:
- `head` -> `baseline_head`
- `tail` -> `baseline_tail`
- `my_policy` -> volatility-driven tail controller

Apply with:
- `bash scripts/04_apply_sampling_policy.sh --policy baseline_head --budget low`
- `bash scripts/04_apply_sampling_policy.sh --policy baseline_tail --budget mid`
- `bash scripts/04_apply_sampling_policy.sh --policy ours --budget high`
