# Same thing on Kubernetes

The standalone setup is the [main README](../README.md) — that is what we actually ran. This page is the same pattern on a cluster: the client talks OpenAI-compat with a dummy token, and the real xAI key lives only in a Kubernetes Secret on the gateway. Cost catalog and traces stay on the gateway.

> **Untested as dummy-token + Secret.** No cluster was stood up for this rewrite. The older, tested kind runbook (OSS passthrough, client holds the key) is [grok-passthrough-kind.md](grok-passthrough-kind.md).

## Before you begin

- A cluster, `kubectl`, and `helm`. Kind is enough: `kind create cluster`.
- `agctl`, for the cost catalog import.
- Your xAI key in `$XAI_API_KEY` or the same mode-600 `.secrets/xai.env` that `start-agw.sh` uses.

## The dummy-token pattern

Create the Secret from the env, never from a file in git:

```bash
kubectl create namespace agentgateway-system --dry-run=client -o yaml | kubectl apply -f -
kubectl -n agentgateway-system create secret generic xai-secret \
  --from-literal=Authorization="$XAI_API_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
```

Backend (xAI, OpenAI-compat contract, TLS required on 443):

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: grok-xai
  namespace: agentgateway-system
spec:
  ai:
    groups:
    - providers:
      - name: xai
        host: api.x.ai
        port: 443
        path: /v1/chat/completions
        openai: {}
        policies:
          auth:
            secretRef:
              name: xai-secret
          tls: {}
```

Route. Strip `/grok` so the upstream sees `/v1/chat/completions`:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grok
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /grok
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: grok-xai
          group: agentgateway.dev
          kind: AgentgatewayBackend
```

Point Grok Build or curl at the port-forward with the dummy token:

```bash
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
export GATEWAY_API_KEY=local-grok-not-xai
curl -sS http://127.0.0.1:8080/grok/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $GATEWAY_API_KEY" \
  -d '{"model":"grok-4-latest","messages":[{"role":"user","content":"hi"}]}' | jq
```

`~/.grok/config.toml` uses `base_url = "http://127.0.0.1:8080/grok/v1"` and the same dummy `env_key`.

## What's different from standalone

| | Standalone | Kubernetes |
| --- | --- | --- |
| Real key | mode-600 `.secrets/xai.env` | `xai-secret` Secret, `Authorization` key |
| Config | [`agentgateway.yaml`](../agentgateway.yaml) | `AgentgatewayBackend` + `HTTPRoute` |
| Client base URL | `http://127.0.0.1:4003/v1` | `http://127.0.0.1:8080/grok/v1` (port-forward) |
| Admin UI | http://127.0.0.1:14011/ui | port-forward the proxy admin |

## OSS passthrough instead

If you want the gateway to forward the client's own `Authorization` and never hold `XAI_API_KEY` in-cluster, that is [grok-passthrough-kind.md](grok-passthrough-kind.md). Same host/TLS gotchas, different auth shape (`passthrough: {}` on OSS).

No real key in git. No Secret manifests. MCP is not wired.
