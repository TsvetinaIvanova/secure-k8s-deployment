# Secure Kubernetes Deployment

A deliberately small Python web service deployed to a local Kubernetes cluster, with the effort going into the platform around it: how the service is built, shipped, constrained and verified. The focus is platform security for regulated and disconnected (air-gapped) environments.

**Status:** in progress. Phases 0 (scaffold) and 1 (application and hardened container) are done.

## What it covers

- A hardened container: non-root, read-only root filesystem, image pinned by digest
- Helm deployment to a local [kind](https://kind.sigs.k8s.io/) cluster
- Pod Security Admission (`restricted`), default-deny NetworkPolicies, least-privilege RBAC
- Policy-as-code with Kyverno (validate, mutate, generate), including exceptions, policy reports and webhook failure modes
- CI security gates: secrets scan, SAST, dependency audit, image scan + SBOM, IaC scan, policy tests
- An air-gap simulation: every image mirrored by digest into a local registry, no public egress
- Secret delivery from Vault with rotation without a redeploy

Every control has a test that proves it is enforced: a request that should be rejected is shown to be rejected.

## Quickstart

Requires Python 3.12+ and Docker.

```bash
make help            # list all targets
make test            # unit tests (python -m pytest) in a local venv
make smoke           # build the image, run it read-only / non-root / no capabilities, check it serves
```

The full flow (`make up && make deploy && make test-security`) arrives with Phases 2 and 3.

## Security controls

| Control | Threat mitigated | Implemented in | Verified by |
|---|---|---|---|
| Non-root container, fixed UID/GID 65532 | A compromised app gets root-level access inside the container | [app/Dockerfile](app/Dockerfile) (`USER 65532:65532`) | `make smoke`: processes run as UID 65532 |
| Works with a read-only root filesystem; code owned by root | Attacker modifies the app or drops tools into the image | [app/Dockerfile](app/Dockerfile); only `/tmp` is written | `make smoke` runs with `--read-only --tmpfs /tmp` and fails on any `[ERROR]` log line |
| Distroless runtime: no shell or package manager | Command injection through `sh -c`, post-exploitation tooling, CVEs in unused packages | [app/Dockerfile](app/Dockerfile), [ADR 0001](docs/adr/0001-base-image.md) | `make smoke`: `docker exec ... /bin/sh` fails |
| Secret read from a mounted file on each request, never returned | Secret leaked via env vars, `/proc` or `kubectl describe`; stale secret after rotation | [app/src/service.py](app/src/service.py) | `make test`: rotation and no-leak tests; `make smoke`: response does not contain the secret |
| Base images pinned by digest; Python dependencies fully pinned; wheels only | Unreviewed upstream changes, build-time code execution from source packages | [app/Dockerfile](app/Dockerfile), [app/requirements.txt](app/requirements.txt) | Review for now; CI checks in Phase 7 |

## Repository layout

```
app/                Flask service, tests, Dockerfile
cluster/            kind cluster config
charts/app/         Helm chart for the service
policies/kyverno/   Kyverno policies and PolicyExceptions
policies/tests/     Kyverno CLI test cases (offline)
platform/           namespaces (PSA labels), NetworkPolicies, RBAC
airgap/             registry mirror script and offline notes
tests/security/     scripts that prove controls are enforced on a live cluster
docs/adr/           architecture decision records
.github/workflows/  CI
```

## Roadmap

| Phase | Topic | Status |
|---|---|---|
| 0 | Scaffold: layout, Makefile, README | done |
| 1 | Application and hardened container | done |
| 2 | Local cluster and Helm deployment | |
| 3 | Pod Security Admission | |
| 4 | Network Policies | |
| 5 | Kyverno policy-as-code | |
| 6 | RBAC and least privilege | |
| 7 | CI pipeline with security gates | |
| 8 | Air-gap simulation | |
| 9 | Documentation and architecture diagrams | |
| 10 | Secrets with Vault and rotation | |
| 11 | Observability for security (Loki, Grafana) | |
| S1 | Stretch: image signing (cosign) and `verifyImages` | |

## Decisions

Architecture decision records live in [docs/adr/](docs/adr/).

- [0001: Distroless runtime base image](docs/adr/0001-base-image.md)
