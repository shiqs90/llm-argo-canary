# LLM Canary Deployments with Argo Rollouts (Azure AKS + GPU time-slicing)

Progressive delivery for LLM serving: roll **Llama-3.2-1B → Llama-3.2-3B** behind one API
with an **Argo Rollouts canary**, an **automated health gate**, and **auto-rollback** —
on a single time-sliced NVIDIA T4, provisioned end-to-end with Terraform on **Azure AKS**.

**Checkpoint:** a model-version bump rolls out as 50% canary → analysis Job gates it →
promote to 100%; a broken version is caught (never healthy, or fails the gate) and Argo rolls
back to stable automatically.

It cleverly folds three learning-path items into one build: canary / progressive delivery (#5),
GPU time-slicing (#3), and the Azure port.

## Architecture

```
                         ┌─ Argo Rollouts controller (CPU node)
                         │  watches Rollout, orchestrates steps
client ──► Service llama-canary :8000
              ├──► live pod    vLLM Llama-3.2-1B ─┐   one physical T4 (16 GB), time-sliced;
              └──► canary pod  vLLM Llama-3.2-3B ─┴── canary is a +1 SURGE pod during the roll
                         │
                         └─ analysis step: curl Job POSTs /v1/chat/completions
                            200 + content → proceed · fail → auto-abort to stable
```

Both versions serve the same API name (`--served-model-name=llama-chat`), so clients are
untouched by the roll. `replicas: 1` + `maxSurge: 1`: the canary **adds one temporary pod**
beside the live one, so traffic splits ~50/50 across the two (one Service selects both) — no
service mesh required. After promotion the single pod is the new (3B) version.

## Hardware: why 1× T4 + time-slicing

| Choice | Reason |
|---|---|
| `Standard_NC4as_T4_v3` (1× T4 16 GB, ~$0.53/hr) | Cheapest Azure GPU; canary needs *concurrent* stable+canary pods, and time-slicing makes one card enough |
| Time-slicing ×4 (GPU Operator) | T4 (Turing) has no MIG; software slicing is the only sharing mode. **No memory isolation** — every pod's `--gpu-memory-utilization` is a share of the *whole* card, so the shares must sum < 1.0 |
| VRAM budget | `replicas: 1`, so a canary *surges* one pod: live 1B `--gpu-memory-utilization=0.25` (~4 GB) + canary 3B `0.55` (~8.8 GB) ≈ **12.8 GB peak**; promoted state is a single 3B. `--enforce-eager` drops CUDA graphs for KV-cache headroom. Full math → [docs/gpu-memory-math.md](docs/gpu-memory-math.md) |
| `--dtype=half` | Turing has **no bfloat16**; Llama-3.2 defaults to bf16 and crashes vLLM without this |
| GPU pool on **Ubuntu 22.04** | AKS's default 24.04 image (containerd 2.x) rejects the GPU Operator toolkit's containerd drop-in → containerd won't start. 22.04 (containerd 1.7) accepts it. `os_sku = "Ubuntu2204"` |

## Deploy

Prereqs: Azure subscription with **NCASv3_T4 quota ≥ 4 vCPU** in `australiacentral`, `az login` done,
HCP Terraform workspace `llm-argo-canary` (execution mode: Local), a HF token with
Llama-3.2 access (the models are gated).

```bash
# 1. Infra: AKS + T4 pool + GPU Operator + Argo Rollouts (~15 min)
cd terraform && terraform init && terraform apply

# 2. Point kubectl at the cluster (command is also printed as a terraform output)
az aks get-credentials --resource-group rg-llm-argo-canary --name llm-argo-canary
kubectl get nodes   # expect: 1 system + 1 GPU node Ready

# 3. Time-slice the T4 into 4 slots
kubectl apply -f ../k8s/timeslicing-configmap.yaml
kubectl patch clusterpolicy cluster-policy -n gpu-operator --type merge \
  -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'
kubectl describe node -l workload=gpu | grep "nvidia.com/gpu:"   # expect capacity 4

# 4. HF token (Llama 3.2 is gated) — lives only in the cluster, never in the repo
kubectl create secret generic hf-token --from-literal=token=hf_YOUR_TOKEN

# 5. Deploy the Rollout + Service + AnalysisTemplate
brew install argoproj/tap/kubectl-argo-rollouts   # the rollouts kubectl plugin
kubectl apply -f ../k8s/
kubectl argo rollouts get rollout llama-canary --watch   # stable 1B comes up (~5-10 min)
```

## Testing — canary happy path & failure path

Both paths were exercised end to end. Use two terminals: one drives the rollout, one streams
live traffic so you can watch requests keep flowing during the roll.

### Happy path (promote)
```bash
# Terminal A — continuous traffic through the Service (a request every 2s)
bash scripts/generate-load.sh

# Terminal B — bump the served model 1B -> 3B (triggers the canary), then watch
bash scripts/canary-demo.sh
```
What to observe in Terminal B:
1. A new `revision:N` ReplicaSet (the 3B **canary**) appears; at **setWeight 50** you have
   **live 1B + canary 3B = 2 pods** (never 3 — `maxSurge: 1` adds exactly one).
2. Canary becomes Ready → the **AnalysisRun** runs the `chat-completion-check` Job (curls the
   canary, needs HTTP 200 + non-empty completion) → **Successful**.
3. Rollout **Paused** at the human gate (`CanaryPauseStep`, Step 2/3).

Promote to 100%:
```bash
kubectl argo rollouts promote llama-canary
```
→ 3B scales to the single replica, 1B retires, that revision becomes **stable**, Status
**Healthy** (Step 3/3). *Evidence: the Paused-at-50%-with-analysis-Successful view + the
promoted Healthy view.*

### Failure path (auto-rollback)
```bash
# Point the canary at a broken (deliberately misspelled) model — it can never download/start
bash scripts/canary-demo.sh --break
kubectl argo rollouts get rollout llama-canary --watch
```
What to observe:
- Canary pod → **CrashLoopBackOff**, `ready 0/1`, and **`ActualWeight: 0`** — the bad version
  receives **zero** traffic despite `setWeight 50`.
- The live/stable pod keeps serving `ready 1/1` — **production is untouched**.
- Argo aborts on the progress deadline → **Degraded**; force it immediately instead of waiting:
```bash
kubectl argo rollouts abort llama-canary   # scales the bad canary down, reverts to stable
```
*Evidence: the crashlooping canary at `ActualWeight 0` while stable serves, and the
aborted/reverted view.*

Return to a clean baseline (optional):
```bash
bash scripts/canary-demo.sh --reset        # rolls back to the 1B baseline
```

**Two distinct rollback triggers** (both valid, worth knowing): a canary that **never becomes
healthy** (the `--break` case — caught by readiness + the progress deadline) versus a canary
that starts but **fails the analysis gate** (the curl Job returns non-200 / empty). The happy
path exercises the analysis gate *passing*; `--break` exercises the health-based abort.

## Cost

| State | ~$/hr | What's running |
|---|---|---|
| Active | **~$0.75** | free control plane + D2s_v3 (~$0.12) + T4 (~$0.63) — Australia Central prices run higher than US regions |
| GPU pool scaled to 0 | ~$0.10 | `az aks nodepool scale ... --name gpu --node-count 0` |
| Destroyed | $0 | `terraform destroy` (or `az group delete -n rg-llm-argo-canary`) |

## Notes / deliberate choices

- **Job-based analysis, not Prometheus** — the gate is a curl Job, so the repo has zero
  observability-stack dependency (that lives in the gpu-inference-observability project).
- **Replica-weighted canary, not mesh-based** — `replicas: 1` with `maxSurge: 1`, so a canary
  *adds* one temporary pod beside the live one (live 1B + canary 3B), and after promotion the
  single pod is the 3B. `replicas: 1` (not 2) is deliberate for a one-GPU demo: it keeps the
  peak at `1B + 3B` instead of `2×3B`. Precise per-request weights would need a mesh/ingress
  plugin; out of scope.
- **`gpu_driver = "None"` on the node pool** — AKS's own NVIDIA driver install is skipped so
  the GPU Operator owns driver + device plugin + time-slicing without conflicts (on EKS the
  accelerated AMI ships the driver instead — the operator runs `driver.enabled=false` there).
- **GPU node pool pinned to Ubuntu 22.04** (`os_sku = "Ubuntu2204"`) — the default 24.04 image
  runs containerd 2.x, which rejects the GPU Operator toolkit's higher-version containerd
  drop-in and refuses to start; 22.04 (containerd 1.7) accepts it. The system pool can stay
  24.04 (it runs no GPU workloads). See `PROJECT5-SUMMARY.md` war story #5.
- **Deliberate GPU-memory tuning** — a 3B barely fits a 16 GB T4, so `--enforce-eager` +
  capped `--max-model-len`/`--max-num-seqs` leave room for KV cache. Reasoning from scratch in
  [docs/gpu-memory-math.md](docs/gpu-memory-math.md).
- **Engine pinned** `vllm/vllm-openai:v0.22.1`, charts pinned (gpu-operator v26.3.2,
  argo-rollouts 2.41.0) — reproducible builds.
