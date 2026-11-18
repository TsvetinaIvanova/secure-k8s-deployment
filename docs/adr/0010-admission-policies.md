# 0010: Built-in admission policies for what PSA can't express

- **Status:** accepted
- **Date:** 2026-11-18

## Context

Pod Security Admission checks a fixed list of pod fields (ADR 0006). It can't require a read-only root filesystem, resource limits or a pinned image, and it checks only Pods, so a Deployment with a bad template is accepted and fails later at pod creation. The deployer also has full control of Services in `app`, and RBAC can't restrict Service fields: it can set `externalIPs` (CVE-2020-8554) or expose the app through NodePort, LoadBalancer or ExternalName (ADR 0009). ValidatingAdmissionPolicy (VAP) is built into this v1.37 cluster, so it meets the native-first rule (ADR 0008).

## Decision

Two cluster-scoped policies in `platform/admission/`, applied by `make platform` before anything is deployed:

- **`app-workloads`:** every container and init container needs `readOnlyRootFilesystem: true`, CPU and memory limits, and an image pinned by digest. It matches Pods and the pod templates of Deployments, ReplicaSets, StatefulSets, DaemonSets, Jobs and CronJobs, so a bad Deployment is itself rejected.
- **`app-services`:** `type: ClusterIP` and no `externalIPs`.
- **Bindings:** namespace `app` only, selected by `kubernetes.io/metadata.name`, which the API server resets to the namespace's name on every write. A namespace can't relabel itself out of scope, and another namespace can't claim to be `app`. `validationActions: [Deny]`, because this cluster has no audit log for `Audit`. `failurePolicy: Fail`, so a CEL error rejects the request instead of skipping the check.
- **No exemptions:** the policies don't depend on who sends the request, so cluster-admin is checked too. Only the platform can change them, because they are cluster-scoped and the deployer's Role is namespaced.

## Alternatives considered

- **Kyverno:** adds mutation, `generate`, `verifyImages` and policy reports, but it is an in-cluster add-on with its own webhook failure modes. It remains the Phase 5 stretch goal, and this ADR doesn't replace it.
- **A registry allowlist now (`localhost:5001/` only):** `test_netpol.sh` runs a `docker.io/curlimages/curl` probe in `app`, and every third-party image still comes from a public registry. An allowlist fits better in Phase 8, when `images.txt` is mirrored locally. Until then, digest pinning keeps the bytes fixed, but it doesn't limit where they come from.
- **Bind cluster-wide:** `kube-system` and kind's components use images by tag. They would each need an exclusion, and the project's scope is `app`.
- **Match `pods/ephemeralcontainers`:** the deployer can't add debug containers (ADR 0009), and `kubectl debug` sets neither a digest nor a read-only root. Matching it would block admin debugging of a distroless image while defending only against admin, who can edit the policy anyway.

## Consequences

- A new or changed policy checks only objects created or updated afterwards, and the API server takes a few seconds to start enforcing it. `test_admission.sh` re-sends the running Deployment and Service as updates to show they comply.
- Debug containers are covered only by PSA, not by these rules.
- Secret mounts are not narrowed. A pod template in `app` can still mount any Secret in the namespace (ADR 0009). Today the only one there is `app-secret`.
- Workload kinds not listed above, such as a custom controller's CRDs, are checked only when their Pods are created, as with PSA.
- The namespace name is fixed in the bindings, as everywhere in `platform/` (ADR 0006).
