# Same thing on Kubernetes

The standalone setup is the [main README](../README.md) — that is what we actually ran. This page is the same pattern on a cluster: the client talks OpenAI-compat with a dummy token, and the real xAI key lives only in a Kubernetes Secret on the gateway. Cost catalog and traces stay on the gateway.

The manifests are files in [`k8s/`](../k8s/), not snippets on this page. See [`k8s/README.md`](../k8s/README.md) for the file-by-file map.

> **Untested.** No cluster was stood up for this repo, so there are no screenshots here. The CRDs mirror the official agentgateway Kubernetes docs (1.4.x): `Secret`, `AgentgatewayBackend`, `HTTPRoute`, `AgentgatewayParameters`, `AgentgatewayPolicy`. The older, tested kind runbook (OSS passthrough, client holds the key) is [grok-passthrough-kind.md](grok-passthrough-kind.md).

On Kubernetes, xAI is configured as an OpenAI-compatible provider (`ai.provider.openai` → `api.x.ai`). Standalone has a first-class `provider: xai`. Same upstream.

## Before you begin

- A cluster, `kubectl`, and `helm`. Kind is enough: `kind create cluster`.
- `agctl`, for the cost catalog import.
- Your xAI key in `$XAI_API_KEY` or the same mode-600 `.secrets/xai.env` that `start-agw.sh` uses.

## Step 1: Install

```bash
./k8s/install.sh
```

That script pins **v1.4.1** and does every step below in order: Gateway API CRDs, the agentgateway CRD and controller charts, the Secret, the cost-catalog ConfigMap, then `k8s/*.yaml`. Prefer to run it by hand? The commands are in [`k8s/README.md`](../k8s/README.md#install).

Two things are built at install time and never committed:

| Not in git | Why | Where it comes from |
| --- | --- | --- |
| `xai-secret` | Real key | `kubectl create secret ... --from-literal=Authorization="$XAI_API_KEY"` |
| `xai-costs` ConfigMap | Generated | `agctl costs import --source models.dev --providers xai` |

## Step 2: Point Grok Build at the gateway

```bash
kubectl port-forward -n agentgateway-system deploy/agentgateway-proxy 8080:80
export GATEWAY_API_KEY=local-grok-not-xai
```

```toml
[model.agw]
model = "grok-4-latest"
base_url = "http://127.0.0.1:8080/v1"
env_key = "GATEWAY_API_KEY"
```

Or curl, same dummy token:

```bash
curl -sS http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $GATEWAY_API_KEY" \
  -d '{"model":"grok-4-latest","messages":[{"role":"user","content":"What is 2+2? Reply with just the number."}]}' | jq
```

In-cluster, the same dummy token against `http://agentgateway-proxy.agentgateway-system.svc/v1`. There is no Grok Build Deployment in this repo.

The full curl walkthrough — dummy token, `grok-4-latest` → `grok-4.3` — is [Step 5 of the main README](../README.md#step-5-prove-it-with-curl). Same form, same gotchas; only the base URL differs.

## What's different from standalone

| | Standalone | Kubernetes |
| --- | --- | --- |
| Real key | mode-600 `.secrets/xai.env` | `xai-secret` Secret, `Authorization` key |
| Config | [`agentgateway.yaml`](../agentgateway.yaml) | [`k8s/*.yaml`](../k8s/) CRDs |
| xAI provider shape | first-class `provider: xai` | `ai.provider.openai` + `host: api.x.ai` + TLS SNI |
| Cost catalog | `config.modelCatalog` → local file | ConfigMap + `AgentgatewayParameters` on the **Gateway** (a GatewayClass catalog is ignored) |
| Client base URL | `http://127.0.0.1:4003/v1` | `http://127.0.0.1:8080/v1` (port-forward) |
| Admin UI | http://127.0.0.1:14011/ui | port-forward `15000` → http://127.0.0.1:15000/ui |
| Jaeger | `docker run` all-in-one | [`k8s/00-jaeger.yaml`](../k8s/00-jaeger.yaml), port-forward `16686` |

## Where to look

Ports are the controller defaults, not standalone `14011` / `4003`.

| What | Where |
| --- | --- |
| OpenAI-compat | `http://127.0.0.1:8080/v1` (port-forward `deploy/agentgateway-proxy 8080:80`) |
| Admin UI | `kubectl port-forward -n agentgateway-system deploy/agentgateway-proxy 15000` → http://127.0.0.1:15000/ui |
| Jaeger | `kubectl port-forward -n telemetry svc/jaeger-ui 16686:16686` → http://127.0.0.1:16686 |

## OSS passthrough instead

If you want the gateway to forward the client's own `Authorization` and never hold `XAI_API_KEY` in-cluster, that is [grok-passthrough-kind.md](grok-passthrough-kind.md). Same host/TLS gotchas, different auth shape (`passthrough: {}` on OSS).

No real key in git. No Secret manifests. No cluster screenshots. MCP is not wired.
