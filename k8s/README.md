# Kubernetes manifests

The same pattern as the standalone [README](../README.md), as files you can apply. Grok Build (or curl) talks OpenAI-compat with a dummy token; the real xAI key lives only in a Kubernetes Secret on the gateway.

> **Untested.** No cluster was stood up for this repo — the standalone path is the one we actually ran. These manifests mirror the CRDs in the official agentgateway Kubernetes docs (1.4.x) and the walkthrough in [../docs/kubernetes.md](../docs/kubernetes.md). Expect to adjust field names if you are on a different version.

On Kubernetes, xAI is an OpenAI-compatible provider (`ai.provider.openai` pointed at `api.x.ai`). Standalone has a first-class `provider: xai`. Same upstream, different CRD shape. Docs: [OpenAI-compatible providers](https://agentgateway.dev/docs/kubernetes/latest/llm/providers/openai-compatible/).

## Files

| File | What | Standalone equivalent in [`agentgateway.yaml`](../agentgateway.yaml) |
| --- | --- | --- |
| [`00-jaeger.yaml`](00-jaeger.yaml) | Jaeger all-in-one — Namespace, Deployment, OTLP + UI Services | the `docker run` in Step 3 |
| [`10-gateway.yaml`](10-gateway.yaml) | `AgentgatewayParameters` (cost catalog) + `Gateway` | `config.modelCatalog`, `gateways.default` |
| [`20-xai-backend.yaml`](20-xai-backend.yaml) | `AgentgatewayBackend` (xAI + auth + TLS) + `HTTPRoute` for `/v1` | `llm.models` |
| [`30-tracing-policy.yaml`](30-tracing-policy.yaml) | `AgentgatewayPolicy` — traces to Jaeger | `config.tracing` |
| [`install.sh`](install.sh) | Everything below, in order | [`start-agw.sh`](../start-agw.sh) |

## Not in this repo

Two things are generated at install time, never committed:

- **The Secret.** The real xAI key goes in `xai-secret` under the `Authorization` key, created from your shell. There is no Secret manifest here on purpose.
- **The cost catalog.** `costs/catalog.json` comes from `agctl costs import` and is gitignored. It becomes the `xai-costs` ConfigMap.

## Install

Scripted — reuses the same mode-600 key file as `start-agw.sh`:

```bash
./k8s/install.sh
```

Or by hand. Order matters: the ConfigMap must exist before the Gateway that references it, and the Secret before the backend.

```bash
export GWAPI_VERSION=1.6.0
kubectl apply --server-side --force-conflicts \
  -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v$GWAPI_VERSION/standard-install.yaml

helm upgrade -i agentgateway-crds oci://cr.agentgateway.dev/charts/agentgateway-crds \
  --create-namespace --namespace agentgateway-system --version v1.4.1
helm upgrade -i agentgateway oci://cr.agentgateway.dev/charts/agentgateway \
  --namespace agentgateway-system --version v1.4.1 --wait

kubectl -n agentgateway-system create secret generic xai-secret \
  --from-literal=Authorization="$XAI_API_KEY"

agctl costs import --source models.dev --providers xai --out ./costs/catalog.json
kubectl -n agentgateway-system create configmap xai-costs \
  --from-file=catalog.json=./costs/catalog.json

kubectl apply -f k8s/
```

## Connect Grok Build / curl

```bash
kubectl port-forward -n agentgateway-system deploy/agentgateway-proxy 8080:80
export GATEWAY_API_KEY=local-grok-not-xai
curl -sS http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $GATEWAY_API_KEY" \
  -d '{"model":"grok-4-latest","messages":[{"role":"user","content":"What is 2+2? Reply with just the number."}]}' | jq
```

`~/.grok/config.toml` — same dummy token, only the base URL changes:

```toml
[model.agw]
model = "grok-4-latest"
base_url = "http://127.0.0.1:8080/v1"
env_key = "GATEWAY_API_KEY"
```

In-cluster, the same dummy token against `http://agentgateway-proxy.agentgateway-system.svc/v1`. There is no Grok Build Deployment in this repo.

The curl walkthrough — dummy token, `grok-4-latest` → `grok-4.3` — is [Step 5 of the main README](../README.md#step-5-prove-it-with-curl). Only the host:port differs.

## Notes

- **Ports are the controller defaults**, not the standalone `14011` / `4003`. Admin UI: `kubectl port-forward -n agentgateway-system deploy/agentgateway-proxy 15000` → http://127.0.0.1:15000/ui. Jaeger: `kubectl port-forward -n telemetry svc/jaeger-ui 16686:16686`.
- **The cost catalog must be attached to the Gateway** via `AgentgatewayParameters`. A GatewayClass-level catalog is ignored.
- **TLS + SNI on `api.x.ai:443` is required.** Without `policies.tls.sni: api.x.ai` the proxy speaks plain HTTP to 443 and Cloudflare returns 400.
- **The tracing policy points across namespaces** (`agentgateway-system` → `telemetry`). If traces never arrive, check whether your version wants a `ReferenceGrant` in `telemetry` for that reference.
- **OSS passthrough** (client holds the key) is a different pattern: [../docs/grok-passthrough-kind.md](../docs/grok-passthrough-kind.md).
- **MCP is not wired**, here or standalone.
