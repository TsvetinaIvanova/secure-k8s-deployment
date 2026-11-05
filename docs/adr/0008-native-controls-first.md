# 0008: Native Kubernetes controls first; in-cluster add-ons are stretch goals

- **Status:** accepted
- **Date:** 2026-11-05

## Context

The roadmap mixed two kinds of control: those any Kubernetes cluster already offers, and those that need extra software installed into it. Kyverno (Phase 5) was next in line, ahead of RBAC, which is built in. Vault (Phase 10), Loki and Grafana (Phase 11), and cosign `verifyImages` (S1) also add components to the cluster.

## Decision

Cover the security measures that apply to a clean Kubernetes cluster first. Phases that add external tooling to the cluster become stretch goals: 5, 10, 11 and S1. Phases keep their numbers, so existing references stay valid.

"External tooling" means a component running in the cluster or added to it, such as a controller, webhook, operator or backend. Two phases stay in the core roadmap under that definition:

- **Phase 7 (CI gates):** the scanners run in CI, and nothing is installed into the cluster.
- **Phase 8 (air-gap):** it extends the local registry and containerd mirror configuration already in use (ADR 0003).

## Alternatives considered

- **Keep Kyverno as Phase 5:** it reaches further than PSA sooner, but it would come before a native control the project hasn't covered yet.
- **Drop these phases:** they cover real gaps listed below. Deferring keeps them available.
- **Count every third-party tool as external, including CI scanners:** Phase 7 would become a stretch goal too, and the project would have no security gates in CI. The distinction here is about what a cluster has to run.

## Consequences

- Until Phase 6a, admission enforcement stops at PSA's fixed rules. `readOnlyRootFilesystem` and resource limits are set in the chart but not enforced, no registry allowlist exists, and a non-compliant Deployment is still accepted, with only its pods rejected (ADR 0006).
- ValidatingAdmissionPolicy is built in (`admissionregistration.k8s.io/v1` on this v1.37 cluster), so it meets the native-first rule and can close the validation gap. It is added as Phase 6a, after RBAC, keeping the numbers of later phases unchanged. It doesn't replace Kyverno's `generate`, `verifyImages` or policy reports.
- New namespaces start without a default-deny policy, because nothing generates one (ADR 0007).
- The app Secret stays a static value created by `make deploy`, with no rotation mechanism until Phase 10 (ADR 0005). The unit tests cover what exists: the app re-reads the file on each request.
- No security log aggregation until Phase 11. This cluster also has no API audit log.
- S1 depends on Phase 5, because `verifyImages` is a Kyverno rule.
- Accepted ADRs that name Phases 5 or 10 describe what those phases do if built, not a commitment to build them.
