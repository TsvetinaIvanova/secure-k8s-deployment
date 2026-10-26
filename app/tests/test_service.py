import hashlib

import pytest

from service import create_app


@pytest.fixture
def secret_file(tmp_path):
    path = tmp_path / "token"
    path.write_text("s3cr3t-value\n")
    return path


@pytest.fixture
def client(monkeypatch, secret_file):
    monkeypatch.setenv("APP_GREETING", "hi from tests")
    monkeypatch.setenv("APP_SECRET_FILE", str(secret_file))
    return create_app().test_client()


def test_index_returns_greeting_and_fingerprint(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.json["message"] == "hi from tests"
    expected = hashlib.sha256(b"s3cr3t-value").hexdigest()[:12]
    assert resp.json["secret_fingerprint"] == expected


def test_index_never_returns_the_secret_itself(client):
    assert b"s3cr3t-value" not in client.get("/").data


def test_rotated_secret_is_picked_up_without_restart(client, secret_file):
    before = client.get("/").json["secret_fingerprint"]
    secret_file.write_text("rotated-value\n")
    after = client.get("/").json["secret_fingerprint"]
    assert before != after
    assert after == hashlib.sha256(b"rotated-value").hexdigest()[:12]


def test_healthz_ok(client):
    resp = client.get("/healthz")
    assert resp.status_code == 200
    assert resp.json == {"status": "ok"}


def test_readyz_ok_when_secret_present(client):
    resp = client.get("/readyz")
    assert resp.status_code == 200
    assert resp.json["status"] == "ready"


def test_readyz_503_when_secret_missing(client, secret_file):
    secret_file.unlink()
    assert client.get("/readyz").status_code == 503
    # Liveness must stay green: a missing secret is not a reason to restart.
    assert client.get("/healthz").status_code == 200
    assert client.get("/").json["secret_fingerprint"] is None


def test_greeting_defaults_when_unset(monkeypatch, secret_file):
    monkeypatch.delenv("APP_GREETING", raising=False)
    monkeypatch.setenv("APP_SECRET_FILE", str(secret_file))
    assert create_app().test_client().get("/").json["message"] == "hello"
