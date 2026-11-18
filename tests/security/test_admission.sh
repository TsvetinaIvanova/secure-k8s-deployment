#!/usr/bin/env bash
# Phase 6a: built-in admission policies (ValidatingAdmissionPolicy) in namespace app (ADR 0010).
# Workloads: read-only root filesystem, CPU and memory limits, image pinned by digest.
# Services: ClusterIP only, no externalIPs.
#
# Each bad object is the compliant one with exactly one field broken, and the compliant one
# must be admitted, so a rejection can only come from that field. Rejections must name the
# policy and the rule. --dry-run=server runs the full admission chain but stores nothing.
# Deployments and Services are sent with the deployer's token (the identity the Service rule
# exists for, ADR 0009); Pods and CronJobs as admin, which the deployer can't create, and
# which shows cluster-admin isn't exempt either.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
echo "== test_admission: namespace $NS"

DKC=$(mktemp)
trap 'rm -f "$DKC" "$DKC.tmp"' EXIT
"$(dirname "$0")/../../cluster/deployer-kubeconfig.sh" "$KUBECTL" "$DKC" >/dev/null || { fail "could not get a deployer token"; exit 1; }
d() { KUBECONFIG=$DKC "$KUBECTL" "$@"; }

# The policies are in place, compiled cleanly and deny (rather than only warn or audit).
for p in app-workloads app-services; do
  actions=$(k get validatingadmissionpolicybinding $p -o jsonpath='{.spec.validationActions}' 2>/dev/null)
  warnings=$(k get validatingadmissionpolicy $p -o jsonpath='{.status.typeChecking.expressionWarnings}' 2>/dev/null)
  if [[ $actions == '["Deny"]' && -z $warnings ]] && k get validatingadmissionpolicy $p >/dev/null 2>&1; then
    pass "policy $p: bound with Deny, no type-checking warnings"
  else
    fail "policy $p: validationActions '$actions', warnings '$warnings'"
  fi
done

# The platform owns the policies: the deployer can't remove or weaken them.
for verb in delete patch; do
  for r in validatingadmissionpolicies validatingadmissionpolicybindings; do
    got=$(d auth can-i $verb $r.admissionregistration.k8s.io 2>/dev/null)
    [[ $got == no ]] && pass "deployer can-i $verb $r: no" || fail "deployer can-i $verb $r: '$got', want no"
  done
done

# What is deployed passes, re-sent as an update: the policies don't break the running app.
for obj in deployment/app service/app; do
  if out=$(k -n $NS get $obj -o json | d replace --dry-run=server -f - 2>&1); then
    pass "deployed $obj admitted as an update"
  else
    fail "deployed $obj rejected: $out"
  fi
done

# The app's own image (pinned by digest), so only the field under test can differ.
IMAGE=$(k -n $NS get deploy app -o jsonpath='{.spec.template.spec.containers[0].image}')
POD_SC='{runAsNonRoot: true, runAsUser: 65532, seccompProfile: {type: RuntimeDefault}}'
CTR_SC='{allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: true}'
LIMITS='{requests: {cpu: 10m, memory: 16Mi}, limits: {cpu: 50m, memory: 32Mi}}'

# Usage: ctr <name> [image] [container securityContext] [resources]
ctr() { echo "{name: $1, image: ${2:-$IMAGE}, securityContext: ${3:-$CTR_SC}, resources: ${4:-$LIMITS}}"; }
# Usage: podspec <containers> [init containers] [extra pod spec fields, e.g. "restartPolicy: Never"]
podspec() { echo "{automountServiceAccountToken: false, securityContext: $POD_SC, containers: [$1], initContainers: [${2:-}]${3:+, $3}}"; }

# Usage: deployment <name> <podspec>
deployment() {
  cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: vap-test-$1, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {vap-test: $1}}
  template:
    metadata: {labels: {vap-test: $1}}
    spec: $2
EOF
}
# Usage: pod <name> <podspec>
pod() { printf 'apiVersion: v1\nkind: Pod\nmetadata: {name: vap-test-%s, namespace: %s}\nspec: %s\n' "$1" "$NS" "$2"; }
# Usage: cronjob <name> <podspec>
cronjob() {
  cat <<EOF
apiVersion: batch/v1
kind: CronJob
metadata: {name: vap-test-$1, namespace: $NS}
spec:
  schedule: "0 0 1 1 *"
  jobTemplate: {spec: {template: {spec: $2}}}
EOF
}
# Usage: service <name> <spec fields>
service() {
  printf 'apiVersion: v1\nkind: Service\nmetadata: {name: vap-test-%s, namespace: %s}\nspec: {selector: {vap-test: x}, ports: [{port: 80, targetPort: 8080}], %s}\n' "$1" "$NS" "$2"
}

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
  elif grep -q "ValidatingAdmissionPolicy '$3'" <<<"$out" && grep -qF "$4" <<<"$out"; then
    pass "$2: rejected"
    echo "      ${out#*denied request: }"
  else
    fail "$2: rejected, but not by $3 ($4): $out"
  fi
}

# Workloads. Deployments are rejected themselves, not only the pods they would create.
expect_admitted d "compliant Deployment" "$(deployment ok "$(podspec "$(ctr app)")")"
expect_denied d "Deployment without readOnlyRootFilesystem" app-workloads readOnlyRootFilesystem \
  "$(deployment rw "$(podspec "$(ctr app "" '{allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}')")")"
expect_denied d "Deployment with a writable init container" app-workloads "container(s): init" \
  "$(deployment rw-init "$(podspec "$(ctr app)" "$(ctr init "" '{allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}, readOnlyRootFilesystem: false}')")")"
expect_denied d "Deployment without a memory limit" app-workloads resources.limits \
  "$(deployment nolimit "$(podspec "$(ctr app "" "" '{limits: {cpu: 50m}}')")")"
expect_denied d "Deployment with an image by tag only" app-workloads "pinned by digest" \
  "$(deployment tag "$(podspec "$(ctr app "${IMAGE%@*}")")")"

# Bare pods and other workload kinds are covered too.
expect_admitted k "compliant Pod (as admin)" "$(pod ok "$(podspec "$(ctr app)")")"
expect_denied k "Pod without readOnlyRootFilesystem (as admin)" app-workloads readOnlyRootFilesystem \
  "$(pod rw "$(podspec "$(ctr app "" '{allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}')")")"
# A Job's pods must set restartPolicy; API validation rejects the CronJob without it.
expect_admitted k "compliant CronJob (as admin)" "$(cronjob ok "$(podspec "$(ctr app)" "" "restartPolicy: Never")")"
expect_denied k "CronJob with an image by tag only (as admin)" app-workloads "pinned by digest" \
  "$(cronjob tag "$(podspec "$(ctr app "${IMAGE%@*}")" "" "restartPolicy: Never")")"

# Services: the deployer's Service rights can't expose the app or capture other traffic.
expect_admitted d "ClusterIP Service" "$(service ok "type: ClusterIP")"
expect_denied d "NodePort Service" app-services "must be ClusterIP" "$(service np "type: NodePort")"
expect_denied d "LoadBalancer Service" app-services "must be ClusterIP" "$(service lb "type: LoadBalancer")"
expect_denied d "ExternalName Service" app-services "must be ClusterIP" \
  "$(printf 'apiVersion: v1\nkind: Service\nmetadata: {name: vap-test-en, namespace: %s}\nspec: {type: ExternalName, externalName: example.com}\n' "$NS")"
expect_denied d "ClusterIP Service with externalIPs (CVE-2020-8554)" app-services externalIPs \
  "$(service eip "type: ClusterIP, externalIPs: [203.0.113.10]")"

exit $FAILED
