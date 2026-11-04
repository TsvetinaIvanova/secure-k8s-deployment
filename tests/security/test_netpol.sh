#!/usr/bin/env bash
# Phase 4: NetworkPolicies in namespace app. Only the labelled client pod in namespace client
# reaches the app, only on 8080, and pods in the namespace have no egress, DNS included.
# Pods are real, not dry-run: only traffic that is actually sent can prove enforcement.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
echo "== test_netpol: namespace $NS"

# Has curl and sleep, and runs as non-root. Pinned here; list-images.sh reads this line.
TEST_IMAGE=docker.io/curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93

CLIENT_NS=client
OUTSIDE_NS=default   # no policies, so this pod shows what the network allows without them
APP_LABELS='app.kubernetes.io/name=app,app.kubernetes.io/instance=app'
TEST_PODS=("$CLIENT_NS allowed" "$CLIENT_NS unlabelled" "$OUTSIDE_NS outsider" "$NS probe")

POD_SC='{runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}'
CTR_SC='{allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}'

# Usage: test_pod <namespace> <name> [labels, e.g. "a: b"]
test_pod() {
    k apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata: {name: netpol-test-$2, namespace: $1, labels: {security-test: netpol, ${3:-}}}
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  securityContext: $POD_SC
  containers:
    - name: c
      image: $TEST_IMAGE
      command: [sleep, "3600"]
      resources: {requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}
      securityContext: $CTR_SC
EOF
}

# Runs on any normal exit or failure. A hard kill skips it: `make clean-test-pods` covers that.
cleanup() {
  k delete pods -A -l security-test=netpol --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT

test_pod "$CLIENT_NS" allowed "app.kubernetes.io/name: test-client"
test_pod "$CLIENT_NS" unlabelled
test_pod "$OUTSIDE_NS" outsider
test_pod "$NS" probe

for entry in "${TEST_PODS[@]}"; do
  read -r ns name <<<"$entry"
  if ! k -n "$ns" wait --for=condition=Ready "pod/netpol-test-$name" --timeout=60s >/dev/null; then
    fail "pod $ns/netpol-test-$name not Ready, so the checks below would prove nothing"
    exit 1
  fi
done

# Prints curl's exit code: 0 connected (any HTTP status), 6 name not resolved, 7 refused, 28 timed out.
# Usage: curl_code <namespace> <pod> <url>
curl_code() {
  k -n "$1" exec "netpol-test-$2" -- curl -sk -o /dev/null --connect-timeout 3 --max-time 4 "$3" >/dev/null 2>&1
  echo $?
}

# Usage: expect_reaches <description> <namespace> <pod> <url>
expect_reaches() {
  local code
  code=$(curl_code "$2" "$3" "$4")
  [[ $code == 0 ]] && pass "$1: connected" || fail "$1: curl exit $code, want 0"
}

# Only a timeout counts: a dropped packet times out. Any other failure, such as a missing tool
# or a refused connection, doesn't show that a policy blocked the traffic.
# Usage: expect_blocked <description> <namespace> <pod> <url>
expect_blocked() {
  local code
  code=$(curl_code "$2" "$3" "$4")
  [[ $code == 28 ]] && pass "$1: blocked (timed out)" || fail "$1: curl exit $code, want 28"
}

APP_URL=http://app.$NS.svc.cluster.local
APP_POD_IP=$(k -n "$NS" get pods -l "$APP_LABELS" -o jsonpath='{.items[0].status.podIP}')
API_IP=$(k -n default get svc kubernetes -o jsonpath='{.spec.clusterIP}')
API_NAME=kubernetes.default.svc.cluster.local

# Ingress. Port 9999 has no listener: without a policy it is refused (7), not timed out (28).
expect_reaches "labelled client in $CLIENT_NS to app" "$CLIENT_NS" allowed "$APP_URL/healthz"
expect_blocked "labelled client to app pod on port 9999" "$CLIENT_NS" allowed "http://$APP_POD_IP:9999/"
expect_blocked "unlabelled pod in $CLIENT_NS to app" "$CLIENT_NS" unlabelled "$APP_URL/healthz"
expect_blocked "pod in $OUTSIDE_NS to app" "$OUTSIDE_NS" outsider "$APP_URL/healthz"

# Egress. The control shows these destinations answer when no policy applies, by IP and by name.
expect_reaches "control: pod in $OUTSIDE_NS to API server by IP" "$OUTSIDE_NS" outsider "https://$API_IP/"
expect_reaches "control: pod in $OUTSIDE_NS to API server by name" "$OUTSIDE_NS" outsider "https://$API_NAME/"
expect_blocked "pod in $NS to API server by IP" "$NS" probe "https://$API_IP/"
expect_blocked "pod in $NS to API server by name (DNS denied)" "$NS" probe "https://$API_NAME/"

# The probe has default-deny alone. Any egress rule in the namespace could give the app more than that.
egress=$(k -n "$NS" get netpol -o jsonpath='{.items[*].spec.egress}')
[[ -z $egress ]] && pass "no egress rules in namespace $NS" || fail "egress rules found: $egress"

# A policy that broke kubelet probes would show up as app pods dropping out of Ready.
not_ready=$(k -n "$NS" get pods -l "$APP_LABELS" -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' | grep -vc '^True$')
[[ $not_ready == 0 ]] && pass "app pods stay Ready under the policies" || fail "$not_ready app pods not Ready"

exit $FAILED
