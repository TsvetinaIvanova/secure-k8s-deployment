# Secure Kubernetes Deployment

A deliberately small Python web service deployed to a local Kubernetes cluster, with the effort going into the platform around it: how the service is built, shipped, constrained and verified. The focus is platform security for regulated and disconnected (air-gapped) environments.

**Status:** in progress. Phases 0 to 4, 6, 6a and 7 are done: scaffold, hardened container, a Helm deployment to a local kind cluster, Pod Security Admission at `restricted`, default-deny NetworkPolicies, least-privilege RBAC for the identity that deploys, built-in admission policies for what Pod Security Admission can't check, and CI security gates. Phases that add external tooling to the cluster (Kyverno, Vault, Loki and Grafana, cosign `verifyImages`) are stretch goals until the security measures that apply to a clean Kubernetes cluster are covered ([ADR 0008](docs/adr/0008-native-controls-first.md)). Admission checks beyond PSA use ValidatingAdmissionPolicy, which is built into Kubernetes ([ADR 0010](docs/adr/0010-admission-policies.md)).

## Implemented

- A hardened container: non-root, read-only root filesystem, image pinned by digest
- Helm deployment to a local [kind](https://kind.sigs.k8s.io/) cluster
- Pod Security Admission (`restricted`) and default-deny NetworkPolicies with no egress
- An app ServiceAccount with no token mounted and no permissions
- Helm runs as a deployer ServiceAccount limited to the app's own objects, with 10-minute tokens: no Secrets, no `exec`, no changes to NetworkPolicies or RBAC
- Built-in admission policies (ValidatingAdmissionPolicy) in `app`: read-only root filesystem, CPU and memory limits, and images pinned by digest for every workload, checked on the Deployment itself; Services only as ClusterIP, with no `externalIPs`
- CI: unit tests, chart lint, image inventory check, container smoke test, and the live security tests on a kind cluster on every PR
- CI security gates, each proven to reject planted bad input: secrets in git history (gitleaks), SAST (Bandit), dependency audit (pip-audit), image vulnerabilities and secrets (Trivy) with a CycloneDX SBOM, and misconfigurations in the rendered chart, platform manifests and Dockerfile (Trivy)

## Planned

Not built yet; see the [roadmap](#roadmap).

- An air-gap simulation: every image mirrored by digest into a local registry, no public egress, and an admission rule that allows only that registry

Stretch goals, because they add external tooling to the cluster:

- Policy-as-code with Kyverno (validate, mutate, generate), including exceptions, policy reports, webhook failure modes and offline policy tests in CI
- Secret delivery from Vault with rotation without a redeploy
- Security observability with Loki and Grafana
- Image signing with cosign, verified by Kyverno `verifyImages`

## Quickstart

Requires Docker, Python 3.12+ and curl on linux/amd64 (the pinned tool checksums are for that platform). kind, kubectl, Helm, gitleaks and Trivy are downloaded into `./bin` at pinned, checksum-verified versions.

```bash
make hooks           # pre-commit secrets scan for this clone (gitleaks on staged changes)
make up              # kind cluster (1 control plane, 2 workers) + local registry
make deploy          # build, push, apply platform resources, helm upgrade --install as the deployer (image pinned by digest)
make test-security   # prove the controls on the live cluster (PASS/FAIL per check)
make scan            # run every CI security gate locally (make -k scan to see all failures)
```

Other targets:

```bash
make help            # list all targets
make test            # unit tests (python -m pytest) in a local venv
make smoke           # run the image read-only / non-root / no capabilities in Docker and check it serves
make lint            # helm lint the chart
make test-gates      # prove each security gate rejects planted bad input (PASS/FAIL per check)
make sbom            # CycloneDX SBOM of the app image (sbom.cdx.json)
make scan-lock       # re-lock the Python scanners (Bandit, pip-audit) with hashes
make platform        # apply platform resources only, as admin (namespaces with Pod Security labels, admission policies, NetworkPolicies, deployer RBAC, app Secret)
make images          # regenerate images.txt and check every pinned digest against its registry
make clean-test-pods # delete pods left behind by a killed security test run
make down            # delete the cluster and the registry

eval "$(make -s kubeconfig)"            # use the pinned kubectl and helm against this cluster in your shell
kubectl -n app port-forward svc/app 8080:80 &
curl localhost:8080/
```

Port-forward works under default-deny because it doesn't arrive through the pod network. In-cluster traffic is limited to the `test-client` pod in namespace `client`.

The cluster's kubeconfig is kept in the repo (`.kube/config`, gitignored), never merged into `~/.kube/config`, so make targets and tests can't act on another cluster by accident. It is cluster-admin and is used for the cluster, platform resources and tests. Helm itself runs with `.kube/deployer`, which `make deploy` writes with a fresh 10-minute token for the deployer ServiceAccount and deletes when Helm exits ([ADR 0009](docs/adr/0009-deployer-rbac.md)). Helm keeps its release record in ConfigMaps, so `helm` by hand needs `HELM_DRIVER=configmap`; the `kubeconfig` target exports it.

CI ([.github/workflows/ci.yml](.github/workflows/ci.yml)) runs on every pull request and push to `main`, calling the same targets as a local run: `test`, `lint`, `images` (plus a check that the committed `images.txt` is current), `smoke`, the gates (`secrets-scan`, `sast`, `deps-audit`, `scan-image`, `scan-iac`), `test-gates`, and `up` + `deploy` + `test-security` on a fresh kind cluster. The SBOM is kept as a workflow artifact for 30 days. Actions are pinned by commit SHA, scanners are downloaded by `make` with hashes in the repo rather than through third-party actions, and the workflow token is read-only ([ADR 0011](docs/adr/0011-ci-security-gates.md)).

## Security controls

Each control below lists how it is verified. Where a control can be enforced, the test shows the bad request being rejected; the table notes where a check is manual or a control isn't enforced at admission.

| Control | Threat mitigated | Implemented in | Verified by |
|---|---|---|---|
| Non-root container, fixed UID/GID 65532 | A compromised app gets root-level access inside the container | [app/Dockerfile](app/Dockerfile) (`USER 65532:65532`) | `make smoke`: processes run as UID 65532 |
| Works with a read-only root filesystem; code owned by root | Attacker modifies the app or drops tools into the image | [app/Dockerfile](app/Dockerfile); only `/tmp` is written | `make smoke` runs with `--read-only --tmpfs /tmp` and fails on any `[ERROR]` log line |
| Distroless runtime: no shell or package manager | Command injection through `sh -c`, post-exploitation tooling, CVEs in unused packages | [app/Dockerfile](app/Dockerfile), [ADR 0001](docs/adr/0001-base-image.md) | `make smoke`: `docker exec ... /bin/sh` fails |
| Secret read from a mounted file on each request, never returned | Secret leaked via env vars, `/proc` or `kubectl describe`; stale secret after rotation | [app/src/service.py](app/src/service.py) | `make test`: rotation and no-leak tests; `make smoke`: response does not contain the secret |
| Base images pinned by digest; Python dependencies fully pinned; wheels only | Unreviewed upstream changes, build-time code execution from source packages | [app/Dockerfile](app/Dockerfile), [app/requirements.txt](app/requirements.txt) | `make images` fails on an unpinned image or a digest its registry doesn't have; CI runs it on every PR and fails if `images.txt` is stale; dependency audit below |
| Cluster and scanner tools at pinned versions, verified against SHA-256 hashes stored in the repo; Python scanners installed with `--require-hashes` | Tampered or swapped download of kind, kubectl, Helm, gitleaks, Trivy, Bandit or pip-audit | [Makefile](Makefile), [tools/scan-requirements.txt](tools/scan-requirements.txt) | A wrong hash stops the install (checked when added); CI downloads and verifies Helm on every run |
| Repo-local kubeconfig | Make targets or security tests running against the wrong cluster | [Makefile](Makefile) (`KUBECONFIG`) | Plain `kubectl` without it cannot reach the cluster |
| App image pinned by digest, served from a local registry | Running different bytes than were built; a moved tag | [charts/app/values.schema.json](charts/app/values.schema.json), [ADR 0003](docs/adr/0003-local-registry.md) | Schema rejects a missing digest or `latest`; `test_deploy.sh`: all pods reference a digest; a wrong digest fails with `ErrImagePull` (checked when added) |
| Hardened pod spec: non-root, RuntimeDefault seccomp, no privilege escalation, drop ALL capabilities, read-only root filesystem | Container breakout and privilege escalation from a compromised app | [charts/app/templates/deployment.yaml](charts/app/templates/deployment.yaml) | `test_psa.sh`: running app pods meet `restricted`. PSA doesn't check the read-only root filesystem; the `app-workloads` policy below does |
| Pod Security Admission `restricted` (enforce pinned to v1.37; warn and audit at latest) on namespace `app`. This kind cluster has no API audit log, so `audit` records go nowhere here; `enforce` and `warn` are what take effect | Privileged, root or host-access pods scheduled into the app namespace, by mistake or by someone with deploy rights | [platform/namespaces.yaml](platform/namespaces.yaml), [ADR 0006](docs/adr/0006-psa-versions.md) | `test_psa.sh`: a privileged, a root, a hostPath and a hostNetwork pod are rejected with the PSA reason; the same pod without the violation is admitted |
| Dedicated ServiceAccount: no token mounted, no RoleBindings | A compromised app uses its token against the Kubernetes API | [serviceaccount.yaml](charts/app/templates/serviceaccount.yaml), [deployment.yaml](charts/app/templates/deployment.yaml) | `test_deploy.sh`: no token volume; `can-i` denies list pods, get secrets, create pods |
| App Secret created outside Helm, from stdin, mounted as a read-only directory | Secret kept in Helm's release history, shell history or an apply annotation | [Makefile](Makefile) (`make platform`), [ADR 0005](docs/adr/0005-secret-outside-chart.md) | `test_deploy.sh`: the decoded release record doesn't contain the value; app serves its fingerprint, never the value |
| Deployer limited to the app's own objects in `app`: Deployments, Services, ServiceAccounts, ConfigMaps; read-only Pods and ReplicaSets | Whoever deploys reads Secrets, opens a shell in a pod, removes NetworkPolicies, weakens Pod Security labels or grants itself more access | [platform/rbac/deployer.yaml](platform/rbac/deployer.yaml), [ADR 0009](docs/adr/0009-deployer-rbac.md) | `test_rbac.sh`: `can-i` allows what Helm needs and denies Secrets, `exec`/`attach`/`portforward`/`log`, token minting, NetworkPolicies, RBAC, namespaces and other namespaces; reading the app Secret, deleting the default-deny policy, binding `admin` and relabelling the namespace are each rejected as forbidden, after succeeding as admin; minting a token is rejected after admin's `can-i` confirms it would be allowed (sending it as admin would issue a real token). With `edit` bound instead, 13 checks fail (checked when added). Services with `externalIPs` or of a type other than ClusterIP, which RBAC can't restrict, are rejected by the `app-services` policy below |
| Deployer tokens from the TokenRequest API, 10 minutes, no Secret-based token, kubeconfig deleted when Helm exits; ServiceAccount in a namespace where nothing runs | A leaked deployer credential stays valid; a pod running as the deployer | [cluster/deployer-kubeconfig.sh](cluster/deployer-kubeconfig.sh), [Makefile](Makefile) (`make deploy`), [platform/namespaces.yaml](platform/namespaces.yaml) | `test_rbac.sh`: the token authenticates as the deployer and expires after 600 s; no token Secret exists in namespace `deploy`. `.kube/deployer` is gone after `make deploy` (checked when added) |
| Helm release record in ConfigMaps (`HELM_DRIVER=configmap`) | The deployer needs Secret access only because of where Helm stores its state, and could then read the app Secret | [Makefile](Makefile), [ADR 0009](docs/adr/0009-deployer-rbac.md) | `make deploy` installs, upgrades and waits as the deployer; `helm rollback` works with the same rights (checked when added); `test_deploy.sh` reads the deployed release from its ConfigMap |
| ValidatingAdmissionPolicy `app-workloads` in `app`: every container and init container has a read-only root filesystem, CPU and memory limits, and an image pinned by digest. Checked on Pods and on the pod templates of Deployments, ReplicaSets, StatefulSets, DaemonSets, Jobs and CronJobs, for every user including cluster-admin | A writable root filesystem, which PSA doesn't check; one pod starving the node; an image whose tag was moved; a bad Deployment accepted and failing only at pod creation (ADR 0006) | [platform/admission/app-workloads.yaml](platform/admission/app-workloads.yaml), [ADR 0010](docs/adr/0010-admission-policies.md) | `test_admission.sh`: a compliant Deployment, Pod and CronJob are admitted. Rejected, with the policy and rule named: a Deployment without `readOnlyRootFilesystem`, a writable init container, no memory limit, an image by tag only; a Pod (as admin) without `readOnlyRootFilesystem`; a CronJob with an image by tag only. The deployed Deployment passes as an update. With its binding deleted, 7 checks fail (checked when added). Not covered: debug containers (ADR 0010); the registry itself, until Phase 8 |
| ValidatingAdmissionPolicy `app-services` in `app`: `type: ClusterIP`, no `externalIPs` | The deployer capturing cluster traffic with `externalIPs` (CVE-2020-8554), or exposing the app through NodePort, LoadBalancer or ExternalName | [platform/admission/app-services.yaml](platform/admission/app-services.yaml), [ADR 0010](docs/adr/0010-admission-policies.md) | `test_admission.sh`, with the deployer's token: a ClusterIP Service is admitted; NodePort, LoadBalancer, ExternalName and `externalIPs` are rejected by the policy. With its binding deleted, 4 rejections and the binding check fail (checked when added). The deployer can't delete or patch the policies or their bindings |
| Secrets scan of the full git history (gitleaks), in CI on every PR; the same check on staged changes as a pre-commit hook (`make hooks`), which is opt-in and skippable with `--no-verify`, so CI is the control | A credential committed, including one deleted in a later commit but still in history | [Makefile](Makefile) (`make secrets-scan`, `make hooks`), [tools/hooks/pre-commit](tools/hooks/pre-commit), [ADR 0011](docs/adr/0011-ci-security-gates.md) | `test_gates.sh`: a GitHub-token-shaped string committed and then deleted is found (`github-pat`); this repo's history passes; with the hook, a commit with a staged token is blocked and nothing enters history, a clean commit goes through |
| SAST of the app source (Bandit); any finding fails, exceptions are `# nosec <id>` with a reason on the line | Injection, unsafe deserialisation and similar flaws in the service code | [Makefile](Makefile) (`make sast`), [app/src/service.py](app/src/service.py) (one false positive: a file path flagged as a password) | `test_gates.sh`: a `shell=True` command built from input is rejected (`B602`); `app/src` passes |
| Dependency audit of the pinned runtime requirements (pip-audit); any known vulnerability fails | Shipping a Python dependency with a published advisory | [Makefile](Makefile) (`make deps-audit`) | `test_gates.sh`: a `Werkzeug==2.2.2` pin is rejected; `app/requirements.txt` passes |
| Image scan (Trivy): fails on HIGH/CRITICAL vulnerabilities with a fixed version, and on embedded secrets; CycloneDX SBOM per build | Shipping a known, fixable vulnerability in the OS packages or Python dependencies of the image | [Makefile](Makefile) (`make scan-image`, `make sbom`), [ADR 0011](docs/adr/0011-ci-security-gates.md) | `test_gates.sh`: an image containing Werkzeug 2.2.2 is rejected (`CVE-2023-25577`); the app image passes. On its first run it failed the app image on zlib (CVE-2026-85091), fixed by re-pinning the distroless digest. Unfixed CVEs (89 HIGH in the Debian base) are reported but don't fail the gate |
| Misconfiguration scan (Trivy) of the chart as rendered by the pinned Helm, `platform/` and the Dockerfile; any finding fails; images only from `localhost:5001` (KSV-0125). Accepted findings in [tools/trivy/trivyignore.yaml](tools/trivy/trivyignore.yaml), each scoped to one file, with a reason and an expiry | A manifest or Dockerfile change that weakens the platform (privileged pods, broader RBAC, another registry) merged without anyone noticing | [Makefile](Makefile) (`make scan-iac`), [tools/trivy/](tools/trivy/) | `test_gates.sh`: a privileged pod is rejected (`KSV-0017`); the repo passes; with their expiry dates moved into the past, all 5 accepted findings fail again |
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
platform/           namespaces (PSA labels), admission policies, NetworkPolicies, deployer RBAC
airgap/             image inventory script (images.txt), later the mirror script and offline notes
images.txt          generated: every third-party image, pinned by digest
tests/security/     scripts that prove controls are enforced on a live cluster
tests/gates/        proves each CI security gate rejects planted bad input
tools/              hash-locked Python scanners, Trivy exceptions and check data, git hooks
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
| 6a | Native admission policies (ValidatingAdmissionPolicy), including ClusterIP-only Services without `externalIPs` in `app` | done |
| 7 | CI pipeline with security gates | done |
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
- [0010: Built-in admission policies for what PSA can't express](docs/adr/0010-admission-policies.md)
- [0011: CI security gates: pinned scanners run by make, fail on findings, exceptions that expire](docs/adr/0011-ci-security-gates.md)

## License

[MIT](LICENSE)
