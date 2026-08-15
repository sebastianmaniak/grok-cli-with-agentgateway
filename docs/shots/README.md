# Screenshots / GIFs

Captures from the standalone box we actually ran. The [README](../../README.md) embeds these on the exact paths below. Nothing here is a cluster screenshot, a real API key, or a claim that MCP is wired.

## Stills

| File | What |
| --- | --- |
| `curl-run.png` | Two dummy-token curls through `:4003` — `4` and `Paris` |
| `grok-config.png` | `~/.grok/config.toml` — custom model `agw`, dummy `env_key` |
| `agw-ui.png` | agentgateway Analytics http://127.0.0.1:14011/ui — $0.0044 / 623 tokens / 2 calls |
| `agw-logs.png` | agentgateway Logs — two `CHAT` / `200` rows, `grok-4-latest` → `grok-4.3`, provider `xai` |
| `agw-admin.png` | Gateway Overview — LLM enabled, MCP not enabled |

## Clips

| File | What |
| --- | --- |
| `curl-run.gif` | Two dummy-token curls: `4` then `Paris` |
| `grok-config.gif` | Point Grok Build at `http://127.0.0.1:4003/v1` |
| `agw-costs.gif` | Admin UI — Overview → Analytics → Logs |
| `agw-logs.gif` | Analytics then Logs |

The README uses them in step order: `curl-run.gif` up top → curl proof → Analytics + `agw-costs.gif` + Logs → Grok Build `grok-config.gif`.
