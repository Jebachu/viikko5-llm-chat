import json
import os
import re
from pathlib import Path

import requests
from flask import Flask, Response, jsonify, render_template, request, stream_with_context
from werkzeug.middleware.proxy_fix import ProxyFix

import db

app = Flask(__name__)

# Nginx välittää sovellukselle alkuperäisen URL-etuliitteen.
app.wsgi_app = ProxyFix(
    app.wsgi_app,
    x_for=1,
    x_proto=1,
    x_host=1,
    x_prefix=1,
)

OLLAMA_URL = os.getenv("OLLAMA_URL", "http://127.0.0.1:11434")
OLLAMA_MODEL = os.getenv("OLLAMA_MODEL", "qwen2.5:0.5b")
MAX_MESSAGE_LENGTH = 4000


def get_revision():
    """Palauta käyttöönotetun version Git SHA."""
    revision = os.getenv("GIT_SHA")

    if revision:
        return revision

    revision_file = Path(__file__).with_name("REVISION")

    if revision_file.exists():
        return revision_file.read_text(encoding="utf-8").strip()

    return "development"


@app.get("/")
def index():
    return render_template("index.html")


@app.get("/health")
def health():
    return jsonify(
        status="ok",
        sha=get_revision(),
    )


@app.get("/api/history/<session_id>")
def history(session_id):
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", session_id):
        return jsonify(error="Invalid session ID"), 400

    try:
        messages = db.get_history(session_id)

        for message in messages:
            if message.get("created_at"):
                message["created_at"] = message["created_at"].isoformat()

        return jsonify(messages=messages)

    except Exception:
        app.logger.exception("Could not retrieve chat history")
        return jsonify(error="Could not retrieve chat history"), 503


@app.post("/api/chat")
def chat():
    data = request.get_json(silent=True) or {}

    session_id = data.get("session_id")
    message = data.get("message")

    if not isinstance(session_id, str) or not re.fullmatch(
        r"[A-Za-z0-9_-]{1,64}", session_id
    ):
        return jsonify(error="Invalid session ID"), 400

    if not isinstance(message, str) or not message.strip():
        return jsonify(error="Message cannot be empty"), 400

    message = message.strip()

    if len(message) > MAX_MESSAGE_LENGTH:
        return jsonify(error="Message is too long"), 400

    try:
        db.save_message(session_id, "user", message)
        conversation = db.get_history(session_id)
    except Exception:
        app.logger.exception("Could not save or retrieve chat message")
        return jsonify(error="Database error"), 503

    ollama_messages = [
        {"role": item["role"], "content": item["content"]}
        for item in conversation
    ]

    @stream_with_context
    def generate():
        assistant_parts = []

        try:
            with requests.post(
                f"{OLLAMA_URL}/api/chat",
                json={
                    "model": OLLAMA_MODEL,
                    "messages": ollama_messages,
                    "stream": True,
                },
                stream=True,
                timeout=(5, 300),
            ) as response:
                response.raise_for_status()

                for line in response.iter_lines():
                    if not line:
                        continue

                    result = json.loads(line)

                    if result.get("error"):
                        raise RuntimeError("Ollama returned an error")

                    token = result.get("message", {}).get("content", "")

                    if token:
                        assistant_parts.append(token)
                        yield json.dumps(
                            {"token": token},
                            ensure_ascii=False,
                        ) + "\n"

                    if result.get("done"):
                        break

            assistant_message = "".join(assistant_parts)

            if assistant_message:
                db.save_message(
                    session_id,
                    "assistant",
                    assistant_message,
                )

            yield json.dumps({"done": True}) + "\n"

        except (requests.RequestException, ValueError, RuntimeError):
            app.logger.exception("Ollama request failed")
            yield json.dumps(
                {"error": "Could not get a response from the language model"}
            ) + "\n"

    return Response(
        generate(),
        content_type="application/x-ndjson; charset=utf-8",
    )


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=8001, debug=False)
