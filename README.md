# Secure Kubernetes Deployment

A deliberately small Python web service deployed to a local Kubernetes cluster, with the effort going into the platform around it: how the service is built, shipped, constrained and verified. The focus is platform security for regulated and disconnected (air-gapped) environments.

**Status:** in progress. Phase 0 (scaffold) is done.

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

```bash
make help            # list all targets
```

The full flow (`make up && make deploy && make test-security`) arrives with Phases 1 to 3.

## Security controls

| Control | Threat mitigated | Implemented in | Verified by |
|---|---|---|---|
| _Added as each phase lands._ | | | |

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
| 1 | Application and hardened container | |
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
