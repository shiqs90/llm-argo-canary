# Project 5 — LLM Canary Deployments with Argo Rollouts (Azure AKS + GPU time-slicing)

Roll **Llama-3.2-1B → Llama-3.2-3B** behind a single API using an **Argo Rollouts canary**, with
an automated health gate and automatic rollback when the new version misbehaves. All of it on one
time-sliced NVIDIA T4, provisioned end to end with Terraform on **Azure AKS**.

**Done when:** a model-version bump rolls out as a 50% canary, an analysis Job gates it, and I
promote it to 100%. And when a deliberately broken version gets caught, either because it never
becomes healthy or because it fails the gate, and Argo returns to stable on its own.

This one covers three items at once: canary and progressive delivery (#5), GPU time-slicing (#3),
and the first Azure port of the stack.

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

Both versions register under the same API name (`--served-model-name=llama-chat`), so clients
never notice the swap. `replicas: 1` plus `maxSurge: 1` means the canary **adds one temporary
pod** next to the live one. A single Service selects both, so traffic splits roughly 50/50
between them. No service mesh involved.

## Hardware: why one T4 and time-slicing

| Choice | Reason |
|---|---|
| `Standard_NC4as_T4_v3` (1× T4 16 GB, ~$0.53/hr) | Azure's cheapest GPU. A canary needs the stable and canary pods running *at the same time*, and time-slicing makes one card enough for that. |
| Time-slicing ×4 via the GPU Operator | The T4 is Turing, which has no MIG. Software slicing is the only sharing option. It gives **no memory isolation**, so every pod's `--gpu-memory-utilization` is a slice of the whole card and the values have to sum under 1.0. |
| VRAM budget | With `replicas: 1`, a canary surges one pod: live 1B at `0.25` (~4 GB) plus canary 3B at `0.55` (~8.8 GB), about **12.8 GB at peak**. After promotion it's a single 3B pod. `--enforce-eager` drops CUDA graphs to buy back KV cache headroom. Full working in [docs/gpu-memory-math.md](docs/gpu-memory-math.md). |
| `--dtype=half` | Turing has no bfloat16. Llama-3.2 defaults to bf16 and vLLM crashes without this flag. |
| GPU pool on **Ubuntu 22.04** | AKS's default 24.04 image runs containerd 2.x, which refuses the GPU Operator toolkit's containerd drop-in and then won't start at all. 22.04 ships containerd 1.7, which accepts it. `os_sku = "Ubuntu2204"`. |

## Deploy

You'll need an Azure subscription with **NCASv3_T4 quota of at least 4 vCPU** in
`australiacentral`, a completed `az login`, an HCP Terraform workspace named `llm-argo-canary`
set to Local execution, and a Hugging Face token with Llama-3.2 access. Those models are gated.

```bash
# 1. Infra: AKS + T4 pool + GPU Operator + Argo Rollouts (~15 min)
cd terraform && terraform init && terraform apply

# 2. Point kubectl at the cluster (terraform also prints this command as an output)
az aks get-credentials --resource-group rg-llm-argo-canary --name llm-argo-canary
kubectl get nodes   # expect 1 system + 1 GPU node, both Ready

# 3. Slice the T4 into 4 slots
kubectl apply -f ../k8s/timeslicing-configmap.yaml
kubectl patch clusterpolicy cluster-policy -n gpu-operator --type merge \
  -p '{"spec":{"devicePlugin":{"config":{"name":"time-slicing-config","default":"any"}}}}'
kubectl describe node -l workload=gpu | grep "nvidia.com/gpu:"   # capacity should read 4

# 4. HF token (Llama 3.2 is gated). Lives in the cluster only, never in the repo.
kubectl create secret generic hf-token --from-literal=token=hf_YOUR_TOKEN

# 5. Deploy the Rollout, Service and AnalysisTemplate
brew install argoproj/tap/kubectl-argo-rollouts   # the rollouts kubectl plugin
kubectl apply -f ../k8s/
kubectl argo rollouts get rollout llama-canary --watch   # stable 1B comes up in 5-10 min
```

## Testing

Both paths were run end to end. Use two terminals: one drives the rollout, the other streams
traffic so you can watch requests keep flowing while it happens.

Four `kubectl argo rollouts get` views are the evidence worth capturing: paused at 50% with the
analysis Successful, promoted and Healthy, the crashlooping canary sitting at `ActualWeight 0`
while stable serves, and the aborted revert.

### Happy path (promote)

```bash
# Terminal A — a request every 2 seconds, through the Service
bash scripts/generate-load.sh

# Terminal B — bump the served model 1B -> 3B, which triggers the canary
bash scripts/canary-demo.sh
```

Watch terminal B for three things:

1. A new `revision:N` ReplicaSet appears, holding the 3B **canary**. At `setWeight 50` you have
   **live 1B + canary 3B = 2 pods**. Never 3, because `maxSurge: 1` adds exactly one.
2. The canary goes Ready, then the **AnalysisRun** fires the `chat-completion-check` Job. It curls
   the canary and needs both HTTP 200 and a non-empty completion. Result: **Successful**.
3. The rollout **pauses** at the human gate (`CanaryPauseStep`, step 2 of 3).

Then promote:

```bash
kubectl argo rollouts promote llama-canary
```

The 3B scales up to the single replica, the 1B retires, that revision becomes **stable** and the
status goes **Healthy** at step 3 of 3.

### Failure path (auto-rollback)

```bash
# Point the canary at a deliberately misspelled model, so it can never download or start
bash scripts/canary-demo.sh --break
kubectl argo rollouts get rollout llama-canary --watch
```

What you see:

- The canary pod goes **CrashLoopBackOff** at `ready 0/1`, and **`ActualWeight: 0`**. Despite
  `setWeight 50`, the broken version receives no traffic at all. Readiness is doing its job.
- The live pod keeps serving at `ready 1/1`. Production is untouched.
- Argo aborts once the progress deadline expires and goes **Degraded**. To skip the wait:

```bash
kubectl argo rollouts abort llama-canary   # scale the bad canary down, revert to stable
```

Back to a clean baseline when you're done:

```bash
bash scripts/canary-demo.sh --reset        # rolls back to the 1B baseline
```

### Two different rollback triggers

These are worth separating, because interviewers ask about the second one and most demos only
show the first.

- A canary that **never becomes healthy**. That's the `--break` case, caught by readiness probes
  and the progress deadline.
- A canary that **starts fine but fails the analysis gate**, meaning the curl Job got a non-200 or
  an empty completion. A model can be perfectly "up" and still be serving garbage, which is
  exactly the failure mode a plain health check misses.

The happy path exercises the analysis gate passing. `--break` exercises the health-based abort.

## Cost

| State | ~$/hr | What's running |
|---|---|---|
| Active | **~$0.75** | Free control plane, D2s_v3 (~$0.12), T4 (~$0.63). Australia Central prices run above the US regions. |
| GPU pool at 0 | ~$0.10 | `az aks nodepool scale ... --name gpu --node-count 0` |
| Destroyed | $0 | `terraform destroy`, or `az group delete -n rg-llm-argo-canary` |

## Deliberate choices

- **The gate is a curl Job, not Prometheus.** That keeps this repo free of any observability-stack
  dependency, which lives over in the gpu-inference-observability project. In production you'd
  gate on real SLO metrics: p99 TTFT, error rate, maybe output-quality checks.
- **Replica-weighted canary, not mesh-based.** `replicas: 1` with `maxSurge: 1`, so the canary
  adds one pod beside the live one and the promoted state is a single 3B pod. `replicas: 1`
  rather than 2 is deliberate on a one-GPU demo: it keeps the peak at `1B + 3B` instead of
  `2× 3B`. Precise per-request weights would need a mesh or an ingress plugin, which is out of
  scope here.
- **`gpu_driver = "None"` on the node pool.** AKS's own NVIDIA driver install is skipped so the
  GPU Operator alone owns the driver, device plugin and time-slicing config, with nothing to
  conflict over. On EKS the accelerated AMI ships the driver instead, and there the Operator runs
  with `driver.enabled=false`. Same principle, opposite knob.
- **GPU node pool pinned to Ubuntu 22.04** (`os_sku = "Ubuntu2204"`). The default 24.04 image runs
  containerd 2.x, which rejects the GPU Operator toolkit's higher-version containerd drop-in and
  then refuses to start. containerd down means kubelet down, which means the node never comes
  back. The system pool can stay on 24.04 since it runs no GPU workloads. Full story in
  `PROJECT5-SUMMARY.md`, war story #5.
- **GPU memory was tuned by hand.** A 3B model barely fits a 16 GB T4 once another pod is sharing
  the card, so `--enforce-eager` plus capped `--max-model-len` and `--max-num-seqs` are what leave
  room for KV cache. The reasoning from first principles is in
  [docs/gpu-memory-math.md](docs/gpu-memory-math.md).
- **Everything is pinned:** engine `vllm/vllm-openai:v0.22.1`, gpu-operator v26.3.2,
  argo-rollouts 2.41.0.
