# 0003: Local registry from the start, not `kind load`

- **Status:** accepted
- **Date:** 2026-10-26

## Context

Every image is referenced as `repo:tag@sha256:digest`. A digest names a manifest that a registry serves. `kind load docker-image` copies an image straight into each node's containerd with no registry involved, so it is not clear the node can match a `@sha256:` reference against it. The usual workaround is a tag-only reference with `imagePullPolicy: Never`, which breaks the digest rule for the one image this repo builds itself. An air-gapped setup (Phase 8) needs a local registry anyway.

## Decision

Run a registry container (`registry:3.1.2`, pinned by digest) from Phase 2 on, set up by `cluster/registry.sh` during `make up`:

- On the host it listens on `127.0.0.1:5001` only. `make load` pushes there and asks the registry for the digest.
- It is attached to the `kind` Docker network as `kind-registry`.
- containerd on each node gets `config_path = /etc/containerd/certs.d` (patched in `kind-config.yaml`, since the node image leaves it empty) and a `hosts.toml` that maps `localhost:5001` to `http://kind-registry:5000`. Inside a node, `localhost` is the node itself.

The chart (Phase 2) gets the digest at deploy time, not from a committed value. Builds are not byte-for-byte identical: the image manifest is stable across rebuilds, but BuildKit's provenance attestation records build metadata, so the top-level index digest changes with every build.

## Alternatives considered

- **`kind load` with tag only and `imagePullPolicy: Never`:** simplest, but the pod spec can't say which bytes it runs. Kyverno's digest/tag policy would need an exception for our own app.
- **Disable provenance (`--provenance=false`) for a stable index digest:** a stable digest is convenient, but it drops supply-chain evidence that the image-signing stretch goal (S1) builds on.

## Consequences

- Verified: a pod pulls `localhost:5001/secure-k8s-app:0.1.0@sha256:…` by digest, and the same tag with a wrong digest fails with `ErrImagePull`/`NotFound`. The tag never overrides the digest.
- The registry is plain HTTP without authentication. That is acceptable only because it is bound to loopback on the host and otherwise reachable only from the kind network. A real mirror would have TLS, authentication, and push rights limited to the promotion pipeline (see Phase 8 notes).
- Phase 8 reuses this mechanism: more `hosts.toml` files point public registry names at the mirror.
- The registry's storage is ephemeral. `make down` deletes it, and `make load` refills it.
