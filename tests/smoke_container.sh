#!/usr/bin/env bash
# Run the app image with the same restrictions the Kubernetes pod spec will apply,
# and check that it still serves. Usage: smoke_container.sh <image> <uid>
set -euo pipefail

IMAGE=${1:?image}
APP_UID=${2:?uid}
PORT=18080
NAME=smoke-$$
FAILED=0

secret_dir=$(mktemp -d)
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$secret_dir"; }
trap cleanup EXIT

printf 'smoke-secret' >"$secret_dir/token"
chmod 755 "$secret_dir" && chmod 644 "$secret_dir/token"

#   --read-only        readOnlyRootFilesystem: true
#   --tmpfs /tmp       the emptyDir at /tmp
#   --user             runAsUser / runAsGroup
#   --cap-drop ALL     capabilities.drop: ["ALL"]
#   no-new-privileges  allowPrivilegeEscalation: false
#   -v ...:ro          the Secret mounted as a read-only file
docker run -d --name "$NAME" \
  --read-only --tmpfs /tmp \
  --user "$APP_UID:$APP_UID" \
  --cap-drop ALL --security-opt no-new-privileges \
  -e APP_GREETING=smoke \
  -e APP_SECRET_FILE=/etc/app/secret/token \
  -v "$secret_dir:/etc/app/secret:ro" \
  -p "127.0.0.1:$PORT:8080" \
  "$IMAGE" >/dev/null

check() {
  local desc=$1; shift
  if "$@" >/dev/null 2>&1; then echo "PASS  $desc"; else echo "FAIL  $desc"; FAILED=1; fi
}

for _ in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null && break
  sleep 0.5
done

check "/healthz returns 200"                curl -sf "http://127.0.0.1:$PORT/healthz"
check "/readyz returns 200 (secret mounted)" curl -sf "http://127.0.0.1:$PORT/readyz"
check "/ serves the config value"           bash -c "curl -sf http://127.0.0.1:$PORT/ | grep -q '\"message\":\"smoke\"'"
check "/ does not leak the secret"          bash -c "! curl -sf http://127.0.0.1:$PORT/ | grep -q smoke-secret"
check "processes run as UID $APP_UID"       bash -c "docker top $NAME -o uid | tail -n +2 | grep -qvx $APP_UID && exit 1 || exit 0"
check "image has no shell"                  bash -c "! docker exec $NAME /bin/sh -c true"
# Catches startup problems that don't break serving, e.g. a write blocked by --read-only.
check "no ERROR lines in container log"     bash -c "! docker logs $NAME 2>&1 | grep -q '\[ERROR\]'"

echo "--- container log"
docker logs "$NAME" 2>&1 | tail -n 8
exit "$FAILED"
