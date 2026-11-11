# 0007: NetworkPolicies: platform-owned, no egress, standard API only

- **Status:** accepted
- **Date:** 2026-11-04

## Context

Pods accept traffic from anywhere in the cluster and can send it anywhere unless a policy selects them. The app only answers HTTP and reads a mounted file, so it needs one inbound path and no outbound one. Three questions: who owns the policies, what egress to allow, and which API to use.

## Decision

- Policies live in `platform/networkpolicies/` and are applied by `make platform`, not by the chart.
- `default-deny-all` selects every pod in namespace `app`, for ingress and egress.
- `allow-client-ingress` admits only pods labelled `test-client` in namespace `client`, on TCP 8080: the pod's port, because the policy is evaluated after the Service translates port 80.
- No egress rules, including DNS. The app never resolves a name, and open DNS is a route for exfiltration.
- Only the standard `networking.k8s.io/v1` API.

## Alternatives considered

- **Policies in the chart:** they would travel with the app's labels and port, but whoever controls the chart could widen access in the same change as the code, and `helm uninstall` would remove them. Same reasoning as ADR 0006.
- **Allow DNS egress:** the usual default-deny companion, and needed by most apps. Unused here, so it would only add a channel.
- **ClusterNetworkPolicy:** adds cluster-wide tiers and explicit deny that namespace owners can't override. It is a CRD, at `v1alpha2` in the latest release (v0.2.1), and not available on this cluster. The right direction for shared production clusters once mature, alongside these policies rather than instead of them.
- **Vendor policies (Calico, Cilium):** would need a different CNI (ADR 0002).

## Consequences

- If the chart changes its selector labels or port, the policy doesn't follow. Traffic is blocked rather than opened, and `test_netpol.sh` fails.
- NetworkPolicy has no explicit deny, so anyone who can write one in `app` can widen access. RBAC must exclude that from the deployer (done in Phase 6, ADR 0009).
- New namespaces start open, and `client` and `default` have no policies. Kyverno `generate` can create a default-deny (Phase 5).
- Traffic from a pod's own node is always allowed, so kubelet probes need no rule. `kubectl port-forward` also keeps working, so it proves nothing about policy; the tests send traffic from real pods.
- `hostNetwork` pods generally aren't subject to NetworkPolicy. PSA `restricted` rejects them in `app` (`test_psa.sh`).
- `test_netpol.sh` passes only on a timeout, since a refused connection doesn't show a policy dropped the packet. It needs a live cluster, and it isn't in CI yet (Phase 7).
- `kubectl apply` doesn't prune: deleting a policy file leaves the policy on the cluster until it is removed by hand.
- If the app starts calling a service directly (for example Vault in Phase 10), it needs a specific egress rule and DNS, and this decision is revisited.
