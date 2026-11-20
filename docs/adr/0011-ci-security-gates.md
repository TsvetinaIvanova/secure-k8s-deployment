# 0011: CI security gates: pinned scanners run by make, fail on findings, exceptions that expire

- **Status:** accepted
- **Date:** 2026-11-20

## Context

CI needs gates for secrets, code, dependencies, the image and the manifests. Scanners run with the CI token and the source tree, so they are supply-chain targets themselves. In March 2026 the release tags of `aquasecurity/trivy-action` and `setup-trivy` were force-pushed to credential-stealing code ([GHSA-69fq-xp46-6x23](https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23)). A gate also only works if people trust it: one that fails on noise gets bypassed, and one that has silently stopped failing looks the same as a clean repo.

## Decision

- **Tools:** gitleaks (full git history), Bandit (app source), pip-audit (pinned runtime requirements), Trivy (image vulnerabilities and secrets, CycloneDX SBOM, misconfigurations in the rendered chart, `platform/` and the Dockerfile).
- **Installation:** gitleaks and Trivy are downloaded by `make` at pinned versions and checked against SHA-256 hashes in the Makefile, like kind, kubectl and Helm. Bandit and pip-audit install from `tools/scan-requirements.txt` with `--require-hashes`. No scanner actions: CI runs the same `make` targets as a laptop. Before pinning, the release was checked against its published checksums and Trivy's Sigstore certificate (issued to `aquasecurity/trivy`'s release workflow for that tag).
- **Thresholds:** Bandit, pip-audit, gitleaks and the IaC scan fail on any finding. The image scan fails on HIGH or CRITICAL vulnerabilities that have a fixed version (`--ignore-unfixed`), and on embedded secrets.
- **Exceptions:** Bandit uses `# nosec <id>` with a reason on the line. Trivy uses `tools/trivy/trivyignore.yaml`: each entry is scoped to one file, gives a reason and the control that covers the risk, and has an `expired_at` date, after which the gate fails again.
- **Pre-commit hook:** `tools/hooks/pre-commit` runs gitleaks on staged changes through the same pinned binary, installed per clone with `make hooks` (`core.hooksPath`). Git can't force a hook on a clone and `--no-verify` skips it, so it is a convenience that keeps secrets out of local history; the CI history scan is the control.
- **Gate tests:** `make test-gates` runs each gate against planted bad input (expecting the specific rule ID) and against this repo, and shows that every Trivy exception fails again once expired. It runs in CI.

## Alternatives considered

- **`aquasecurity/trivy-action` pinned by SHA:** a SHA pin would have been safe in March 2026 too. It still adds an action and its own download logic to the trust chain, and a laptop can't run it. A hash in the repo covers the one binary we use.
- **Fail on every CVE, including unfixed ones:** the distroless base has around 90 HIGH CVEs with no Debian fix. There is nothing to act on, so the gate would be red permanently and people would learn to ignore it.
- **Upload SARIF to GitHub code scanning:** needs `security-events: write`. CI logs and the SBOM artifact are enough for now.
- **Semgrep for SAST:** better for multiple languages and custom rules, but this codebase is Python only. Its default `--config auto` fetches rules from a registry, and those rules are not open source.

## Consequences

- The first image scan failed: the pinned distroless digest predated Debian's zlib fix (CVE-2026-85091). It was re-pinned, not ignored. Expect this whenever Debian ships a fix; the remedy is a digest bump.
- A hash pin does not help if the pinned release was malicious to begin with. That risk is reduced by checking provenance before pinning and by not taking a release in its first days.
- Trivy's vulnerability DB and pip-audit's advisory lookups need the internet. That breaks in an air gap; Phase 8 has to mirror the DB.
- Unfixed CVEs are visible in a full scan but don't block a merge. Re-scanning on a schedule is not set up.
