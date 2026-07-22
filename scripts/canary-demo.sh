#!/usr/bin/env bash
# Triggers a canary rollout by bumping the served model.
#
#   bash scripts/canary-demo.sh           # 1B -> 3B (happy path)
#   bash scripts/canary-demo.sh --break   # 1B -> nonexistent model (rollback demo)
#   bash scripts/canary-demo.sh --reset   # back to 1B stable baseline
#
# During the run (other terminal):
#   kubectl argo rollouts promote llama-canary   # approve at the pause step
#   kubectl argo rollouts abort llama-canary     # manual rollback
set -euo pipefail

case "${1:-}" in
  --break)
    MODEL="meta-llama/Llama-3.2-3B-Instruc" # typo on purpose: download fails -> pod never Ready -> auto-abort
    UTIL="0.55"
    ;;
  --reset)
    MODEL="meta-llama/Llama-3.2-1B-Instruct"
    UTIL="0.25"
    ;;
  *)
    MODEL="meta-llama/Llama-3.2-3B-Instruct"
    UTIL="0.55" # 3B ~6GB weights; a single 3B on the 16GB T4 has ample room at 0.55
    ;;
esac

echo ">> Setting model=$MODEL (gpu-memory-utilization=$UTIL) — this changes the pod
>> template, so Argo Rollouts starts a canary instead of replacing pods in place."
kubectl patch rollout llama-canary --type json -p "[
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/0/value\",\"value\":\"$MODEL\"},
  {\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/env/1/value\",\"value\":\"$UTIL\"}
]"

echo ">> Watching the rollout (Ctrl-C to stop watching; the rollout continues):"
kubectl argo rollouts get rollout llama-canary --watch
