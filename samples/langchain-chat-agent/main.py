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

# Where to send model calls.
#
# Inside Agent Manager, LLM traffic is proxied through the environment's
# embedded gateway rather than going straight to api.anthropic.com — that is
# what applies the platform's governance (token and cost-based rate limiting,
# guardrails) and what makes the calls show up in the console. Point this at the
# gateway's LLM proxy and the agent needs no change.
#
# LLM_BASE_URL is checked first so the platform's own variable name can be
# mapped onto it without editing code; ANTHROPIC_BASE_URL / ANTHROPIC_API_URL
# are the names the Anthropic SDK and langchain-anthropic already recognise.
# Unset = call the Anthropic API directly, which is what happens when you run
# this locally.
LLM_BASE_URL = (
    os.getenv("LLM_BASE_URL")
    or os.getenv("ANTHROPIC_BASE_URL")
    or os.getenv("ANTHROPIC_API_URL")
    or ""
).strip()

# Which header carries the key to the gateway.
#
# Not hardcoded, because it is the gateway's choice and it is NOT the SDK's
# default: the Anthropic SDK sends its key as `x-api-key`, while the platform's
# own API keys are read from `x-amp-api-key` (that is the header on the
# gateway's otel RestApi). Leave unset for the SDK's normal behaviour — which is
# what you want when calling the Anthropic API directly.
LLM_AUTH_HEADER = os.getenv("LLM_AUTH_HEADER", "").strip()
LLM_AUTH_KEY = (os.getenv("LLM_AUTH_KEY") or os.getenv("ANTHROPIC_API_KEY") or "").strip()

app = FastAPI(title="LangChain Chat Agent", version="1.0.0")

_history: dict[str, list[BaseMessage]] = defaultdict(list)
_llm: ChatAnthropic | None = None


def llm() -> ChatAnthropic:
    """Built lazily so the container still starts (and /healthz answers) when
    the model configuration is missing — otherwise the pod crash-loops and the
    platform reports a deployment failure rather than a configuration one."""
    global _llm
    if _llm is None:
        api_key = LLM_AUTH_KEY
        if not api_key:
            if not LLM_BASE_URL:
                raise RuntimeError(
                    "No model endpoint configured. Set ANTHROPIC_API_KEY to call "
                    "the Anthropic API directly, or LLM_BASE_URL to route through "
                    "the environment's gateway LLM proxy."
                )
            # Behind the gateway proxy the upstream provider credential is held
            # by the gateway, not the agent. The SDK still requires a non-empty
            # key, so send a placeholder rather than failing here.
            api_key = "proxied-by-gateway"

        kwargs: dict[str, Any] = {
            "model": MODEL,
            "max_tokens": MAX_TOKENS,
            "timeout": 120,
            "api_key": api_key,
        }
        if LLM_BASE_URL:
            kwargs["base_url"] = LLM_BASE_URL
        if LLM_AUTH_HEADER and LLM_AUTH_KEY:
            # Sent in addition to the SDK's own x-api-key, not instead of it —
            # the gateway reads the header it was configured with and ignores
            # the other.
            kwargs["default_headers"] = {LLM_AUTH_HEADER: LLM_AUTH_KEY}

        _llm = ChatAnthropic(**kwargs)
        log.info(
            "model=%s endpoint=%s auth_header=%s",
            MODEL,
            LLM_BASE_URL or "https://api.anthropic.com",
            LLM_AUTH_HEADER or "x-api-key (SDK default)",
        )
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


# No OpenTelemetry setup here on purpose.
#
# Agent Manager instruments deployed agents itself — traces reach the platform
# through the environment's embedded gateway, not from an exporter inside this
# process. Configuring a second exporter here would duplicate spans and add a
# credential (an API key that does not survive a platform upgrade) for no gain.
# Run this locally and it simply emits nothing.


if __name__ == "__main__":
    # Lets the container start with a plain `python main.py`, which is what runs
    # when the Procfile is not honoured and the platform supplies its own
    # command. Binding 0.0.0.0 is required — the default 127.0.0.1 is not
    # reachable from outside the pod, and the endpoint would time out rather
    # than refuse, which is markedly harder to diagnose.
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=int(os.getenv("PORT", "8080")))
