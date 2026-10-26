# 0001: Distroless runtime base image

- **Status:** accepted
- **Date:** 2026-10-26

## Context

The app image needs a Python runtime. Whatever else ships in the image is attack surface: tools an attacker can use after a compromise, and packages that carry CVEs and need patching. The image must also run as a fixed non-root UID with a read-only root filesystem, so it fits the Pod Security `restricted` level and the Kyverno policies later.

## Decision

Two-stage build. The build stage (`python:3.13-slim-trixie`) installs pinned wheels into `/deps`. The runtime stage is `gcr.io/distroless/python3-debian13:nonroot`, which ships the Python interpreter and its libraries but no shell, package manager or coreutils. Both are pinned by digest. The process runs as UID/GID 65532, and app code stays root-owned.

The two stages must share the Python minor version (3.13) and the Debian release (trixie), because the installed packages are built against both.

## Alternatives considered

- **`python:3.13-slim` as runtime:** has a shell, apt and about 100 Debian packages. It is easier to debug with `kubectl exec`, but it keeps the tools that post-exploitation payloads rely on and widens the CVE surface.
- **Slim with `/bin/sh` deleted:** fragile. The other packages remain, scanners still flag them, and a base image update can quietly restore the shell.
- **`scratch`:** no interpreter, so it only works for static binaries.
- **Chainguard/Wolfi Python:** similar goal, often fewer CVEs, but the free tier only offers `latest` tags, which conflicts with this repo's version-pinning rule.
- **`python3-debian12` distroless:** Python 3.11, older. Debian 13 gives 3.13.

## Consequences

- **What it protects against:** command injection that relies on `sh -c` fails, ready-made payloads that need `sh`, `curl` or `wget` fail, and there are fewer packages to scan and patch. **What it doesn't:** remote code execution inside the Python process can still do anything Python can. Egress NetworkPolicy (Phase 4) and the non-root, no-capabilities settings limit what that code can reach and do.
- **Debugging without a shell:** use logs, probes and events first. Then `kubectl debug -it <pod> --image=<debug image> --target=app --profile=restricted`, an ephemeral container that sees the app's processes and filesystem without changing the image. `kubectl debug --copy-to` debugs a copy of the pod. Under PSA `restricted` and the Kyverno registry allowlist, the debug image must itself run as non-root and come from an allowed registry (the mirror, once air-gapped). This is to be tried in practice once Phase 8 is done.
- **No shell to fix things by hand:** nobody can patch production through `kubectl exec`, so every change goes through the image and the chart.
- **Distroless publishes no version tags,** so the digest is the only meaningful pin. Updating the base image means bumping the digest deliberately.
