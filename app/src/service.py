"""A deliberately trivial HTTP service. The interesting parts of this repo are the platform around it.

Configuration:
  APP_GREETING      plain config value, delivered as an env var (from a ConfigMap later)
  APP_SECRET_FILE   path to a file holding the secret (a mounted Kubernetes Secret later)
"""

import hashlib
import os

from flask import Flask, jsonify

DEFAULT_SECRET_FILE = "/etc/app/secret/token"


def read_secret(path):
    """Return the secret's bytes, or None if the file is missing or unreadable.

    Called on every request instead of once at startup, so a rotated secret is
    picked up without restarting the process.
    """
    try:
        with open(path, "rb") as f:
            return f.read().strip()
    except OSError:
        return None


def fingerprint(secret):
    """Short SHA-256 prefix: shows which secret is loaded without revealing it."""
    return hashlib.sha256(secret).hexdigest()[:12]


def create_app():
    app = Flask(__name__)
    greeting = os.environ.get("APP_GREETING", "hello")
    secret_file = os.environ.get("APP_SECRET_FILE", DEFAULT_SECRET_FILE)

    @app.get("/")
    def index():
        secret = read_secret(secret_file)
        return jsonify(
            message=greeting,
            secret_fingerprint=fingerprint(secret) if secret else None,
        )

    @app.get("/healthz")
    def healthz():
        # Liveness: the process can serve HTTP. No dependency checks here, or a
        # missing secret would make the kubelet restart the pod in a loop.
        return jsonify(status="ok")

    @app.get("/readyz")
    def readyz():
        # Readiness: only take traffic once the secret is actually available.
        if read_secret(secret_file) is None:
            return jsonify(status="not ready", reason="secret not available"), 503
        return jsonify(status="ready")

    return app
