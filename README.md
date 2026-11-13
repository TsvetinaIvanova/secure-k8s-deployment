# Secure Kubernetes Deployment

A deliberately small Python web service deployed to a local Kubernetes cluster, with the effort going into the platform around it: how the service is built, shipped, constrained and verified. The focus is platform security for regulated and disconnected (air-gapped) environments.

**Status:** in progress. Phases 0 to 4 and 6 are done: scaffold, hardened container, a Helm deployment to a local kind cluster, Pod Security Admission at `restricted`, default-deny NetworkPolicies, and least-privilege RBAC for the identity that deploys. Phases that add external tooling to the cluster (Kyverno, Vault, Loki and Grafana, cosign `verifyImages`) are stretch goals until the security measures that apply to a clean Kubernetes cluster are covered ([ADR 0008](docs/adr/0008-native-controls-first.md)). Today, nothing beyond PSA's fixed rules is enforced at admission; Phase 6a is planned to close that gap with built-in admission policies.

## Implemented

- A hardened container: non-root, read-only root filesystem, image pinned by digest
- Helm deployment to a local [kind](https://kind.sigs.k8s.io/) cluster
- Pod Security Admission (`restricted`) and default-deny NetworkPolicies with no egress
- An app ServiceAccount with no token mounted and no permissions
- Helm runs as a deployer ServiceAccount limited to the app's own objects, with 10-minute tokens: no Secrets, no `exec`, no changes to NetworkPolicies or RBAC
- CI baseline: unit tests, chart lint, image inventory check, container smoke test

## Planned

Not built yet; see the [roadmap](#roadmap).

- Built-in admission policies (ValidatingAdmissionPolicy) for what PSA can't express, such as a read-only root filesystem
- CI security gates: secrets scan, SAST, dependency audit, image scan + SBOM, IaC scan
- An air-gap simulation: every image mirrored by digest into a local registry, no public egress

Stretch goals, because they add external tooling to the cluster:

- Policy-as-code with Kyverno (validate, mutate, generate), including exceptions, policy reports, webhook failure modes and offline policy tests in CI
- Secret delivery from Vault with rotation without a redeploy
- Security observability with Loki and Grafana
- Image signing with cosign, verified by Kyverno `verifyImages`

## Quickstart

Requires Docker, Python 3.12+ and curl on linux/amd64 (the pinned tool checksums are for that platform). kind, kubectl and Helm are downloaded into `./bin` at pinned, checksum-verified versions.

```bash
make up              # kind cluster (1 control plane, 2 workers) + local registry
make deploy          # build, push, apply platform resources, helm upgrade --install as the deployer (image pinned by digest)
make test-security   # prove the controls on the live cluster (PASS/FAIL per check)
```

Other targets:

```bash
make help            # list all targets
make test            # unit tests (python -m pytest) in a local venv
make smoke           # run the image read-only / non-root / no capabilities in Docker and check it serves
make lint            # helm lint the chart
make platform        # apply platform resources only, as admin (namespaces with Pod Security labels, NetworkPolicies, deployer RBAC, app Secret)
make images          # regenerate images.txt and check every pinned digest against its registry
make clean-test-pods # delete pods left behind by a killed security test run
make down            # delete the cluster and the registry

eval "$(make -s kubeconfig)"            # use the pinned kubectl and helm against this cluster in your shell
kubectl -n app port-forward svc/app 8080:80 &
curl localhost:8080/
```

Port-forward works under default-deny because it doesn't arrive through the pod network. In-cluster traffic is limited to the `test-client` pod in namespace `client`.

The cluster's kubeconfig is kept in the repo (`.kube/config`, gitignored), never merged into `~/.kube/config`, so make targets and tests can't act on another cluster by accident. It is cluster-admin and is used for the cluster, platform resources and tests. Helm itself runs with `.kube/deployer`, which `make deploy` writes with a fresh 10-minute token for the deployer ServiceAccount and deletes when Helm exits ([ADR 0009](docs/adr/0009-deployer-rbac.md)). Helm keeps its release record in ConfigMaps, so `helm` by hand needs `HELM_DRIVER=configmap`; the `kubeconfig` target exports it.

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs on every pull request and push to `main`, calling the same targets: `test`, `lint`, `images` (plus a check that the committed `images.txt` is current) and `smoke`. Actions are pinned by commit SHA and the workflow token is read-only. The security gates (secrets scan, SAST, image and IaC scans, e2e) are Phase 7.

## Security controls

Each control below lists how it is verified. Where a control can be enforced, the test shows the bad request being rejected; the table notes where a check is manual or a control isn't enforced at admission.

| Control | Threat mitigated | Implemented in | Verified by |
|---|---|---|---|
| Non-root container, fixed UID/GID 65532 | A compromised app gets root-level access inside the container | [app/Dockerfile](app/Dockerfile) (`USER 65532:65532`) | `make smoke`: processes run as UID 65532 |
| Works with a read-only root filesystem; code owned by root | Attacker modifies the app or drops tools into the image | [app/Dockerfile](app/Dockerfile); only `/tmp` is written | `make smoke` runs with `--read-only --tmpfs /tmp` and fails on any `[ERROR]` log line |
| Distroless runtime: no shell or package manager | Command injection through `sh -c`, post-exploitation tooling, CVEs in unused packages | [app/Dockerfile](app/Dockerfile), [ADR 0001](docs/adr/0001-base-image.md) | `make smoke`: `docker exec ... /bin/sh` fails |
| Secret read from a mounted file on each request, never returned | Secret leaked via env vars, `/proc` or `kubectl describe`; stale secret after rotation | [app/src/service.py](app/src/service.py) | `make test`: rotation and no-leak tests; `make smoke`: response does not contain the secret |
| Base images pinned by digest; Python dependencies fully pinned; wheels only | Unreviewed upstream changes, build-time code execution from source packages | [app/Dockerfile](app/Dockerfile), [app/requirements.txt](app/requirements.txt) | `make images` fails on an unpinned image or a digest its registry doesn't have; CI runs it on every PR and fails if `images.txt` is stale; dependency audit in Phase 7 |
| Cluster tools at pinned versions, verified against SHA-256 hashes stored in the repo | Tampered or swapped download of kind, kubectl or Helm | [Makefile](Makefile) (`make tools`) | A wrong hash stops the install (checked when added); CI downloads and verifies Helm on every run |
| Repo-local kubeconfig | Make targets or security tests running against the wrong cluster | [Makefile](Makefile) (`KUBECONFIG`) | Plain `kubectl` without it cannot reach the cluster |
| App image pinned by digest, served from a local registry | Running different bytes than were built; a moved tag | [charts/app/values.schema.json](charts/app/values.schema.json), [ADR 0003](docs/adr/0003-local-registry.md) | Schema rejects a missing digest or `latest`; `test_deploy.sh`: all pods reference a digest; a wrong digest fails with `ErrImagePull` (checked when added) |
| Hardened pod spec: non-root, RuntimeDefault seccomp, no privilege escalation, drop ALL capabilities, read-only root filesystem | Container breakout and privilege escalation from a compromised app | [charts/app/templates/deployment.yaml](charts/app/templates/deployment.yaml) | `test_psa.sh`: running app pods meet `restricted`. PSA doesn't check the read-only root filesystem: it is set in the chart and exercised by `make smoke`, but nothing enforces it at admission |
| Pod Security Admission `restricted` (enforce pinned to v1.37; warn and audit at latest) on namespace `app`. This kind cluster has no API audit log, so `audit` records go nowhere here; `enforce` and `warn` are what take effect | Privileged, root or host-access pods scheduled into the app namespace, by mistake or by someone with deploy rights | [platform/namespaces.yaml](platform/namespaces.yaml), [ADR 0006](docs/adr/0006-psa-versions.md) | `test_psa.sh`: a privileged, a root, a hostPath and a hostNetwork pod are rejected with the PSA reason; the same pod without the violation is admitted |
| Dedicated ServiceAccount: no token mounted, no RoleBindings | A compromised app uses its token against the Kubernetes API | [serviceaccount.yaml](charts/app/templates/serviceaccount.yaml), [deployment.yaml](charts/app/templates/deployment.yaml) | `test_deploy.sh`: no token volume; `can-i` denies list pods, get secrets, create pods |
| App Secret created outside Helm, from stdin, mounted as a read-only directory | Secret kept in Helm's release history, shell history or an apply annotation | [Makefile](Makefile) (`make platform`), [ADR 0005](docs/adr/0005-secret-outside-chart.md) | `test_deploy.sh`: the decoded release record doesn't contain the value; app serves its fingerprint, never the value |
| Deployer limited to the app's own objects in `app`: Deployments, Services, ServiceAccounts, ConfigMaps; read-only Pods and ReplicaSets | Whoever deploys reads Secrets, opens a shell in a pod, removes NetworkPolicies, weakens Pod Security labels or grants itself more access | [platform/rbac/deployer.yaml](platform/rbac/deployer.yaml), [ADR 0009](docs/adr/0009-deployer-rbac.md) | `test_rbac.sh`: `can-i` allows what Helm needs and denies Secrets, `exec`/`attach`/`portforward`/`log`, token minting, NetworkPolicies, RBAC, namespaces and other namespaces; reading the app Secret, deleting the default-deny policy, binding `admin` and relabelling the namespace are each rejected as forbidden, after succeeding as admin; minting a token is rejected after admin's `can-i` confirms it would be allowed (sending it as admin would issue a real token). With `edit` bound instead, 13 checks fail (checked when added). Not covered: the deployer can still create Services with `externalIPs` or of type NodePort or LoadBalancer; blocking them at admission is planned for Phase 6a |
| Deployer tokens from the TokenRequest API, 10 minutes, no Secret-based token, kubeconfig deleted when Helm exits; ServiceAccount in a namespace where nothing runs | A leaked deployer credential stays valid; a pod running as the deployer | [cluster/deployer-kubeconfig.sh](cluster/deployer-kubeconfig.sh), [Makefile](Makefile) (`make deploy`), [platform/namespaces.yaml](platform/namespaces.yaml) | `test_rbac.sh`: the token authenticates as the deployer and expires after 600 s; no token Secret exists in namespace `deploy`. `.kube/deployer` is gone after `make deploy` (checked when added) |
| Helm release record in ConfigMaps (`HELM_DRIVER=configmap`) | The deployer needs Secret access only because of where Helm stores its state, and could then read the app Secret | [Makefile](Makefile), [ADR 0009](docs/adr/0009-deployer-rbac.md) | `make deploy` installs, upgrades and waits as the deployer; `helm rollback` works with the same rights (checked when added); `test_deploy.sh` reads the deployed release from its ConfigMap |
| NetworkPolicy-enforcing CNI | Policies accepted but silently not enforced | [cluster/kind-config.yaml](cluster/kind-config.yaml), [ADR 0002](docs/adr/0002-cni.md) | `test_netpol.sh`: blocked traffic times out, and controls show the same destinations answer for a pod with no policy |
| Default-deny ingress and egress for every pod in namespace `app`, including DNS | Lateral movement to the app; a compromised app reaching other services or exfiltrating data | [platform/networkpolicies/networkpolicy-app.yaml](platform/networkpolicies/networkpolicy-app.yaml), [ADR 0007](docs/adr/0007-network-policies.md) | `test_netpol.sh`: a pod in `app` can't reach the API server by IP or by name; no egress rules exist in the namespace; app pods stay Ready |
| Ingress only from `test-client` pods in namespace `client`, TCP 8080 only | Any other workload in the cluster calling the app | [platform/networkpolicies/networkpolicy-app.yaml](platform/networkpolicies/networkpolicy-app.yaml) | `test_netpol.sh`: the allowed pod connects; another port, an unlabelled pod in `client` and a pod in another namespace are all blocked |

## Repository layout

```
app/                Flask service, tests, Dockerfile
cluster/            kind cluster config, local registry setup, deployer kubeconfig
charts/app/         Helm chart for the service
policies/kyverno/   planned: Kyverno policies and PolicyExceptions
policies/tests/     planned: Kyverno CLI test cases (offline)
platform/           namespaces (PSA labels), NetworkPolicies, deployer RBAC
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
| 4 | Network Policies | done |
| 5 | Kyverno policy-as-code | stretch goal |
| 6 | RBAC and least privilege | done |
| 6a | Native admission policies (ValidatingAdmissionPolicy), including ClusterIP-only Services without `externalIPs` in `app` | |
| 7 | CI pipeline with security gates | |
| 8 | Air-gap simulation | |
| 9 | Documentation and architecture diagrams | |
| 10 | Secrets with Vault and rotation | stretch goal |
| 11 | Observability for security (Loki, Grafana) | stretch goal |
| S1 | Image signing (cosign) and `verifyImages`; needs Phase 5 | stretch goal |

## Decisions

Architecture decision records live in [docs/adr/](docs/adr/).

- [0001: Distroless runtime base image](docs/adr/0001-base-image.md)
- [0002: Keep kind's default CNI (kindnet) for NetworkPolicy](docs/adr/0002-cni.md)
- [0003: Local registry from the start, not `kind load`](docs/adr/0003-local-registry.md)
- [0004: Package the app as a Helm chart](docs/adr/0004-helm.md)
- [0005: Keep the app Secret out of the Helm chart](docs/adr/0005-secret-outside-chart.md)
- [0006: Pod Security Admission: pinned enforce, latest warn/audit, namespace owned by the platform](docs/adr/0006-psa-versions.md)
- [0007: NetworkPolicies: platform-owned, no egress, standard API only](docs/adr/0007-network-policies.md)
- [0008: Native Kubernetes controls first; in-cluster add-ons are stretch goals](docs/adr/0008-native-controls-first.md)
- [0009: Deployer RBAC: a namespaced Role, short-lived tokens, no Secrets](docs/adr/0009-deployer-rbac.md)

## License

[MIT](LICENSE)
