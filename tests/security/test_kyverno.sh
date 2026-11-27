#!/usr/bin/env bash
# Phase 5: Kyverno policies (ADR 0013), on the live cluster.
#  - app-image-registry: images in namespace app only from localhost:5001, one narrow exception
#  - PolicyExceptions count only in namespace kyverno, and the deployer can't create them
#  - namespace-pod-security(-defaults): new namespaces enforce restricted; can't be weakened
#  - namespace-default-deny: new namespaces get default-deny, kept in sync
#  - PolicyReports record the deployed app
#  - fail closed: with Kyverno unreachable, app rejects requests and kube-system still works.
#    "Unreachable" is simulated by giving the webhook Service no endpoints and restarting the
#    admission controller, which also drops the API server's open connection to it (with only
#    the Service changed, the API server kept using that connection). Scaling Kyverno to 0
#    is not an outage: Kyverno then deletes its own webhooks by design (ADR 0013), so only the
#    platform can do it, which is checked below.
#
# Each rejected object is the admitted one with one field changed. --dry-run=server runs the
# full admission chain, webhooks included, and stores nothing.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
echo "== test_kyverno: policies in namespace $NS and on namespaces"

KNS=kyverno
RUN=$RANDOM
TEST_NS=kyv-test-$RUN
CURL=docker.io/curlimages/curl:8.23.0@sha256:3fb7e13e5d179a845c97d78204f3f1064d1907037f26a3ebf91710571151fd93

DKC=$(mktemp)
SVC_SELECTOR='{"app.kubernetes.io/component":"admission-controller","app.kubernetes.io/instance":"kyverno","app.kubernetes.io/part-of":"kyverno"}'
restore_svc() { k -n $KNS patch svc kyverno-svc --type=json -p "[{\"op\":\"replace\",\"path\":\"/spec/selector\",\"value\":$SVC_SELECTOR}]" >/dev/null 2>&1; }
cleanup() {
  # Whatever happened, leave Kyverno reachable and no test objects behind.
  restore_svc
  k delete ns "$TEST_NS" --wait=false >/dev/null 2>&1
  k -n $NS delete policyexception.policies.kyverno.io kyv-test-in-app --ignore-not-found >/dev/null 2>&1
  rm -f "$DKC" "$DKC.tmp"
}
trap cleanup EXIT
"$(dirname "$0")/../../cluster/deployer-kubeconfig.sh" "$KUBECTL" "$DKC" >/dev/null || { fail "could not get a deployer token"; exit 1; }
d() { KUBECONFIG=$DKC "$KUBECTL" "$@"; }

# Usage: expect_admitted <d|k> <description> <manifest>
expect_admitted() {
  local out
  if out=$($1 create --dry-run=server -f - <<<"$3" 2>&1); then
    pass "$2: admitted"
  else
    fail "$2: rejected, so the rejections below prove nothing: $out"
  fi
}
# Usage: expect_denied <d|k> <description> <policy> <message fragment> <manifest>
expect_denied() {
  local out
  if out=$($1 create --dry-run=server -f - <<<"$5" 2>&1); then
    fail "$2: admitted"
  elif grep -q "Policy $3 failed" <<<"$out" && grep -qF "$4" <<<"$out"; then
    pass "$2: rejected"
    echo "      ${out#*failed: }"
  else
    fail "$2: rejected, but not by $3 ($4): $out"
  fi
}
# Usage: wait_for <seconds> <command...>; true once the command succeeds.
wait_for() {
  local t=$1; shift
  for _ in $(seq 1 "$t"); do "$@" >/dev/null 2>&1 && return 0; sleep 1; done
  return 1
}

# --- Installed and ready ------------------------------------------------------------------
for dep in admission-controller background-controller cleanup-controller reports-controller; do
  ready=$(k -n $KNS get deploy kyverno-$dep -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [[ ${ready:-0} -ge 1 ]] && pass "kyverno-$dep ready" || fail "kyverno-$dep not ready"
done
for p in validatingpolicy/app-image-registry validatingpolicy/namespace-pod-security \
         mutatingpolicy/namespace-pod-security-defaults generatingpolicy/namespace-default-deny; do
  ready=$(k get "${p%%/*}.policies.kyverno.io" "${p#*/}" -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)
  [[ $ready == true ]] && pass "$p ready" || fail "$p: ready '$ready'"
done

# --- Registry allowlist in app --------------------------------------------------------------
IMAGE=$(k -n $NS get deploy app -o jsonpath='{.spec.template.spec.containers[0].image}')
# The deployed Deployment, re-sent by the deployer as an update, still passes.
if out=$(k -n $NS get deploy app -o json | d replace --dry-run=server -f - 2>&1); then
  pass "deployed app admitted as an update (deployer)"
else
  fail "deployed app rejected: $out"
fi
# Usage: deployment <name> <image>; otherwise compliant with app-workloads too.
deployment() {
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: kyv-test-$1, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {kyv-test: $1}}
  template:
    metadata: {labels: {kyv-test: $1}}
    spec:
      automountServiceAccountToken: false
      securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
      containers:
        - name: app
          image: $2
          securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true}
          resources: {limits: {cpu: 50m, memory: 32Mi}}
EOF
}
# Usage: pod <name> <image> [labels]
pod() {
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $1, namespace: $NS, labels: {${3:-}}}
spec:
  automountServiceAccountToken: false
  securityContext: {runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}
  containers:
    - name: c
      image: $2
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true}
      resources: {limits: {cpu: 50m, memory: 32Mi}}
EOF
}
expect_admitted d "Deployment from localhost:5001 (deployer)" "$(deployment local "$IMAGE")"
expect_denied d "Deployment from docker.io, pinned by digest (deployer)" app-image-registry "come from localhost:5001/" \
  "$(deployment public "$CURL")"
expect_denied k "Pod from docker.io (as admin)" app-image-registry "come from localhost:5001/" \
  "$(pod kyv-test-public "$CURL")"

# The one exception: the NetworkPolicy probe, exactly as test_netpol.sh creates it.
expect_admitted k "netpol probe with the pinned curl digest (exception)" \
  "$(pod netpol-test-probe "$CURL" "security-test: netpol")"
# Another digest (still pinned, so app-workloads lets it through to Kyverno): no exception.
expect_denied k "netpol probe with a different curl digest" app-image-registry "come from localhost:5001/" \
  "$(pod netpol-test-probe "${CURL%@*}@sha256:$(printf '0%.0s' {1..64})" "security-test: netpol")"

# --- Who can create exceptions, and where they count ------------------------------------------
for ns in $NS $KNS; do
  got=$(d auth can-i create policyexceptions.policies.kyverno.io -n $ns 2>/dev/null)
  [[ $got == no ]] && pass "deployer can-i create policyexceptions in $ns: no" || fail "deployer can-i create policyexceptions in $ns: '$got'"
done
# An exception outside namespace kyverno is ignored, even one created by admin.
k apply -f - >/dev/null <<EOF
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata: {name: kyv-test-in-app, namespace: $NS}
spec:
  policyRefs: [{name: app-image-registry, kind: ValidatingPolicy}]
  matchConditions: [{name: all, expression: "true"}]
EOF
sleep 3
expect_denied k "Pod from docker.io with a match-all exception in $NS" app-image-registry "come from localhost:5001/" \
  "$(pod kyv-test-public "$CURL")"
k -n $NS delete policyexception.policies.kyverno.io kyv-test-in-app >/dev/null

# --- Pod Security on namespaces ---------------------------------------------------------------
k create ns "$TEST_NS" >/dev/null
enforce=$(k get ns "$TEST_NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}:{.metadata.labels.pod-security\.kubernetes\.io/enforce-version}')
[[ $enforce == restricted:v1.37 ]] && pass "new namespace labelled enforce=restricted, v1.37 (mutate)" || fail "new namespace enforce '$enforce'"
# PSA now applies in it: a privileged pod is rejected.
out=$(k -n "$TEST_NS" run kyv-priv --image="$IMAGE" --restart=Never --dry-run=server \
  --overrides='{"spec":{"containers":[{"name":"kyv-priv","image":"'"$IMAGE"'","securityContext":{"privileged":true}}]}}' 2>&1)
grep -q 'violates PodSecurity "restricted' <<<"$out" && pass "privileged pod in the new namespace rejected by PSA" || fail "privileged pod in new namespace: $out"

ns_manifest() { printf 'apiVersion: v1\nkind: Namespace\nmetadata: {name: kyv-test-%s, labels: {%s}}\n' "$1" "$2"; }
expect_denied k "namespace created with enforce=privileged" namespace-pod-security 'got "privileged"' \
  "$(ns_manifest priv "pod-security.kubernetes.io/enforce: privileged")"
expect_denied k "namespace created with enforce-version v1.20" namespace-pod-security "enforce-version" \
  "$(ns_manifest oldver "pod-security.kubernetes.io/enforce: restricted, pod-security.kubernetes.io/enforce-version: v1.20")"
# Updates are checked too, so an existing namespace can't be weakened.
for change in "pod-security.kubernetes.io/enforce=baseline --overwrite" "pod-security.kubernetes.io/enforce-"; do
  # shellcheck disable=SC2086
  if out=$(k label ns "$TEST_NS" $change 2>&1); then
    fail "label $change on an existing namespace: admitted"
  elif grep -q "Policy namespace-pod-security failed" <<<"$out"; then
    pass "label $change on an existing namespace: rejected"
  else
    fail "label $change: rejected, but not by namespace-pod-security: $out"
  fi
done

# --- Default-deny generated in new namespaces ---------------------------------------------------
has_deny() { [[ $(k -n "$TEST_NS" get networkpolicy default-deny-all -o jsonpath='{.spec.policyTypes}' 2>/dev/null) == '["Ingress","Egress"]' ]]; }
wait_for 20 has_deny && pass "new namespace has default-deny-all (ingress and egress)" || fail "no default-deny-all in $TEST_NS"
# Any update to the namespace once deleted the generated policy; see namespace-default-deny.yaml.
k label ns "$TEST_NS" team=kyv-test >/dev/null; sleep 5
has_deny && pass "default-deny-all kept after the namespace is updated" || fail "default-deny-all gone after a namespace update"
k -n "$TEST_NS" delete networkpolicy default-deny-all >/dev/null
wait_for 20 has_deny && pass "default-deny-all recreated after deletion" || fail "default-deny-all not recreated after deletion"
k -n "$TEST_NS" patch networkpolicy default-deny-all --type=json -p '[{"op":"replace","path":"/spec/policyTypes","value":["Ingress"]}]' >/dev/null
sleep 2
wait_for 20 has_deny && pass "default-deny-all restored after egress was removed from it" || fail "default-deny-all left without egress"
# Platform namespaces with their own policies are exempt (exception platform-network).
for ns in $NS client; do
  gen=$(k -n $ns get networkpolicy -l generate.kyverno.io/policy-name=namespace-default-deny -o name 2>/dev/null)
  [[ -z $gen ]] && pass "no generated policy in $ns (exception)" || fail "generated policy in $ns: $gen"
done

# --- Policy reports -----------------------------------------------------------------------
app_pass() {
  k -n $NS get policyreports.wgpolicyk8s.io -o json | python3 -c '
import json, sys
r = json.load(sys.stdin)["items"]
ok = [x for x in r if x.get("scope", {}).get("kind") == "Deployment" and x["scope"].get("name") == "app"
      and any(res.get("policy") == "app-image-registry" and res.get("result") == "pass" for res in x.get("results", []))]
sys.exit(0 if ok else 1)'
}
wait_for 90 app_pass && pass "PolicyReport: Deployment app passes app-image-registry" || fail "no passing PolicyReport for Deployment app"

# --- Fail closed ----------------------------------------------------------------------------
# The Service in front of Kyverno's webhook selects no pods, so the API server can't reach it.
sel=$(k -n $KNS get svc kyverno-svc -o jsonpath='{.spec.selector}')
[[ $sel == "$SVC_SELECTOR" ]] || { fail "kyverno-svc selector is '$sel', not the one this test restores"; exit 1; }
k -n $KNS patch svc kyverno-svc --type=json -p '[{"op":"replace","path":"/spec/selector","value":{"kyv-test":"no-such-pod"}}]' >/dev/null
no_endpoints() { [[ -z $(k -n $KNS get endpointslices -l kubernetes.io/service-name=kyverno-svc -o jsonpath='{.items[*].endpoints[*].addresses}') ]]; }
wait_for 30 no_endpoints || fail "kyverno-svc still has endpoints"
# Replicas stay at 1, so Kyverno keeps its webhooks registered (it removes them only when
# scaled to 0 or deleted); the new pod is unreachable through the Service.
k -n $KNS delete pods -l app.kubernetes.io/component=admission-controller --wait=true >/dev/null
webhooks_kept() { k get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg; }
webhooks_kept >/dev/null 2>&1 && pass "Kyverno's webhooks still registered while it is unreachable" || fail "Kyverno's webhooks were removed"
if out=$(d create --dry-run=server -f - <<<"$(deployment down "$IMAGE")" 2>&1); then
  fail "with Kyverno unreachable, a Deployment in $NS was admitted unchecked"
elif grep -q "failed calling webhook" <<<"$out"; then
  pass "with Kyverno unreachable, a Deployment in $NS is rejected (fail closed)"
  echo "      ${out##*: failed calling webhook}"
else
  fail "with Kyverno unreachable: unexpected error: $out"
fi
if out=$(k create ns "kyv-test-down-$RUN" --dry-run=server 2>&1); then
  fail "with Kyverno unreachable, a namespace was created without its Pod Security labels"
else
  pass "with Kyverno unreachable, namespace creation is rejected"
fi
if out=$(k -n kube-system create configmap kyv-test-$RUN --dry-run=server 2>&1); then
  pass "with Kyverno unreachable, kube-system still admits requests"
else
  fail "with Kyverno unreachable, kube-system rejected a request: $out"
fi
restore_svc
k -n $KNS rollout status deploy kyverno-admission-controller --timeout=180s >/dev/null || fail "admission controller not ready"
# Back means enforcing again, not just reachable.
policy_back() { ! d create --dry-run=server -f - <<<"$(deployment public "$CURL")" >/dev/null 2>&1 && \
  d create --dry-run=server -f - <<<"$(deployment local "$IMAGE")" >/dev/null 2>&1; }
wait_for 60 policy_back && pass "after recovery, app-image-registry enforces again" || fail "app-image-registry not enforcing after recovery"

# Scaling Kyverno to 0 or deleting it removes its webhooks, by design. Only the platform can.
for verb in "patch deployments" "update deployments/scale" "delete deployments" "patch services"; do
  got=$(d auth can-i ${verb%% *} ${verb#* } -n $KNS 2>/dev/null)
  [[ $got == no ]] && pass "deployer can-i $verb in $KNS: no" || fail "deployer can-i $verb in $KNS: '$got'"
done
for r in validatingwebhookconfigurations mutatingwebhookconfigurations; do
  got=$(d auth can-i delete $r.admissionregistration.k8s.io 2>/dev/null)
  [[ $got == no ]] && pass "deployer can-i delete $r: no" || fail "deployer can-i delete $r: '$got'"
done

exit $FAILED
