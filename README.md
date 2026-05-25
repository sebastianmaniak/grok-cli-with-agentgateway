# Grok (xAI) passthrough auth via AgentGateway on kind

Routes `/grok/*` on the AgentGateway proxy to `api.x.ai`, forwarding the client's
`Authorization` header untouched. No API key lives in the cluster.

Target cluster: `kind-grok-agentgateway` (already running OSS AgentGateway
`cr.agentgateway.dev/agentgateway:v1.2.0`, control plane in `agentgateway-system`).

## 0. Preflight

Verify the cluster has what's needed. Expect a `Gateway` named `agentgateway-proxy`
that is `Programmed=True`, and the GatewayClass `agentgateway` to be `ACCEPTED=True`.

```bash
kubectl config use-context kind-grok-agentgateway

kubectl get gatewayclass agentgateway
kubectl get gateway -n agentgateway-system agentgateway-proxy
kubectl get crd agentgatewaybackends.agentgateway.dev
```

If any of those are missing, install the OSS control plane first; this runbook
assumes they exist.

## 1. Why the existing manifest needs a one-field edit

`AgentgatewayBackend.yaml` in the repo uses:

```yaml
policies:
  auth:
    subscription:
      enabled: true
      passthrough: true
```

That `subscription` shape is Solo Enterprise (the `filintod/agwcode` feature
branch). The OSS v1alpha1 CRD on this cluster does **not** define a
`subscription` field. Its `auth` accepts exactly one of
`[key, secretRef, passthrough, aws, azure, gcp]` (enforced by a CEL rule), where
`passthrough` is an empty object. Semantically it's the same thing: the gateway
leaves the client's `Authorization` header intact and forwards it upstream.

## 2. Apply the corrected `AgentgatewayBackend`

Paste this whole block — it pipes the manifest directly into `kubectl apply`:

```bash
kubectl apply -f - <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: grok-xai
  namespace: agentgateway-system
spec:
  ai:
    groups:
    - providers:
      - name: xai-passthrough
        host: api.x.ai
        port: 443
        path: /v1/chat/completions
        openai: {}
        policies:
          auth:
            passthrough: {}
          tls: {}
EOF
```

Field-by-field rationale (verified against the live CRD with `kubectl explain
agentgatewaybackend.spec.ai.groups.providers`):

- `host` / `port` / `path` — top-level provider fields, no nesting under `openai`.
- `openai: {}` — selects the OpenAI request/response shape. Empty is correct;
  xAI exposes an OpenAI-compatible API, so no `model` override is needed.
- `policies.auth.passthrough: {}` — pass the client's `Authorization` through.
- `policies.tls: {}` — **required** to dial `api.x.ai:443` over HTTPS. Without
  this the proxy speaks plain HTTP to port 443 and Cloudflare returns a 400
  `"The plain HTTP request was sent to HTTPS port"`. Empty object is enough:
  system trusted CAs validate the server and SNI is set automatically from
  `host`.

## 3. Apply the `HTTPRoute`

The Gateway has no routes yet, so requests have nowhere to land:

```bash
kubectl apply -f - <<'EOF'
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
EOF
```

The `URLRewrite` strips `/grok` so the upstream sees the path defined on the
backend (`/v1/chat/completions`) rather than `/grok/v1/chat/completions`.

## 4. Verify

```bash
kubectl get agentgatewaybackend -n agentgateway-system
kubectl get httproute -n agentgateway-system grok -o yaml | yq '.status'
```

The HTTPRoute status should show `Accepted=True` and `ResolvedRefs=True` from
parent `agentgateway-proxy`. If `ResolvedRefs=False`, the backend name or group
is wrong — re-check step 2.

## 5. Get an xAI API key

Create one at <https://console.x.ai/> and export it locally. It is never sent to
the cluster:

```bash
export XAI_API_KEY=xai-...
```

## 6. Port-forward the proxy

The proxy `Service` fronts the Gateway's listener (port 80 inside the cluster):

```bash
kubectl port-forward -n agentgateway-system svc/agentgateway-proxy 8080:80
```

If the Service name differs, find it with
`kubectl get svc -n agentgateway-system` — the one owned by the Gateway will
have label `gateway.networking.k8s.io/gateway-name=agentgateway-proxy`.

## 7. Test

```bash
curl -sS http://localhost:8080/grok/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "grok-4-latest",
    "messages": [
      {"role": "system", "content": "You are a terse assistant."},
      {"role": "user", "content": "Say hi in five words."}
    ]
  }' | jq
```

Expected: a normal OpenAI-shaped `chat.completion` response from xAI. The key
never appears in any Kubernetes object — it travels client → proxy → `api.x.ai`
in the `Authorization` header only.

## 8. Verify it really is passthrough

Two quick checks:

1. **Wrong key fails with xAI's own 401**, not a gateway 401:
   ```bash
   curl -i http://localhost:8080/grok/v1/chat/completions \
     -H "Content-Type: application/json" \
     -H "Authorization: Bearer bogus" \
     -d '{"model":"grok-4-latest","messages":[{"role":"user","content":"hi"}]}'
   ```
   The error body should be xAI's JSON (`{"error": {...}}`), confirming the
   request reached the upstream.

2. **Missing key reaches xAI too** (gateway is not enforcing auth):
   ```bash
   curl -i http://localhost:8080/grok/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"model":"grok-4-latest","messages":[{"role":"user","content":"hi"}]}'
   ```
   xAI returns 401. If the gateway short-circuits with its own response, the
   `passthrough` field isn't taking effect — recheck the backend's
   `policies.auth`.

## 9. Cleanup

```bash
kubectl delete httproute -n agentgateway-system grok
kubectl delete agentgatewaybackend -n agentgateway-system grok-xai
```

## 10. Adding remote MCP servers through AgentGateway

You can route MCP (Model Context Protocol) traffic for external MCP servers through the same AgentGateway instance using the `mcp` section of `AgentgatewayBackend`. This gives you a single ingress point for both LLM (Grok) and MCP tool calls, with the same passthrough auth, TLS handling, and observability.

### 10.1 Create an `AgentgatewayBackend` for a remote MCP server

This example proxies a remote MCP server over Streamable HTTP (the modern default transport):

```bash
kubectl apply -f - <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: remote-mcp
  namespace: agentgateway-system
spec:
  mcp:
    targets:
    - name: external-mcp
      static:
        host: mcp.mycompany.com
        port: 443
        protocol: StreamableHTTP
        tls:
          sni: mcp.mycompany.com
    sessionRouting: Stateful
    failureMode: FailClosed
EOF
```

Field highlights:

- `spec.mcp.targets[].static` — use this for out-of-cluster hosts. For in-cluster MCP services, prefer `selector.services.matchLabels` with label selectors (see §10.3).
- `protocol: StreamableHTTP` — preferred transport. `SSE` is also supported for legacy servers.
- `path` — defaults to `/mcp` for StreamableHTTP and `/sse` for SSE; override if your server uses a different path.
- `tls.sni` — required for external HTTPS servers so the gateway can verify the server certificate. Set to the upstream hostname.
- `sessionRouting` — `Stateful` (default) keeps a session open across requests; set to `Stateless` if the upstream has no server-side state and each request is self-contained.

### 10.2 Create the `HTTPRoute`

```bash
kubectl apply -f - <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: mcp-route
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - name: remote-mcp
          group: agentgateway.dev
          kind: AgentgatewayBackend
EOF
```

Clients connect to `http://localhost:8080/mcp` (or whatever path you match on).

### 10.3 MCP federation — multiple servers behind one endpoint

AgentGateway can aggregate tools from many MCP servers behind a single `/mcp` endpoint. Clients see a unified namespace of tools, and you can filter access per client identity.

**Explicit multi-target backend:**

```bash
kubectl apply -f - <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: federated-mcp
  namespace: agentgateway-system
spec:
  mcp:
    targets:
    - name: external-mcp
      static:
        host: mcp.mycompany.com
        port: 443
        protocol: StreamableHTTP
        tls:
          sni: mcp.mycompany.com
    - name: filesystem-mcp
      stdio:
        cmd: npx
        args: ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
    sessionRouting: Stateful
    failureMode: FailClosed
EOF
```

Both servers' tools appear under the same route. The `stdio` target spawns a local subprocess; the `static` target proxies to a remote host.

**Selector-based federation (in-cluster services):**

If MCP servers run inside the cluster as Kubernetes Services, use label selectors to auto-discover them:

```bash
kubectl apply -f - <<'EOF'
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayBackend
metadata:
  name: federation-mcp
  namespace: agentgateway-system
spec:
  mcp:
    targets:
    - name: mcp-servers
      selector:
        services:
          matchLabels:
            mcp-federation: "true"
    sessionRouting: Stateful
    failureMode: FailClosed
EOF
```

Label your MCP Services so the selector picks them up:

```bash
kubectl label service my-mcp-service -n default mcp-federation=true
kubectl annotate service my-mcp-service -n default appProtocol=agentgateway.dev/mcp
```

This only works with StreamableHTTP for selector-based discovery.

### 10.4 Test the MCP route

Use any MCP-compatible client (Claude Desktop, Cursor, VS Code with the MCP extension) and point it at:

```
http://localhost:8080/mcp
```

Or test with `curl` (MCP over Streamable HTTP uses SSE negotiation on the first request):

```bash
curl -sS -N http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Mcp-Protocol: 2024-11-05"
```

You should get back an SSE stream with an initialization message. Follow the MCP handshake to list tools or call them.

### 10.5 Point an MCP client at the gateway

Configure your MCP client's transport URL to the gateway endpoint:

| Client | Transport | URL |
|---|---|---|
| Claude Desktop | Streamable HTTP | `http://localhost:8080/mcp` |
| Cursor | Streamable HTTP | `http://localhost:8080/mcp` |
| VS Code MCP extension | Streamable HTTP | `http://localhost:8080/mcp` |
| `mcp-cli` / `npx @modelcontextprotocol/cli` | Streamable HTTP | `http://localhost:8080/mcp` |

The gateway handles session management, TLS verification of upstream servers, and forwards the client's auth headers (if configured with passthrough auth on the MCP targets).

### 10.6 MCP federation via the Standalone mode (optional)

If you prefer not to use Kubernetes Gateway API, AgentGateway's standalone mode lets you configure MCP backends in a single YAML file:

```yaml
# yaml-language-server: $schema=https://agentgateway.dev/schema/config
binds:
- port: 3000
  listeners:
  - routes:
    - policies:
        cors:
          allowOrigins: ["*"]
          allowHeaders: [mcp-protocol-version, content-type, cache-control]
          exposeHeaders: ["Mcp-Session-Id"]
      backends:
      - mcp:
          targets:
          - name: everything
            stdio:
              cmd: npx
              args: ["@modelcontextprotocol/server-everything"]
          - name: remote
            mcp:
              host: https://mcp.mycompany.com/mcp
```

Run with `agentgateway -f config.yaml` — the Admin UI appears at `http://localhost:15000/ui/`. This mode is great for local development or single-instance deployments where Kubernetes is overkill.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `apply` fails with CEL message "exactly one of [key secretRef passthrough aws azure gcp] must be set" | More than one auth method set, or `subscription:` left in by mistake | Keep only `passthrough: {}` under `auth` |
| 404 from proxy | HTTPRoute not Accepted, or path mismatch | `kubectl get httproute grok -o yaml` — check `status.parents[].conditions` |
| 400 with `server: cloudflare` and HTML body "The plain HTTP request was sent to HTTPS port" | Backend missing `policies.tls: {}` — proxy is dialing port 443 in plaintext | Add `tls: {}` under `policies` (see step 2) and re-apply |
| 502 / connection refused upstream | Outbound HTTPS from kind blocked, or DNS for `api.x.ai` not resolving from inside the cluster | `kubectl run -it --rm dns --image=busybox -- nslookup api.x.ai`; check kind network |
| Got an xAI 401 even with a good key | Header stripped before passthrough (another auth policy applied earlier) | This config has no upstream auth policies; confirm no `EnterpriseAgentgatewayPolicy` of kind `auth` targets this Gateway |

## Notes on enterprise vs OSS

If/when this cluster is upgraded to Solo Enterprise AgentGateway, the
`auth.subscription.passthrough: true` shape from the upstream `agw-proxy.md`
example becomes available and is the preferred form — it integrates with the
Solo UI's subscription/quota tracking. The OSS `auth.passthrough: {}` used here
produces the same on-the-wire behavior but does not register a subscription.
