# ZeroClaw Config Reference

All top-level config sections available in `config.toml`. Based on upstream v0.1.7.

| Section | Description | In template? | Notes |
|---------|-------------|:---:|-------|
| `api_key` / `api_url` | Provider API credentials | no | via env vars |
| `default_provider` | LLM provider | yes | `"openrouter"` |
| `default_model` | Default model | yes | `${DEFAULT_MODEL}` |
| `default_temperature` | Temperature | yes | `0.7` |
| `provider` | Provider-specific overrides | no | |
| `observability` | Logging/tracing | no | |
| `autonomy` | Permissions, approvals, risk | yes | full autonomy, high-risk commands require approval |
| `security` | Security policy | no | |
| `runtime` | Native vs Docker execution | no | |
| `research` | Proactive info gathering | no | |
| `reliability` | Retries, fallback providers | no | |
| `scheduler` | Periodic task execution | no | enabled by default upstream |
| `agent` | Orchestration settings | yes | 50 max tool iterations, parallel tools on |
| `skills` | Skills loading | yes | community open-skills enabled |
| `model_routes` | Route hints to provider+model | no | |
| `embedding_routes` | Embedding routing | no | |
| `query_classification` | Auto-classify messages to models | no | useful for cost optimization |
| `heartbeat` | Health pings | yes | 15 min interval |
| `cron` | Cron jobs | no | enabled by default upstream |
| `goal_loop` | Autonomous goal execution | yes | enabled, defaults (10min, 3 steps) |
| `channels_config` | Channel enablement | yes | Telegram only |
| `memory` | Memory backends | no | |
| `storage` | Storage providers | no | |
| `tunnel` | Tunneling | no | |
| `gateway` | Webhook/gateway + dashboard | yes | public bind, pairing required |
| `composio` | OAuth tool integrations | yes | |
| `secrets` | Secret encryption | no | |
| `browser` | Browser automation | yes | agent_browser backend |
| `http_request` | HTTP requests | yes | all domains |
| `multimodal` | Image/audio handling | yes | remote fetch enabled |
| `web_fetch` | Web page content reader | yes | all domains |
| `web_search` | Web search | yes | DuckDuckGo (free) |
| `proxy` | Proxy settings | no | |
| `identity` | Identity config | no | |
| `cost` | Cost tracking | no | |
| `economic` | Token pricing | no | |
| `peripherals` | Hardware peripherals | no | |
| `agents` | Delegate sub-agents | no | |
| `coordination` | Multi-agent coordination | no | local only |
| `hooks` | Lifecycle hooks | no | |
| `plugins` | Plugin system | no | enabled by default upstream |
| `hardware` | Hardware config | no | |
| `transcription` | Audio transcription | no | |
| `agents_ipc` | Inter-agent comms | no | same-host only |
| `mcp` | Model Context Protocol | no | |
| `wasm` | WASM runtime | no | |

## Template values

| Key | Value | Why |
|-----|-------|-----|
| `autonomy.level` | `"full"` | Managed bot, no interactive CLI |
| `autonomy.block_high_risk_commands` | `false` | Allow but require approval via context rules |
| `autonomy.command_context_rules` | `require_approval` for rm, sudo, dd, chmod, chown, mkfs, shutdown, reboot | Safety gate for destructive commands |
| `agent.max_tool_iterations` | `50` | Allow complex multi-step tasks |
| `agent.parallel_tools` | `true` | Faster execution with capable models |
| `gateway.allow_public_bind` | `true` | Required for Railway deployment |
| `gateway.require_pairing` | `true` | Dashboard/API access needs bearer token |
| `web_search.provider` | `"duckduckgo"` | Free, no API key needed |
| `goal_loop.enabled` | `true` | Autonomous goal pursuit with defaults |
| `multimodal.allow_remote_fetch` | `true` | Bot can read images from URLs |
| `skills.open_skills_enabled` | `true` | Community skills repo loaded |
