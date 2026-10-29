# 0006: Pod Security Admission: pinned enforce, latest warn/audit, namespace owned by the platform

- **Status:** accepted
- **Date:** 2026-10-29

## Context

Pod Security Admission (PSA) is the API server's built-in check of pods against the `privileged`, `baseline` or `restricted` standard. It is configured per namespace with labels, one per mode (`enforce` rejects, `audit` logs, `warn` returns a warning), each with its own level and version. The checks behind a level change between Kubernetes releases, and an unset version means `latest`.

Two questions: which versions the labels pin, and who creates namespace `app`. Until now `make deploy` created it as an empty namespace, which admits anything.

## Decision

- `enforce: restricted` pinned to `enforce-version: v1.37`, the cluster's minor version.
- `warn` and `audit` at `restricted`, version `latest`.
- The namespace is defined in `platform/namespaces.yaml` and applied by `make platform` before the chart is installed. The chart does not create namespaces.

## Alternatives considered

- **Every mode at `latest`:** a cluster upgrade could start rejecting pods that were valid the day before, with no change in the repo.
- **Every mode pinned:** fits "pin everything", but then nothing reports which pods would break under the next version's rules until the pin is raised. `warn`/`audit` never block anything, so tracking `latest` there costs nothing and gives early warning. This is a deliberate exception to the pinning rule.
- **Namespace created by Helm (`--create-namespace` or a template):** the namespace would come from the app's release, so whoever controls the chart controls its security level, and uninstalling the release deletes the namespace. Kept separate so the platform owns the guardrails and the app only deploys into them.
- **Cluster-wide default (an `AdmissionConfiguration` file on the API server):** the right tool for "restricted unless stated otherwise" on a real cluster. Left out here because it needs API server flags (a kind config patch), and every exempt system namespace would need to be listed. Noted for production.

## Consequences

- Upgrade path: upgrade the cluster, read the `warn`/`audit` output, fix workloads, then raise `enforce-version` in a reviewed change.
- `enforce` checks Pods only. A Deployment with a non-compliant template is accepted and its ReplicaSet then fails to create pods, which shows up only as an event, plus a client warning from the `warn` label. Kyverno (Phase 5) rejects the Deployment itself.
- Labelling a namespace that already has pods evicts nothing. Before tightening a namespace, `kubectl label --dry-run=server` lists existing pods that would violate the level. `test_psa.sh` uses the same check.
- The namespace name is fixed (`override NAMESPACE := app` in the Makefile, `NS=app` in `tests/security/lib.sh`), not a setting: Phases 4–6 name it in plain YAML. A second instance would mean templating `platform/` (e.g. Kustomize) with its own ADR.
- PSA's levels are fixed. It can't require `readOnlyRootFilesystem`, registries or resource limits; those are Kyverno policies.
