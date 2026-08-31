# LangChain Chat Agent — deployment smoke test

A deliberately small chat agent for verifying that an Agent Manager install works **end to end**: build → image push → deploy → invoke → trace.

It is a smoke test, not a reference architecture. Conversation history is an in-process dict, so it is lost on restart and inconsistent across replicas.

| | |
|---|---|
| Framework | LangChain (`langchain-anthropic`, which wraps the official Anthropic SDK) |
| Model | `claude-opus-5` (override with `ANTHROPIC_MODEL`) |
| Server | FastAPI + uvicorn, listening on `$PORT` (default `8080`) |
| Build | Google Cloud / Paketo buildpacks — `requirements.txt` + `Procfile`, no Dockerfile needed |

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
| `ANTHROPIC_API_KEY` | **yes** | Without it `/chat` returns `503` with a message saying so, and the container still starts |
| `INSTRUMENTATION_URL` | no | The platform's OTLP ingest base (ends in `/otel`); the exporter appends `/v1/traces` |
| `AMP_API_KEY` | no | Sent as `x-amp-api-key`. **Mint a fresh one after every platform upgrade** — keys do not survive one |
| `ANTHROPIC_MODEL` | no | Defaults to `claude-opus-5` |
| `SYSTEM_PROMPT` | no | Defaults to a "be concise" instruction |
| `MAX_TOKENS` | no | Defaults to `16000` |

Tracing is enabled only when `INSTRUMENTATION_URL` **and** `AMP_API_KEY` are both set, and it fails soft — a broken exporter never stops the agent answering.

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

Then confirm traces arrived — count documents in the day's index rather than trusting the console:

```shell
kubectl exec -n openchoreo-observability-plane opensearch-master-0 -c opensearch -- \
  curl -sk -u admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD \
  "https://localhost:9200/_cat/indices?v" | grep otel-traces
```

## Running it locally

```shell
python3 -m venv .venv && . .venv/bin/activate
pip install -r requirements.txt
export ANTHROPIC_API_KEY=sk-ant-...
uvicorn main:app --port 8080
curl -s -X POST localhost:8080/chat -H 'Content-Type: application/json' \
  -d '{"message":"hi"}' | jq
```

Interactive API docs are at `http://localhost:8080/docs`.

## Troubleshooting

| Symptom | Cause |
|---|---|
| `503` with "ANTHROPIC_API_KEY is not set" | The env var is missing on the agent |
| `502` with an exception name | The model call itself failed — the detail carries the upstream error verbatim |
| Build fails at image push | Registry not reachable or not trusted by the node — see the registry section of the repository README |
| Agent runs, Traces view empty | Almost always a stale `AMP_API_KEY`; the route reports healthy while the key is rejected with `401` |
| `422` on `/chat` | Body is missing `message` |

## Notes

- `claude-opus-5` runs **adaptive thinking by default**, so a response's `content` is a list of blocks rather than a string. `text_of()` handles both and drops thinking blocks. Do not add a `budget_tokens` thinking config — it is rejected with a 400 on this model family.
- `requirements.txt` uses lower bounds so the buildpack takes the newest compatible release. Pin exact versions if you need reproducible builds.
- Verified locally against `langchain-anthropic` 1.7.0, `langchain-core` 1.6.1, `anthropic` 1.2.0, `fastapi` 0.141.1.
