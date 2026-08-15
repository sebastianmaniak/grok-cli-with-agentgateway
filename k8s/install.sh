#!/usr/bin/env bash
# Install agentgateway on Kubernetes and apply the manifests next to this script.
#
# Same shape as ../start-agw.sh: the real xAI key comes from a mode-600 file
# (or the env) and is handed straight to the cluster as a Secret. It is never
# written to a manifest in this repo.
#
#   ./k8s/install.sh
#
# Env overrides:
#   AGW_VERSION      agentgateway chart version (default v1.4.1)
#   GWAPI_VERSION    Gateway API version (default 1.6.0)
#   NAMESPACE        gateway namespace (default agentgateway-system)
#   AGW_SECRET_FILE  key file (default ../.secrets/xai.env)
#   SKIP_TRACING=1   skip Jaeger and the tracing policy
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

AGW_VERSION="${AGW_VERSION:-v1.4.1}"
GWAPI_VERSION="${GWAPI_VERSION:-1.6.0}"
NAMESPACE="${NAMESPACE:-agentgateway-system}"
SECRET="${AGW_SECRET_FILE:-$ROOT/.secrets/xai.env}"

for bin in kubectl helm; do
  command -v "$bin" >/dev/null || { echo "missing $bin" >&2; exit 1; }
done

# Real key: env first, else the 600 file. Same file start-agw.sh uses.
if [[ -z "${XAI_API_KEY:-}" ]]; then
  if [[ ! -f "$SECRET" ]]; then
    echo "missing $SECRET and XAI_API_KEY is unset" >&2
    echo "create it with mode 600 and one line: export XAI_API_KEY=..." >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  set -a; . "$SECRET"; set +a
fi

if [[ -z "${XAI_API_KEY:-}" ]]; then
  echo "XAI_API_KEY is empty" >&2
  exit 1
fi

echo "==> Gateway API $GWAPI_VERSION"
kubectl apply --server-side --force-conflicts \
  -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/standard-install.yaml"

echo "==> agentgateway $AGW_VERSION"
helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace "$NAMESPACE" --version "$AGW_VERSION"
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace "$NAMESPACE" --version "$AGW_VERSION" --wait

# Secret, built in memory from the key above. Never rendered to a file in git.
echo "==> xai-secret (key: Authorization)"
kubectl -n "$NAMESPACE" create secret generic xai-secret \
  --from-literal=Authorization="$XAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# Cost catalog. Generated, gitignored, same import as the standalone README.
CATALOG="$ROOT/costs/catalog.json"
if [[ ! -f "$CATALOG" ]]; then
  command -v agctl >/dev/null || { echo "missing agctl, needed to build $CATALOG" >&2; exit 1; }
  echo "==> importing cost catalog"
  mkdir -p "$ROOT/costs"
  agctl costs import --source models.dev --providers xai --out "$CATALOG"
fi
echo "==> xai-costs ConfigMap"
kubectl -n "$NAMESPACE" create configmap xai-costs \
  --from-file=catalog.json="$CATALOG" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> manifests"
if [[ "${SKIP_TRACING:-0}" != "1" ]]; then
  kubectl apply -f "$HERE/00-jaeger.yaml"
fi
kubectl apply -f "$HERE/10-gateway.yaml"
kubectl apply -f "$HERE/20-xai-backend.yaml"
if [[ "${SKIP_TRACING:-0}" != "1" ]]; then
  kubectl apply -f "$HERE/30-tracing-policy.yaml"
fi

cat <<HINT

Done. Dummy token in, real key only in xai-secret.

  kubectl port-forward -n $NAMESPACE deploy/agentgateway-proxy 8080:80
  export GATEWAY_API_KEY=local-grok-not-xai
  curl -sS http://127.0.0.1:8080/v1/chat/completions \\
    -H "Content-Type: application/json" \\
    -H "Authorization: Bearer \$GATEWAY_API_KEY" \\
    -d '{"model":"grok-4-latest","messages":[{"role":"user","content":"What is 2+2? Reply with just the number."}]}' | jq

Admin UI:  kubectl port-forward -n $NAMESPACE deploy/agentgateway-proxy 15000
           http://127.0.0.1:15000/ui
Jaeger:    kubectl port-forward -n telemetry svc/jaeger-ui 16686:16686

Grok Build ~/.grok/config.toml:
  [model.agw]
  model = "grok-4-latest"
  base_url = "http://127.0.0.1:8080/v1"
  env_key = "GATEWAY_API_KEY"

HINT
