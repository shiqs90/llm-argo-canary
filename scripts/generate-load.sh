#!/usr/bin/env bash
# Sends a request every 2s through the shared Service so traffic flows during the
# canary. Requests load-balance across stable + canary pods (that IS the 50/50 split
# at setWeight 50). The API model name stays "llama-chat" across versions — to see
# which pod answered each request, tail both pods' logs in another terminal:
#   kubectl logs -l app=llama-canary -f --prefix
set -euo pipefail

kubectl port-forward svc/llama-canary 8000:8000 >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null' EXIT
sleep 3

i=0
while true; do
  i=$((i + 1))
  OUT=$(curl -s --max-time 60 http://localhost:8000/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"llama-chat","messages":[{"role":"user","content":"One word: hello"}],"max_tokens":5}' \
    | sed -n 's/.*"content":"\([^"]*\)".*/\1/p')
  echo "req $i -> ${OUT:-<no response>}"
  sleep 2
done
