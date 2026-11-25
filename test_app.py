import json

import app as chat_app


class FakeOllamaResponse:
    def __init__(self, lines):
        self.lines = lines

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def raise_for_status(self):
        pass

    def iter_lines(self):
        return self.lines


def test_health_returns_git_sha(monkeypatch):
    monkeypatch.setenv("GIT_SHA", "test-sha-123")

    client = chat_app.app.test_client()
    response = client.get("/health")

    assert response.status_code == 200
    assert response.json["status"] == "ok"
    assert response.json["sha"] == "test-sha-123"


def test_chat_rejects_invalid_session_id():
    client = chat_app.app.test_client()

    response = client.post(
        "/api/chat",
        json={"session_id": "invalid session!", "message": "Hei"},
    )

    assert response.status_code == 400


def test_chat_rejects_empty_message():
    client = chat_app.app.test_client()

    response = client.post(
        "/api/chat",
        json={"session_id": "test-session", "message": "   "},
    )

    assert response.status_code == 400


def test_chat_streams_and_saves_messages(monkeypatch):
    saved_messages = []

    monkeypatch.setattr(
        chat_app.db,
        "save_message",
        lambda session_id, role, content: saved_messages.append(
            (session_id, role, content)
        ),
    )
    monkeypatch.setattr(
        chat_app.db,
        "get_history",
        lambda session_id: [
            {"role": "user", "content": "Hei"},
        ],
    )

    ollama_lines = [
        json.dumps(
            {"message": {"content": "Hei "}, "done": False}
        ).encode(),
        json.dumps(
            {"message": {"content": "sinulle!"}, "done": False}
        ).encode(),
        json.dumps({"done": True}).encode(),
    ]

    monkeypatch.setattr(
        chat_app.requests,
        "post",
        lambda *args, **kwargs: FakeOllamaResponse(ollama_lines),
    )

    client = chat_app.app.test_client()
    response = client.post(
        "/api/chat",
        json={"session_id": "test-session", "message": "Hei"},
    )

    assert response.status_code == 200
    assert b'"token": "Hei "' in response.data
    assert b'"token": "sinulle!"' in response.data
    assert b'"done": true' in response.data

    assert saved_messages == [
        ("test-session", "user", "Hei"),
        ("test-session", "assistant", "Hei sinulle!"),
    ]


def test_history_returns_messages(monkeypatch):
    monkeypatch.setattr(
        chat_app.db,
        "get_history",
        lambda session_id: [
            {
                "role": "user",
                "content": "Hei",
                "created_at": None,
            }
        ],
    )

    client = chat_app.app.test_client()
    response = client.get("/api/history/test-session")

    assert response.status_code == 200
    assert response.json["messages"][0]["content"] == "Hei"


def test_history_returns_error_when_database_fails(monkeypatch):
    def raise_database_error(session_id):
        raise RuntimeError("Database unavailable")

    monkeypatch.setattr(
        chat_app.db,
        "get_history",
        raise_database_error,
    )

    client = chat_app.app.test_client()
    response = client.get("/api/history/test-session")

    assert response.status_code == 503
    assert "error" in response.json
