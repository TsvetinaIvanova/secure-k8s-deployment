#!/usr/bin/env bash
# Phase 3: Pod Security Admission enforces "restricted" in namespace app.
# Each bad pod is the compliant pod with exactly one field broken, and the compliant pod
# itself must be admitted, so a rejection can only come from that field.
# --dry-run=server runs the full admission chain (PSA included) but stores nothing.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
echo "== test_psa: namespace $NS"

labels=$(k get ns $NS -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}:{.metadata.labels.pod-security\.kubernetes\.io/enforce-version}')
[[ $labels == restricted:v1.37 ]] && pass "namespace enforces restricted:v1.37" || fail "namespace enforce label is '$labels', want restricted:v1.37"

# The app's own image, so a later registry or tag policy (Phase 5) can't be what rejects these pods.
IMAGE=$(k -n $NS get deploy app -o jsonpath='{.spec.template.spec.containers[0].image}')

# Usage: pod <name> <pod securityContext> <container securityContext> [extra container fields] [pod volumes]
pod() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: psa-test-$1, namespace: $NS}
spec:
  automountServiceAccountToken: false
  securityContext: $2
  containers:
    - name: c
      image: $IMAGE
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}
      securityContext: $3
${4:-}
${5:-}
EOF
}
POD_SC='{runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}'
CTR_SC='{allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}'

if out=$(pod compliant "$POD_SC" "$CTR_SC" | k apply --dry-run=server -f - 2>&1); then
  pass "compliant pod admitted"
else
  fail "compliant pod rejected, so the rejections below prove nothing: $out"
fi

# Usage: expect_rejected <description> <manifest>
expect_rejected() {
  local out
  if out=$(k apply --dry-run=server -f - <<<"$2" 2>&1); then
    fail "$1: admitted"
  elif grep -q 'violates PodSecurity "restricted:v1.37"' <<<"$out"; then
    pass "$1: rejected"
    echo "      ${out#*violates }"
  else
    fail "$1: rejected, but not by PodSecurity: $out"
  fi
}

# allowPrivilegeEscalation is left out: privileged implies it, and setting it false next
# to privileged: true fails API validation before admission ever runs.
expect_rejected "privileged container" \
  "$(pod privileged "$POD_SC" '{capabilities: {drop: [ALL]}, privileged: true}')"
expect_rejected "root user (runAsUser 0, runAsNonRoot unset)" \
  "$(pod root '{runAsUser: 0, seccompProfile: {type: RuntimeDefault}}' "$CTR_SC")"
expect_rejected "hostPath volume" \
  "$(pod hostpath "$POD_SC" "$CTR_SC" '      volumeMounts: [{name: host, mountPath: /host}]' \
     '  volumes: [{name: host, hostPath: {path: /}}]')"

# PSA checks pods only when they are created or updated. Labelling an existing namespace
# never evicts anything, so ask the API server whether the running pods meet the level.
warnings=$(k label --dry-run=server --overwrite ns $NS pod-security.kubernetes.io/enforce=restricted 2>&1 >/dev/null)
running=$(k -n $NS get pods -l app.kubernetes.io/name=app --field-selector=status.phase=Running -o name | wc -l)
if [[ -z $warnings && $running -gt 0 ]]; then
  pass "all $running running app pods comply with restricted"
else
  fail "running app pods: $running; violations: ${warnings:-none}"
fi

exit $FAILED
