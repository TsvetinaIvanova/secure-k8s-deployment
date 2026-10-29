# Secure Kubernetes Deployment

A deliberately small Python web service deployed to a local Kubernetes cluster, with the effort going into the platform around it: how the service is built, shipped, constrained and verified. The focus is platform security for regulated and disconnected (air-gapped) environments.

**Status:** in progress. Phases 0 to 3 are done: scaffold, hardened container, a Helm deployment to a local kind cluster, and Pod Security Admission at `restricted`.

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

Requires Docker, Python 3.12+ and curl on linux/amd64 (the pinned tool checksums are for that platform). kind, kubectl and Helm are downloaded into `./bin` at pinned, checksum-verified versions.

```bash
make up              # kind cluster (1 control plane, 2 workers) + local registry
make deploy          # namespace with Pod Security labels, then build, push, helm upgrade --install (image pinned by digest)
make test-security   # prove the controls on the live cluster (PASS/FAIL per check)
```

Other targets:

```bash
make help            # list all targets
make test            # unit tests (python -m pytest) in a local venv
make smoke           # run the image read-only / non-root / no capabilities in Docker and check it serves
make lint            # helm lint the chart
make platform        # apply platform resources only (namespaces with Pod Security labels)
make images          # regenerate images.txt and check every pinned digest against its registry
make down            # delete the cluster and the registry

eval "$(make -s kubeconfig)"            # use the pinned kubectl against this cluster in your shell
kubectl -n app port-forward svc/app 8080:80 &
curl localhost:8080/
```

The cluster's kubeconfig is kept in the repo (`.kube/config`, gitignored), never merged into `~/.kube/config`, so make targets and tests can't act on another cluster by accident.

## Security controls

| Control | Threat mitigated | Implemented in | Verified by |
|---|---|---|---|
| Non-root container, fixed UID/GID 65532 | A compromised app gets root-level access inside the container | [app/Dockerfile](app/Dockerfile) (`USER 65532:65532`) | `make smoke`: processes run as UID 65532 |
| Works with a read-only root filesystem; code owned by root | Attacker modifies the app or drops tools into the image | [app/Dockerfile](app/Dockerfile); only `/tmp` is written | `make smoke` runs with `--read-only --tmpfs /tmp` and fails on any `[ERROR]` log line |
| Distroless runtime: no shell or package manager | Command injection through `sh -c`, post-exploitation tooling, CVEs in unused packages | [app/Dockerfile](app/Dockerfile), [ADR 0001](docs/adr/0001-base-image.md) | `make smoke`: `docker exec ... /bin/sh` fails |
| Secret read from a mounted file on each request, never returned | Secret leaked via env vars, `/proc` or `kubectl describe`; stale secret after rotation | [app/src/service.py](app/src/service.py) | `make test`: rotation and no-leak tests; `make smoke`: response does not contain the secret |
| Base images pinned by digest; Python dependencies fully pinned; wheels only | Unreviewed upstream changes, build-time code execution from source packages | [app/Dockerfile](app/Dockerfile), [app/requirements.txt](app/requirements.txt) | `make images` fails on an unpinned image or a digest its registry doesn't have; Python pins checked in CI (Phase 7) |
| Cluster tools at pinned versions, verified against SHA-256 hashes stored in the repo | Tampered or swapped download of kind, kubectl or Helm | [Makefile](Makefile) (`make tools`) | A wrong hash stops the install (checked when added) |
| Repo-local kubeconfig | Make targets or security tests running against the wrong cluster | [Makefile](Makefile) (`KUBECONFIG`) | Plain `kubectl` without it cannot reach the cluster |
| App image pinned by digest, served from a local registry | Running different bytes than were built; a moved tag | [charts/app/values.schema.json](charts/app/values.schema.json), [ADR 0003](docs/adr/0003-local-registry.md) | Schema rejects a missing digest or `latest`; `test_deploy.sh`: all pods reference a digest; a wrong digest fails with `ErrImagePull` (checked when added) |
| Hardened pod spec: non-root, RuntimeDefault seccomp, no privilege escalation, drop ALL capabilities, read-only root filesystem | Container breakout and privilege escalation from a compromised app | [charts/app/templates/deployment.yaml](charts/app/templates/deployment.yaml) | `test_psa.sh`: running app pods meet `restricted`; read-only root filesystem enforced by Kyverno in Phase 5 |
| Pod Security Admission `restricted` (enforce pinned to v1.37; warn and audit at latest) on namespace `app` | Privileged, root or host-access pods scheduled into the app namespace, by mistake or by someone with deploy rights | [platform/namespaces.yaml](platform/namespaces.yaml), [ADR 0006](docs/adr/0006-psa-versions.md) | `test_psa.sh`: a privileged, a root and a hostPath pod are rejected with the PSA reason; the same pod without the violation is admitted |
| Dedicated ServiceAccount: no token mounted, no RoleBindings | A compromised app uses its token against the Kubernetes API | [serviceaccount.yaml](charts/app/templates/serviceaccount.yaml), [deployment.yaml](charts/app/templates/deployment.yaml) | `test_deploy.sh`: no token volume; `can-i` denies list pods, get secrets, create pods |
| App Secret created outside Helm, from stdin, mounted as a read-only directory | Secret kept in Helm's release history, shell history or an apply annotation | [Makefile](Makefile) (`make deploy`), [ADR 0005](docs/adr/0005-secret-outside-chart.md) | `test_deploy.sh`: the decoded release record doesn't contain the value; app serves its fingerprint, never the value |
| NetworkPolicy-enforcing CNI | Policies accepted but silently not enforced | [cluster/kind-config.yaml](cluster/kind-config.yaml), [ADR 0002](docs/adr/0002-cni.md) | Checked across nodes when chosen; `test_netpol.sh` in Phase 4 |

## Repository layout

```
app/                Flask service, tests, Dockerfile
cluster/            kind cluster config, local registry setup
charts/app/         Helm chart for the service
policies/kyverno/   Kyverno policies and PolicyExceptions
policies/tests/     Kyverno CLI test cases (offline)
platform/           namespaces (PSA labels), NetworkPolicies, RBAC
airgap/             image inventory script (images.txt), later the mirror script and offline notes
images.txt          generated: every third-party image, pinned by digest
tests/security/     scripts that prove controls are enforced on a live cluster
docs/adr/           architecture decision records
.github/workflows/  CI
```

## Roadmap

| Phase | Topic | Status |
|---|---|---|
| 0 | Scaffold: layout, Makefile, README | done |
| 1 | Application and hardened container | done |
| 2 | Local cluster and Helm deployment | done |
| 3 | Pod Security Admission | done |
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
- [0002: Keep kind's default CNI (kindnet) for NetworkPolicy](docs/adr/0002-cni.md)
- [0003: Local registry from the start, not `kind load`](docs/adr/0003-local-registry.md)
- [0004: Package the app as a Helm chart](docs/adr/0004-helm.md)
- [0005: Keep the app Secret out of the Helm chart](docs/adr/0005-secret-outside-chart.md)
- [0006: Pod Security Admission: pinned enforce, latest warn/audit, namespace owned by the platform](docs/adr/0006-psa-versions.md)
