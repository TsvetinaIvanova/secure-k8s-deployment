#!/usr/bin/env bash
# Local image registry for the kind cluster (the pattern from kind's docs).
# Idempotent: safe to re-run after `make up`.
#
#   host:  docker push localhost:5001/...      -> registry container, port bound to 127.0.0.1 only
#   nodes: pull localhost:5001/... -> hosts.toml redirects to http://kind-registry:5000 on the kind network
#
# Usage: registry.sh <kind binary> <cluster name>
set -euo pipefail

KIND=${1:?kind binary}
CLUSTER=${2:?cluster name}
REG_NAME=kind-registry
REG_PORT=5001
REG_IMAGE=registry:3.1.2@sha256:01cd312e67026f06f5d89c3e133a4a9adc7cb9eeb9b1194e0b2954dfd770efd2

# 1. Registry container. Plain HTTP and no auth, so the port is bound to loopback:
#    nothing outside this machine can push or pull.
if [ "$(docker inspect -f '{{.State.Running}}' "$REG_NAME" 2>/dev/null)" != "true" ]; then
  docker rm -f "$REG_NAME" >/dev/null 2>&1 || true
  docker run -d --restart=always --name "$REG_NAME" \
    -p "127.0.0.1:$REG_PORT:5000" "$REG_IMAGE" >/dev/null
  echo "started $REG_NAME on 127.0.0.1:$REG_PORT"
fi

# 2. Attach it to the kind network, so nodes can reach it by name.
if [ "$(docker inspect -f '{{json .NetworkSettings.Networks.kind}}' "$REG_NAME")" = "null" ]; then
  docker network connect kind "$REG_NAME"
fi

# 3. Tell each node's containerd where "localhost:5001" really is. Inside a node,
#    localhost is the node itself, so without this the pull would fail.
#    Phase 8 adds more hosts.toml files here to point public registries at the mirror.
reg_dir="/etc/containerd/certs.d/localhost:$REG_PORT"
for node in $("$KIND" get nodes --name "$CLUSTER"); do
  docker exec "$node" mkdir -p "$reg_dir"
  printf '[host."http://%s:5000"]\n' "$REG_NAME" | docker exec -i "$node" cp /dev/stdin "$reg_dir/hosts.toml"
done
echo "registry localhost:$REG_PORT configured on nodes of $CLUSTER"
