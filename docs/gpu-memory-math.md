# GPU Memory Math — why the vLLM flags are what they are

A from-scratch explanation of how we sized two Llama models to share one 16 GB GPU.
No prior GPU knowledge assumed.

## The one hard constraint

We have **one NVIDIA T4 = 16 GB of GPU memory (VRAM)**, and — because we use
**time-slicing** to share it — there is **no memory isolation**. Every pod sees the whole
16 GB and can grab as much as it wants. Nothing stops one pod from taking it all and
starving the others (which then crash). So *we* have to hand each pod a memory budget and
make sure the budgets add up to less than 16 GB. That budget is one vLLM flag:
`--gpu-memory-utilization`.

Think of the T4 as a **16-litre bucket** shared by housemates with no dividers. If everyone
just scoops freely, someone runs dry. So each person is told "you may use up to X litres."
The rule is simply: **the sum of everyone's allowance ≤ 16.**

## What `--gpu-memory-utilization` actually means

It's a **fraction of the *total* 16 GB** that one vLLM process is allowed to use — its share
of the bucket. It is **not** "how much of the free space" — it's measured against the full 16
GB, always.

```
--gpu-memory-utilization = 0.48   →   this pod may use 0.48 × 16 GB = 7.7 GB
```

This is the subtle trap of time-slicing: vLLM computes 7.7 GB from the *total* card, but the
card might already be half-full with another pod's model. vLLM checks the **currently free**
memory at startup, and if free space is less than its 7.7 GB budget, it refuses to start.
That's why we can't just set everyone to 0.9 — the allowances would overlap.

## Where a model's memory actually goes

When vLLM loads a model, its budget gets spent in four buckets, in this order:

| Bucket | What it is | Llama-3.2-3B (FP16) |
|---|---|---|
| 1. **Weights** | the model's parameters. FP16 = 2 bytes each | 3.2B params × 2 = **~6.0 GB** |
| 2. **CUDA context** | fixed overhead the GPU driver + PyTorch reserve | ~0.7 GB |
| 3. **CUDA graphs** | pre-recorded execution plans that make inference faster | ~0.5 GB |
| 4. **KV cache** | scratch space for the *conversation* — grows with tokens | **whatever's left** |

The critical part: **KV cache gets the leftovers.** vLLM fills buckets 1–3 first, then
whatever remains of your budget becomes KV cache. **If buckets 1–3 already exceed the
budget, KV cache is negative — and vLLM aborts.** That is exactly the error we hit:

```
Model loading took 6.04 GiB          ← weights
Estimated CUDA graph memory: 0.48 GiB ← graphs
Available KV cache memory: -0.93 GiB  ← NEGATIVE → engine fails to start
```

At `--gpu-memory-utilization=0.44` the budget was `0.44 × 16 = 7.0 GB`, but weights (6.04) +
graphs (0.48) + context (~1.4) ≈ **7.9 GB**, overshooting by ~0.9 GB. No room for KV → crash.

### What is KV cache, in one line?
As the model generates text, it remembers ("caches") the math it already did for earlier
tokens (the "keys and values") so it doesn't redo it. More concurrent requests (`max-num-seqs`)
and longer context (`max-model-len`) → more to remember → bigger KV cache. So we can *shrink*
the KV requirement by lowering those two flags.

## The two things that made it fit

**1. `--enforce-eager` — delete bucket 3.**
This tells vLLM "don't build CUDA graphs, just run the model step-by-step (eagerly)." It's
slightly slower per request, but it **removes the ~0.5 GB graph cost *and* the profiler's
graph reservation**, handing that memory back to KV cache. On a card this tight, that swing
is the difference between negative and positive KV.

**2. Small KV footprint — shrink what bucket 4 needs.**
`--max-num-seqs=2` (at most 2 requests at once) and `--max-model-len=2048` (context cap) keep
the KV *requirement* tiny (~0.45 GB), so the modest leftover is enough.

## The budgets we landed on

Two facts drive the numbers:
- A 3B model needs **~7 GB minimum** just to start with usable KV.
- The **fully-promoted** state is **two 3B pods** on one 16 GB card → each must stay **≤ ~0.48**
  (because 2 × 0.48 × 16 = 15.4 GB, which fits; 2 × 0.50 = 16.0 GB is the absolute ceiling).

| Phase | Pods on the T4 | Budget sum | GB used | Fits 16 GB? |
|---|---|---|---|---|
| Stable only | 2 × 1B @ 0.25 | 0.50 | ~8.0 | ✅ |
| **Canary** (1 stable + 1 canary) | 1B @ 0.25 + 3B @ 0.48 | 0.73 | ~11.7 | ✅ |
| **Fully promoted** | 2 × 3B @ 0.48 | 0.96 | ~15.4 | ✅ (tight) |

The canary phase is only `1 stable + 1 canary` (not 2 + 1) because of the Rollout's
`maxSurge: 0` / `maxUnavailable: 1` — it scales a stable pod *down* to make room instead of
adding a third pod. Without that, three engines would fight over 16 GB and the canary would
starve (the first bug we hit).

## The flags, decoded

```
--gpu-memory-utilization=$(GPU_UTIL)  # this pod's share of the 16 GB (0.25 for 1B, 0.48 for 3B)
--enforce-eager                       # drop CUDA graphs → ~0.5 GB back to KV cache
--max-num-seqs=2                      # at most 2 concurrent requests → small KV requirement
--max-model-len=2048                  # context cap → bounds KV per request
--dtype=half                          # FP16; the T4 (Turing) has no bfloat16
```

## Rules of thumb to remember

- **FP16 weights ≈ 2 GB per billion parameters.** (1B ≈ 2 GB, 3B ≈ 6 GB, 7B ≈ 14 GB.)
- **`gpu-memory-utilization` is a share of the *whole* card**, not of free space — under
  time-slicing the shares must sum to < 1.0.
- **KV cache is the leftover** after weights + context + graphs. If it goes negative, the
  engine won't start — lower the model, raise the budget, or free memory with `--enforce-eager`.
- **Plan for the *worst* moment**, which here is full promotion (2 × the bigger model), not the
  canary step.
