"""
Minimal LangChain chat agent for WSO2 Agent Manager.

Deliberately small: this exists to prove a deployment works end to end
(build -> push -> deploy -> invoke -> trace), not to be a good example of
conversation design. Session history is an in-process dict, so it is lost on
restart and wrong across replicas — fine for a smoke test, not for anything real.
"""

from __future__ import annotations

import logging
import os
from collections import defaultdict
from typing import Any

from fastapi import FastAPI, HTTPException
from langchain_anthropic import ChatAnthropic
from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage
from pydantic import BaseModel, Field

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
log = logging.getLogger("chat-agent")

# claude-opus-5 runs adaptive thinking by default — do not set a thinking budget,
# it is rejected with a 400 on this model family.
MODEL = os.getenv("ANTHROPIC_MODEL", "claude-opus-5")
SYSTEM_PROMPT = os.getenv(
    "SYSTEM_PROMPT",
    "You are a concise assistant deployed on WSO2 Agent Manager. "
    "Answer in at most three sentences.",
)
MAX_TOKENS = int(os.getenv("MAX_TOKENS", "16000"))
MAX_TURNS = int(os.getenv("MAX_HISTORY_TURNS", "20"))

app = FastAPI(title="LangChain Chat Agent", version="1.0.0")

_history: dict[str, list[BaseMessage]] = defaultdict(list)
_llm: ChatAnthropic | None = None


def llm() -> ChatAnthropic:
    """Built lazily so the container still starts (and /healthz answers) when
    ANTHROPIC_API_KEY is missing — otherwise the pod crash-loops and the
    platform reports a deployment failure rather than a configuration one."""
    global _llm
    if _llm is None:
        if not os.getenv("ANTHROPIC_API_KEY"):
            raise RuntimeError(
                "ANTHROPIC_API_KEY is not set. Add it as an environment variable "
                "on the agent in the Agent Manager console."
            )
        _llm = ChatAnthropic(model=MODEL, max_tokens=MAX_TOKENS, timeout=120)
    return _llm


def text_of(message: AIMessage) -> str:
    """Extract the reply text.

    With adaptive thinking on (the default on claude-opus-5), `content` is a
    list of blocks rather than a string, and the thinking blocks must not be
    shown to the user. Handle both shapes.
    """
    content: Any = message.content
    if isinstance(content, str):
        return content
    parts = [
        block.get("text", "")
        for block in content
        if isinstance(block, dict) and block.get("type") == "text"
    ]
    return "".join(parts).strip()


class ChatRequest(BaseModel):
    message: str = Field(..., description="The user's message.")
    session_id: str = Field(
        "default", description="Conversation key; reuse it to continue a conversation."
    )


class ChatResponse(BaseModel):
    reply: str
    session_id: str
    model: str


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Liveness only — deliberately does not call the model, so it stays green
    without spending tokens and without depending on the API key."""
    return {"status": "ok"}


@app.post("/chat", response_model=ChatResponse)
def chat(req: ChatRequest) -> ChatResponse:
    history = _history[req.session_id]
    messages: list[BaseMessage] = [SystemMessage(content=SYSTEM_PROMPT), *history]
    messages.append(HumanMessage(content=req.message))

    # Distinguish "you configured it wrong" (503) from "the upstream call
    # failed" (502). Without this both surface as an unhandled 500 with a stack
    # trace, which is markedly harder to read from the console's logs view.
    try:
        answer = llm().invoke(messages)
    except RuntimeError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    except Exception as exc:  # noqa: BLE001 - surface upstream errors verbatim
        log.exception("model call failed")
        raise HTTPException(
            status_code=502, detail=f"{type(exc).__name__}: {exc}"
        ) from exc
    reply = text_of(answer)

    history.append(HumanMessage(content=req.message))
    history.append(AIMessage(content=reply))
    # Trim oldest first; each turn is a (human, ai) pair.
    del history[: max(0, len(history) - MAX_TURNS * 2)]

    log.info("session=%s in=%d out=%d", req.session_id, len(req.message), len(reply))
    return ChatResponse(reply=reply, session_id=req.session_id, model=MODEL)


@app.delete("/chat/{session_id}")
def reset(session_id: str) -> dict[str, str]:
    _history.pop(session_id, None)
    return {"status": "cleared", "session_id": session_id}


# --- OpenTelemetry (optional) -------------------------------------------------
# Agent Manager ingests traces at INSTRUMENTATION_URL, authenticated with an API
# key in the x-amp-api-key header (no "Bearer" prefix). Both are set as
# environment variables on the agent. Failing soft is deliberate: a broken trace
# exporter should not stop the agent from answering.
def _init_tracing() -> None:
    endpoint = os.getenv("INSTRUMENTATION_URL", "").strip()
    api_key = os.getenv("AMP_API_KEY", "").strip()
    if not endpoint or not api_key:
        log.info("tracing disabled (INSTRUMENTATION_URL or AMP_API_KEY unset)")
        return
    try:
        from opentelemetry import trace
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor

        provider = TracerProvider(
            resource=Resource.create(
                {"service.name": os.getenv("OTEL_SERVICE_NAME", "langchain-chat-agent")}
            )
        )
        provider.add_span_processor(
            BatchSpanProcessor(
                OTLPSpanExporter(
                    # The exporter needs the full signal path; INSTRUMENTATION_URL
                    # is the /otel base.
                    endpoint=f"{endpoint.rstrip('/')}/v1/traces",
                    headers={"x-amp-api-key": api_key},
                )
            )
        )
        trace.set_tracer_provider(provider)
        FastAPIInstrumentor.instrument_app(app)
        log.info("tracing enabled -> %s/v1/traces", endpoint.rstrip("/"))
    except Exception:  # noqa: BLE001 - never block startup on telemetry
        log.exception("tracing setup failed; continuing without it")


_init_tracing()
