# LangChain Chat Agent — deployment smoke test

A deliberately small chat agent for verifying that an Agent Manager install works **end to end**: build → image push → deploy → invoke.

It is a smoke test, not a reference architecture. Conversation history is an in-process dict, so it is lost on restart and inconsistent across replicas.

| | |
|---|---|
| Framework | LangChain (`langchain-anthropic`, which wraps the official Anthropic SDK) |
| Model | `claude-opus-5` (override with `ANTHROPIC_MODEL`) |
| Server | FastAPI + uvicorn, listening on `$PORT` (default `8080`) |
| Build | Google Cloud Buildpacks (`gcr.io/buildpacks/builder`) — `pyproject.toml` + `requirements.txt`, no Dockerfile needed |

## What it exposes

| Method | Path | Purpose |
|---|---|---|
| `POST` | `/chat` | `{"message": "...", "session_id": "default"}` → `{"reply", "session_id", "model"}` |
| `DELETE` | `/chat/{session_id}` | Clear a conversation |
| `GET` | `/healthz` | Liveness. Does **not** call the model, so it stays green without spending tokens |

## Deploying it

The agent's port, path and schema are configured **in the Agent Manager console**, not in a file in this repo — the build's `generate-workload` step takes them as parameters. The one exception is the endpoint schema, which it reads from the checked-out source.

1. Push this directory to a Git repository the platform can reach.
2. In the console, create an agent from that repo. If the sample is in a subdirectory, set the app path to `/samples/langchain-chat-agent`.
3. Configure the endpoint:
   - **Port** `8080`
   - **Schema file path** `/openapi.yaml` — this is what makes the console's try-out render a form instead of a raw body
4. Set the environment variables below.
5. Build, then deploy.

### Environment variables

| Variable | Required | Notes |
|---|---|---|
| `LLM_BASE_URL` | one of these two | Route model calls through the environment's embedded gateway LLM proxy |
| `ANTHROPIC_API_KEY` | one of these two | Call the Anthropic API directly instead — this is the local-development path |
| `LLM_AUTH_HEADER` | no | Header the key is sent in. Unset = the SDK's `x-api-key` |
| `LLM_AUTH_KEY` | no | Key for that header. Falls back to `ANTHROPIC_API_KEY` |
| `ANTHROPIC_MODEL` | no | Defaults to `claude-opus-5` |
| `SYSTEM_PROMPT` | no | Defaults to a "be concise" instruction |
| `MAX_TOKENS` | no | Defaults to `16000` |

With neither set, `/chat` returns `503` naming both options and the container still starts.

`ANTHROPIC_BASE_URL` and `ANTHROPIC_API_URL` work too — those are the names the Anthropic SDK and `langchain-anthropic` already recognise. `LLM_BASE_URL` is checked first so the platform's own variable name can be mapped onto it without editing code.

### Routing through the gateway

In Agent Manager, LLM traffic is proxied through the environment's embedded gateway rather than going straight to `api.anthropic.com`. That is what applies the platform's governance — token and cost-based rate limiting, guardrails — and what makes model calls visible in the console. Set `LLM_BASE_URL` to the gateway's LLM proxy endpoint and the agent needs no code change.

Behind the proxy the upstream provider credential is held by **the gateway, not the agent** — the agent presents a gateway-issued key instead, and the gateway swaps in the real provider credential on the way out.

The header that key travels in is configurable, because it is the gateway's choice and it is **not** the SDK's default. The Anthropic SDK sends its key as `x-api-key`, whereas the platform's own API keys are read from `x-amp-api-key` — that is the header configured on the gateway's `otel` RestApi. So for a gateway-issued key:

```
LLM_BASE_URL=<gateway LLM proxy endpoint>
LLM_AUTH_HEADER=x-amp-api-key
LLM_AUTH_KEY=<key created at the gateway>
```

The custom header is sent *in addition to* the SDK's `x-api-key`, not instead of it — the gateway reads whichever it is configured for and ignores the other. If no key is set at all, the sample sends a placeholder so the SDK can construct.

### Tracing

There is deliberately **no OpenTelemetry setup in this sample.** Agent Manager instruments deployed agents itself; traces reach the platform through the embedded gateway, not from an exporter inside the process. Adding one would duplicate spans and introduce a credential for no gain.

## Testing it

Once deployed, the invoke URL is `http://<org>-<project>.agents.<base-domain>:<port>`. On a local install add a hosts entry for it first:

```shell
scripts/amp-hosts.sh add <project>
```

```shell
curl -s -X POST http://default-<project>.agents.local.apis.coach:19080/chat \
  -H 'Content-Type: application/json' \
  -d '{"message":"Hello! Which model are you?"}' | jq
```

Expect:

```json
{ "reply": "...", "session_id": "default", "model": "claude-opus-5" }
```

Then check the console's Traces view — the platform records the call itself.

## Running it locally

```shell
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
export ANTHROPIC_API_KEY=sk-ant-...
PORT=8099 python main.py   # 8080 is taken by the control-plane gateway
curl -s -X POST localhost:8099/chat -H 'Content-Type: application/json' \
  -d '{"message":"hi"}' | jq
```

Interactive API docs are at `http://localhost:8099/docs`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `503` "No model endpoint configured" | Neither `LLM_BASE_URL` nor `ANTHROPIC_API_KEY` is set on the agent |
| `502` with a `401`/`403` from the gateway | The key is going to the wrong header — set `LLM_AUTH_HEADER` to what the gateway expects |
| `502` with an exception name | The model call itself failed — the detail carries the upstream error verbatim |
| Build fails at image push | Registry not reachable or not trusted by the node — see the registry section of the repository README |
| Agent runs, Traces view empty | Model calls are bypassing the gateway — check `LLM_BASE_URL` is set and points at the LLM proxy |
| `422` on `/chat` | Body is missing `message` |

## Build files and entrypoint

Agent Manager builds with Google Cloud Buildpacks. Its Python group runs `google.python.runtime` (required), then `google.python.pip`, `google.python.webserver` and `google.config.entrypoint` — the last three all optional. Three files matter:

| File | Role |
|---|---|
| `pyproject.toml` | Project metadata and dependencies. What the runtime buildpack detects and installs from when the Procfile is not honoured. |
| `requirements.txt` | The pip path. **Takes precedence** over `pyproject.toml` when both exist, per Google's docs — so the two dependency lists must be kept in sync. |
| `Procfile` | Entrypoint hint. Documented as supported, but **not honoured in this platform's build**, which is why `main.py` also has a `__main__` block. |

Because the Procfile can be ignored, `main.py` ends with a `uvicorn.run(...)` guard so a plain `python main.py` starts the server on `$PORT`, binding `0.0.0.0`. If you need to force the command at build time instead, set the build environment variable:

```
GOOGLE_ENTRYPOINT=uvicorn main:app --host 0.0.0.0 --port ${PORT:-8080}
```

> [!IMPORTANT]
>
> Adding a dependency to `pyproject.toml` alone will **not** install it — `requirements.txt` wins. Edit both.

## Notes

- `claude-opus-5` runs **adaptive thinking by default**, so a response's `content` is a list of blocks rather than a string. `text_of()` handles both and drops thinking blocks. Do not add a `budget_tokens` thinking config — it is rejected with a 400 on this model family.
- Both dependency files use lower bounds so the buildpack takes the newest compatible release. Pin exact versions if you need reproducible builds.
- Verified locally against `langchain-anthropic` 1.7.0, `langchain-core` 1.6.1, `anthropic` 1.2.0, `fastapi` 0.141.1.
