# 0005: Keep the app Secret out of the Helm chart

- **Status:** accepted
- **Date:** 2026-10-26

## Context

The app reads its secret from a mounted Kubernetes Secret. The obvious approach is a `secret.yaml` template filled from a chart value (`--set secret.token=...`). But Helm stores the full set of values, gzipped and base64-encoded, in its release record: a Secret in the release namespace, one per revision. The value would then exist in every revision of the release history and in the values passed on the command line, possibly in shell history or CI logs, and anyone who can read Helm's release Secrets could recover it.

## Decision

The chart only *references* the Secret by name (`secret.name`) and mounts it. It does not create it. `make deploy` creates `app-secret` once, if it does not exist yet:

- with a random 32-byte value piped through stdin (`--from-file=token=/dev/stdin`), so the value is never in process arguments, shell history or a file on disk;
- with `kubectl create`, not `kubectl apply`, because client-side apply stores a full copy of the object in the `last-applied-configuration` annotation.

Later redeploys keep the existing value. Rotation is a separate operation (Phase 10).

## Alternatives considered

- **Secret templated from a chart value:** simple, but the value ends up in the release history as described above.
- **`lookup` in the template to keep an existing value:** `lookup` returns nothing under `helm template` or `--dry-run`, so CI renders differ from real installs, and the value still lands in the release record.
- **Sealed Secrets / SOPS-encrypted values in git:** good for GitOps, but this repo goes straight to Vault (Phase 10) instead.

## Consequences

- Verified: the decoded Helm release record contains the image digest but not the secret value.
- Phase 10 replaces the `make deploy` step with Vault / External Secrets Operator creating the same Secret. The chart doesn't change.
- If the Secret is missing, the pods start but stay not-ready (`/readyz` returns 503), so the rollout times out instead of serving without a secret.
- This departs from the plan's "chart with a Secret": the chart has a Secret *mount*, not a Secret *object*.
