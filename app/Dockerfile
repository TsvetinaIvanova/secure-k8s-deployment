# Build stage: has pip and a shell, used only to install dependencies.
# Must match the runtime's Python minor version (3.13) and Debian release (trixie).
FROM python:3.13-slim-trixie@sha256:d98cc29d3266e535dd9da1099688d9cb3ca4753813571e071763d17725460962 AS build

COPY requirements.txt /build/requirements.txt
# --only-binary: install wheels only, so no package's setup.py runs at build time.
# --target: install into a plain directory that the runtime stage copies as-is.
RUN pip install --no-cache-dir --only-binary=:all: --target /deps -r /build/requirements.txt

# Runtime stage: distroless, no shell or package manager. See docs/adr/0001-base-image.md.
FROM gcr.io/distroless/python3-debian13:nonroot@sha256:64e54c4b1200da244d80181d98e86fc01d73c8101f107d5baf472152d8e119a2

# Code and dependencies stay owned by root, so the app user cannot modify them.
COPY --from=build /deps /deps
COPY src/ /app/

ENV PYTHONPATH=/deps:/app \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Fixed numeric UID/GID (distroless "nonroot"). Numeric, so Kubernetes can verify
# runAsNonRoot without having to resolve a user name.
USER 65532:65532
EXPOSE 8080

# Exec form: gunicorn runs as PID 1 and receives SIGTERM directly.
# gthread workers: 2 processes x 4 threads, sized explicitly (not from the node's CPU count).
# --worker-tmp-dir: heartbeat files go to /tmp, the only writable path (an emptyDir in Kubernetes).
# --no-control-socket: no runtime admin socket; nothing in a distroless pod would use it.
ENTRYPOINT ["/usr/bin/python3.13", "-m", "gunicorn", \
            "--bind=0.0.0.0:8080", \
            "--workers=2", "--threads=4", \
            "--worker-tmp-dir=/tmp", \
            "--no-control-socket", \
            "--access-logfile=-", \
            "service:create_app()"]
