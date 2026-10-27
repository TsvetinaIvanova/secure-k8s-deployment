# Shared helpers for tests/security/test_*.sh. Source it; don't run it.
# Requires KUBECONFIG and KUBECTL in the environment (set by make test-security).

FAILED=0
pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILED=1; }
k() { "$KUBECTL" "$@"; }

# Port-forward svc/<name> in <ns> to a local port and wait until it answers.
# Usage: port_forward <ns> <svc> <local port>; stopped automatically on exit.
port_forward() {
  k -n "$1" port-forward "svc/$2" "$3:80" >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null' EXIT
  for _ in $(seq 1 20); do curl -sf "localhost:$3/healthz" >/dev/null && return 0; sleep 0.5; done
  return 1
}
