# 0012: In-cluster add-ons before the air-gap; air-gap becomes a stretch goal

- **Status:** accepted
- **Date:** 2026-11-26
- **Supersedes:** [0008](0008-native-controls-first.md)

## Context

ADR 0008 made the native controls the core roadmap and moved the phases that install software into the cluster to stretch goals. Phases 3, 4, 6, 6a and 7 now cover admission, network, identity and CI with what a clean cluster provides. The only native phase left is 8, the air-gap.

ADR 0008 lists gaps that native controls can't close: no default-deny policy is generated for new namespaces, there are no signature checks on images and no policy reports, the app Secret has no rotation, and nothing aggregates security logs. Each one needs an add-on.

## Decision

Build the add-on phases next, in this order: 5 (Kyverno), 11 (observability with Loki and Grafana), 10 (Vault), S1 (cosign and `verifyImages`), then 9 (documentation and diagrams), so the documentation covers the finished platform. Phase 8 (air-gap) becomes a stretch goal.

Phase numbers stay as they are. They are identifiers, not an order. Accepted ADRs, code comments and CI refer to them by number.

## Alternatives considered

- **Renumber the phases to match the new order:** the numbers appear in about 40 places, including accepted ADRs, which are records and aren't rewritten. Two numbering schemes would mean readers can't tell which one a reference uses.
- **Keep ADR 0008's order (air-gap first):** it would mirror only the app, kind and test images. Done last, the air-gap also has to bring in Kyverno, Loki, Grafana and Vault, which is a more realistic image set to cut off.
- **Close the gaps with more ValidatingAdmissionPolicy:** that policy type only validates. It can't generate objects, verify signatures or produce reports.

## Consequences

- The cluster depends on components it doesn't ship with. Kyverno's webhook becomes part of the admission path, so Phase 5 has to choose a failure mode and test it.
- Add-on images come from public registries. Like every third-party image, they are pinned by digest and listed in `images.txt` (`make images`), which is the list a later air-gap phase mirrors.
- No admission rule restricts which registry an image comes from (ADR 0010 deferred that to Phase 8). In CI, Trivy's KSV-0125 check accepts only `localhost:5001` in the rendered chart. On the cluster, digest pinning fixes an image's bytes but not its origin. Once S1 is built, the app image also has to carry a valid signature.
- What already points toward disconnected environments stays: the local registry, digest pins, the image inventory and no pod egress in `app`. The mirror step and cutting the nodes off from the internet are deferred.
- Accepted ADRs that mention Phase 8 describe what that phase does if it's built. They aren't a commitment to build it.
