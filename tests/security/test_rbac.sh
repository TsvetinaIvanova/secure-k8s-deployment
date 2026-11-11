#!/usr/bin/env bash
# Phase 6: the deployer ServiceAccount can do what Helm needs in namespace app, and nothing
# that would let it read Secrets, run commands in pods, change the platform's controls,
# grant access or act outside app (ADR 0009).
# Every check uses a real token for the ServiceAccount, not impersonation (--as), so the
# token path `make deploy` uses is what is tested.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
echo "== test_rbac: namespace $NS"

SA=system:serviceaccount:deploy:app-deployer
DKC=$(mktemp)
trap 'rm -f "$DKC" "$DKC.tmp"' EXIT
"$(dirname "$0")/../../cluster/deployer-kubeconfig.sh" "$KUBECTL" "$DKC" >/dev/null || { fail "could not get a deployer token"; exit 1; }
d() { KUBECONFIG=$DKC "$KUBECTL" "$@"; }

who=$(d auth whoami -o jsonpath='{.status.userInfo.username}' 2>/dev/null)
[[ $who == "$SA" ]] && pass "deployer token authenticates as $SA" || fail "deployer token authenticates as '$who', want $SA"

# exp - iat from the JWT payload (base64url, padding stripped).
payload=$(sed -n 's/^ *token: //p' "$DKC" | cut -d. -f2 | tr '_-' '/+')
while (( ${#payload} % 4 )); do payload+='='; done
ttl=$(base64 -d <<<"$payload" 2>/dev/null | python3 -c 'import sys,json; c=json.load(sys.stdin); print(c["exp"]-c["iat"])' 2>/dev/null)
[[ -n $ttl ]] && (( ttl <= 600 )) && pass "deployer token expires after ${ttl}s" || fail "deployer token lifetime '$ttl', want <= 600s"

legacy=$(k -n deploy get secrets --field-selector type=kubernetes.io/service-account-token -o name)
[[ -z $legacy ]] && pass "no long-lived token Secret in namespace deploy" || fail "long-lived token Secret exists: $legacy"

# Usage: expect_can <yes|no> <verb> <resource[/subresource]> [namespace, default app]
# Subresources go through --subresource: `can-i get pods/log` would ask about a pod named "log".
expect_can() {
  local got res=${3%%/*} sub=()
  [[ $3 == */* ]] && sub=(--subresource "${3#*/}")
  got=$(d auth can-i "$2" "$res" "${sub[@]}" -n "${4:-$NS}" 2>/dev/null)
  [[ $got == "$1" ]] && pass "can-i $2 $3 -n ${4:-$NS}: $got" || fail "can-i $2 $3 -n ${4:-$NS}: '$got', want $1"
}

# What Helm needs: render, upgrade, wait for the rollout, store the release record.
expect_can yes create deployments.apps
expect_can yes patch services
expect_can yes create configmaps
expect_can yes watch pods

# Secrets: neither directly nor through Helm's release storage.
expect_can no get secrets
expect_can no list secrets
expect_can no create secrets
# Pods: no direct creation, and no way into a running one.
expect_can no create pods
expect_can no create pods/exec
expect_can no create pods/attach
expect_can no create pods/portforward
expect_can no get pods/log
expect_can no patch pods/ephemeralcontainers
expect_can no create serviceaccounts/token
# The platform's controls and access itself.
expect_can no patch networkpolicies.networking.k8s.io
expect_can no create rolebindings.rbac.authorization.k8s.io
expect_can no escalate roles.rbac.authorization.k8s.io
expect_can no bind clusterroles.rbac.authorization.k8s.io
expect_can no patch namespaces
expect_can no create validatingadmissionpolicies.admissionregistration.k8s.io
# Outside app, including its own namespace.
expect_can no create deployments.apps client
expect_can no create deployments.apps default
expect_can no create deployments.apps kube-system
expect_can no get secrets deploy

# Real requests, rejected by RBAC. --dry-run=server: full authorization and admission, nothing
# stored. Each is first sent as admin, so a rejection can only come from the deployer's rights.
# Usage: expect_forbidden <description> <kubectl args...>
expect_forbidden() {
  local desc=$1 out; shift
  if ! out=$(k "$@" 2>&1); then
    fail "$desc: control request failed as admin: $out"; return
  fi
  # On success the output isn't printed: it can be a Secret or a token.
  if out=$(d "$@" 2>&1); then
    fail "$desc: allowed, want forbidden"
  elif grep -qi forbidden <<<"$out"; then
    pass "$desc: forbidden"
  else
    fail "$desc: want forbidden, got: $(head -1 <<<"$out")"
  fi
}

expect_forbidden "read the app Secret" -n $NS get secret app-secret -o name
expect_forbidden "delete the default-deny NetworkPolicy" -n $NS delete networkpolicy default-deny-all --dry-run=server
expect_forbidden "bind admin to itself in app" -n $NS create rolebinding rbac-test --clusterrole=admin \
  --serviceaccount=deploy:app-deployer --dry-run=server
expect_forbidden "relabel namespace app to privileged" label ns $NS pod-security.kubernetes.io/enforce=privileged \
  --overwrite --dry-run=server
expect_forbidden "mint a token for the app ServiceAccount" -n $NS create token app --duration=10m

exit $FAILED
