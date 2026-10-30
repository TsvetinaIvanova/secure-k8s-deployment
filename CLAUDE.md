# Secure Kubernetes Deployment

Portfolio project: a trivial Flask service on a local kind cluster, with the depth in the platform (PSA, NetworkPolicy, Kyverno, RBAC, CI security gates, air-gap, Vault). Everything must be defensible in a review without notes. Be direct, flag tradeoffs honestly, push back if something doesn't fit.

## Working rules

- Work one phase at a time (roadmap in README.md). At the end of a phase, run its verification commands, show the real output, update the README (quickstart, Security Controls rows, roadmap status), and stop for review.
- Pin every version (kind, node image, CNI, Kyverno chart, Helm, GitHub Actions, Trivy, base images). Look up the current stable release; never guess versions from memory.
- Pin images by digest (`repo:tag@sha256:...`).
- Every security control gets a test proving it is enforced (the bad request is rejected), with PASS/FAIL output.
- Explain the root cause or reasoning before changing code; keep fixes targeted.
- Non-obvious decisions get an ADR in `docs/adr/` (template `0000-template.md`), under a page each.
- Every routine action is a `make` target.
- Docs describe the project on its own merits (platform security, regulated and disconnected environments).
- Never commit secrets, kubeconfigs or tokens.

## Conventions

- CI: `actions/checkout@v6`, `actions/setup-python@v6`, tests run with `python -m pytest`. Least-privilege `permissions:` (`contents: read` by default). Actions pinned.
- Small PRs; CI must pass before merge. Commit or push only when asked.
