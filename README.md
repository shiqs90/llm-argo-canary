# LLM Canary Deployments with Argo Rollouts (Azure AKS + GPU time-slicing)

Progressive delivery for LLM serving: roll **Llama-3.2-1B → Llama-3.2-3B** behind one API
with an **Argo Rollouts canary**, an **automated health gate**, and **auto-rollback** —
on a single time-sliced NVIDIA T4, provisioned end-to-end with Terraform on **Azure AKS**.

**Checkpoint:** a model-version bump rolls out as 50% canary → analysis Job gates it →
promote to 100%; a broken version fails the gate and Argo rolls back to stable automatically.

It cleverly folds three learning-path items into one build: canary / progressive delivery (#5),
GPU time-slicing (#3), and the Azure port.

## Architecture

```
                         ┌─ Argo Rollouts controller (CPU node)
                         │  watches Rollout, orchestrates steps
client ──► Service llama-canary :8000
              ├──► stable pod  vLLM Llama-3.2-1B ─┐   one physical T4 (16 GB)
              └──► canary pod  vLLM Llama-3.2-3B ─┴── time-sliced as 4 GPU slots
                         │
                         └─ analysis step: curl Job POSTs /v1/chat/completions
                            200 + content → proceed · fail → auto-abort to stable
```

Both versions serve the same API name (`--served-model-name=llama-chat`), so clients are
untouched by the roll. Traffic split is **replica-weighted** (one Service selects both pods)
— no service mesh required.

## Hardware: why 1× T4 + time-slicing

| Choice | Reason |
|---|---|
| `Standard_NC4as_T4_v3` (1× T4 16 GB, ~$0.53/hr) | Cheapest Azure GPU; canary needs *concurrent* stable+canary pods, and time-slicing makes one card enough |
| Time-slicing ×4 (GPU Operator) | T4 (Turing) has no MIG; software slicing is the only sharing mode. **No memory isolation** — pods must self-limit |
| VRAM budget | 1B pod `--gpu-memory-utilization=0.28` (~4.5 GB) · 3B pod `0.44` (~7 GB). Canary phase ≈ 11.5 GB, fully-promoted 2×3B ≈ 14 GB — both < 16 GB |
| `--dtype=half` | Turing has **no bfloat16**; Llama-3.2 defaults to bf16 and crashes vLLM without this |

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

## Demo

```bash
# Happy path: bump 1B -> 3B, watch canary -> analysis -> pause
bash scripts/canary-demo.sh
bash scripts/generate-load.sh                    # second terminal: live traffic
kubectl argo rollouts promote llama-canary       # approve -> 100% 3B

# Auto-rollback: broken model name -> canary never Ready -> Argo aborts to stable
bash scripts/canary-demo.sh --break
kubectl argo rollouts get rollout llama-canary   # Degraded, stable still serving

bash scripts/canary-demo.sh --reset              # back to 1B baseline
```

## Cost

| State | ~$/hr | What's running |
|---|---|---|
| Active | **~$0.75** | free control plane + D2s_v3 (~$0.12) + T4 (~$0.63) — Australia Central prices run higher than US regions |
| GPU pool scaled to 0 | ~$0.10 | `az aks nodepool scale ... --name gpu --node-count 0` |
| Destroyed | $0 | `terraform destroy` (or `az group delete -n rg-llm-argo-canary`) |

## Notes / deliberate choices

- **Job-based analysis, not Prometheus** — the gate is a curl Job, so the repo has zero
  observability-stack dependency (that lives in the gpu-inference-observability project).
- **Replica-weighted canary, not mesh-based** — setWeight 50 with 2 replicas = 1+1 pods
  behind one Service. Precise per-request weights need a mesh/ingress plugin; out of scope.
- **`gpu_driver = "None"` on the node pool** — AKS's own NVIDIA driver install is skipped so
  the GPU Operator owns driver + device plugin + time-slicing without conflicts (on EKS the
  accelerated AMI ships the driver instead — the operator runs `driver.enabled=false` there).
- **Engine pinned** `vllm/vllm-openai:v0.22.1`, charts pinned (gpu-operator v26.3.2,
  argo-rollouts 2.41.0) — reproducible builds.
