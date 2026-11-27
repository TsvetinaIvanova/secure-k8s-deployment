# 0013: Kyverno: CEL policies, installed by the platform, exceptions in one namespace, fail closed

- **Status:** accepted
- **Date:** 2026-11-26

## Context

ADR 0012 puts Kyverno next. The gaps it should close are already recorded: no admission rule limits which registry an image in `app` comes from (ADRs 0010, 0012), and a new namespace starts with no Pod Security labels and no NetworkPolicy, so anything runs in it and all traffic is allowed (ADR 0007). Kyverno v1.20 removed the legacy `kyverno.io` ClusterPolicy and PolicyException; only the CEL types in `policies.kyverno.io/v1` are enforced.

## Decision

- **Install:** Kyverno v1.20.0 from chart 3.10.0. The chart file is checked against a SHA-256 in the Makefile, and every image is pinned by digest. `make kyverno` installs it as admin into namespace `kyverno` (Pod Security `restricted`); the deployer has no rights there.
- **Policies,** each closing one recorded gap and none repeating the Phase 6a rules:
  - `app-image-registry` (validate): images in `app` come only from `localhost:5001/`.
  - `namespace-pod-security-defaults` (mutate) and `namespace-pod-security` (validate): new namespaces get `restricted` labels, and no namespace can set a weaker `enforce` level or an older `enforce-version`. Mutate alone would leave an explicit `privileged` untouched.
  - `namespace-default-deny` (generate, synchronized): every new namespace gets default-deny for ingress and egress, and Kyverno restores it if it is deleted or edited.
- **Exceptions** are enabled, but Kyverno only honours ones in namespace `kyverno`. There are two: the NetworkPolicy test's curl probe, pinned by name, label and digest, and namespaces `app` and `client` for the generated policy, because the platform owns their NetworkPolicies.
- **Failure mode:** `failurePolicy: Fail`. If Kyverno can't be reached, matching requests are rejected. The webhook skips `kube-system` and `kyverno`, so Kyverno itself can always be repaired.

## Alternatives considered

- **Add the registry rule to `app-workloads` (ValidatingAdmissionPolicy):** no add-on in the admission path, but an exception would mean editing the rule's CEL, and nothing would report on running workloads.
- **`failurePolicy: Ignore`:** an outage or a slow webhook would admit everything unchecked, which an attacker can cause.
- **Exceptions allowed in any namespace:** anyone who can create objects in `app` could exempt their own workloads.
- **Copy the Phase 6a rules into Kyverno:** two engines enforcing the same rule drift apart, and it's no longer clear which one is in charge.

## Consequences

- While Kyverno is unreachable, Pods and workloads in `app` and new namespaces are rejected until it is back (`test_kyverno.sh` simulates this).
- Kyverno deletes its own webhooks when its Deployment is scaled to 0 or deleted. It treats that as an admin removing Kyverno, not as an outage. The Kyverno rules then stop with no error, while the Phase 6a policies keep enforcing digests, limits and the read-only root. Only admin can do this; the test checks that the deployer can't.
- The generate policy matches namespace updates as well as creation. With creation only, Kyverno deleted the generated policy on any namespace update, for example adding a label. Building this phase found that; it's tested.
- Not matched: `default`, `kube-system`, `kube-public`, `kube-node-lease`, `local-path-storage`. `default` keeps no Pod Security labels. `kyverno` has no NetworkPolicy, because the API server must reach its webhook.
- The chart's ClusterRoles let Kyverno's background controller create and delete Roles, RoleBindings and NetworkPolicies cluster-wide. That's needed for generate; trimming those ClusterRoles is left for later.
- `enforce-version: v1.37` is pinned in the policies as in ADR 0006, and moves with a cluster upgrade. The curl digest is pinned in both `test_netpol.sh` and the exception.
- CI adds an offline `policy-test` job, and e2e takes longer while it pulls the Kyverno images.
