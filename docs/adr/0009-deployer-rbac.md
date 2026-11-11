# 0009: Deployer RBAC: a namespaced Role, short-lived tokens, no Secrets

- **Status:** accepted
- **Date:** 2026-11-11

## Context

Until now `make deploy` ran Helm with the cluster-admin kubeconfig that kind creates. Whoever deploys the app could therefore also delete the NetworkPolicies, relabel the namespace out of Pod Security `restricted`, read every Secret and grant themselves anything. The app's own ServiceAccount already has no rights (Phase 2); the deploying identity is the remaining broad one.

## Decision

- **Identity:** ServiceAccount `app-deployer` in its own namespace, `deploy`, where nothing runs. A pod can only use a ServiceAccount from its own namespace, so nothing deployed into `app` can run as the deployer.
- **Credentials:** `make deploy` gets a token from the TokenRequest API, valid for 10 minutes (the minimum), and writes it into `.kube/deployer` (mode 600, gitignored). No Secret-based token exists, so there is nothing long-lived to leak.
- **Rights:** Role `app-deployer` in `app` only: full control of Deployments, Services, ServiceAccounts and ConfigMaps; read-only ReplicaSets and Pods so `--wait=watcher` can follow the rollout. Nothing else.
- **Helm release storage in ConfigMaps** (`HELM_DRIVER=configmap`): with the default Secret driver, Helm lists Secrets by label, and RBAC can't limit `list` by name or label, so the deployer could read `app-secret`. The release record holds no secret values (ADR 0005), so ConfigMaps are enough.
- **The platform keeps the rest:** namespaces, NetworkPolicies, RBAC and the app Secret are applied by `make platform` with the admin kubeconfig.

Verified on the cluster: install, upgrade with a rollout, and `helm rollback` all work with only these rights.

## Alternatives considered

- **Bind the built-in `edit` ClusterRole in `app`:** one line, but it includes Secrets, `pods/exec`, `pods/portforward`, ServiceAccount tokens and NetworkPolicies. `test_rbac.sh` fails 13 checks with it bound.
- **Keep the Secret driver and grant Secrets:** the deployer could then read the app Secret directly.
- **A user with a client certificate signed by the cluster CA:** Kubernetes can't revoke a client certificate before it expires.
- **A long-lived ServiceAccount token Secret:** works with any tool, but stays valid until deleted.

## Consequences

- Creating Deployments in `app` still means running any code there, and that code can mount the namespace's Secrets. RBAC can't separate "deploy" from "what the deployed code can reach". The limits are elsewhere: PSA `restricted`, no egress (ADR 0007) and no `exec`, `log` or `portforward` for the deployer. A pod could still surface a Secret through its own status, for example a termination message, which the deployer can read. Phase 6a can narrow what a pod template may mount.
- The deployer can still change the app's ServiceAccount, Service and ConfigMap, which the chart owns. It can't give the ServiceAccount rights, since it can't create RoleBindings.
- Moving from the Secret driver leaves old `sh.helm.release.v1.app.v*` Secrets in `app`. Helm adopts the running objects on the next deploy (verified); the old Secrets can be deleted by hand, or the cluster rebuilt.
- The admin kubeconfig is still cluster-admin and is used for `make up`, `make platform` and the tests. Splitting platform administration into its own role is out of scope for a single local cluster.
- Removing a rule from the Role takes effect on the next `make platform`. Deleting an object from `deployer.yaml` doesn't remove it from the cluster, because `kubectl apply` doesn't prune; it has to be deleted by hand.
