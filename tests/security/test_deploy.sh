#!/usr/bin/env bash
# Phase 2 controls on the deployed app: digest-pinned images, no API credentials,
# and the secret kept out of Helm's release history.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
echo "== test_deploy: namespace $NS"

images=$(k -n $NS get pods -l app.kubernetes.io/name=app -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}')
if [[ -n $images ]] && ! grep -qv '@sha256:' <<<"$images"; then
  pass "all app pods reference their image by digest"
else
  fail "app pod image not pinned by digest: $(grep -v '@sha256:' <<<"$images" | head -1)"
fi

vols=$(k -n $NS get pods -l app.kubernetes.io/name=app -o jsonpath='{.items[*].spec.volumes[*].name}')
grep -q kube-api-access <<<"$vols" && fail "a ServiceAccount token is mounted" || pass "no ServiceAccount token mounted"

for verb in "list pods" "get secrets" "create pods"; do
  if [[ $(k auth can-i $verb -n $NS --as=system:serviceaccount:$NS:app 2>/dev/null) == no ]]; then
    pass "app ServiceAccount cannot $verb"
  else
    fail "app ServiceAccount can $verb"
  fi
done

token=$(k -n $NS get secret app-secret -o jsonpath='{.data.token}' | base64 -d)
release=$(k -n $NS get secret -l owner=helm,status=deployed -o jsonpath='{.items[0].data.release}' | base64 -d | base64 -d | gunzip)
if [[ -z $token || -z $release ]]; then
  fail "could not read the app Secret or the Helm release record"
elif grep -qF "$token" <<<"$release"; then
  fail "secret value found in the Helm release record"
else
  pass "secret value not in the Helm release record"
fi

if port_forward $NS app 18082; then
  want=$(printf '%s' "$token" | sha256sum | cut -c1-12)
  resp=$(curl -s localhost:18082/)
  got=$(python3 -c 'import sys,json; print(json.loads(sys.argv[1])["secret_fingerprint"])' "$resp" 2>/dev/null)
  [[ $got == "$want" ]] && pass "app serves the mounted Secret (fingerprint $got)" || fail "fingerprint: want $want, got '$got'"
  grep -qF "$token" <<<"$resp" && fail "response contains the secret" || pass "response does not contain the secret"
else
  fail "app not reachable through its Service"
fi

exit $FAILED
