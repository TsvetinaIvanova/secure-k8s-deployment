SHELL := /bin/bash
.DEFAULT_GOAL := help

CLUSTER_NAME ?= secure-k8s
# Fixed, not a setting: platform/ manifests name this namespace (ADR 0006). `override`
# because a plain assignment still loses to `make deploy NAMESPACE=...` on the command line.
override NAMESPACE := app
VENV         ?= .venv
PYTHON       := $(VENV)/bin/python
IMAGE        ?= secure-k8s-app
IMAGE_TAG    ?= 0.1.0
APP_UID      := 65532
REGISTRY     ?= localhost:5001
IMAGE_REF    := $(REGISTRY)/$(IMAGE):$(IMAGE_TAG)
# Asks the registry for the digest of what was actually pushed. Use it as $$($(IMAGE_DIGEST_CMD))
# inside a recipe, so the shell runs it at that line. A make variable would be expanded
# before the recipe's first line runs, i.e. before the push.
IMAGE_DIGEST_CMD := docker buildx imagetools inspect $(IMAGE_REF) --format '{{.Manifest.Digest}}'

# The cluster's kubeconfig lives in the repo (gitignored), never in ~/.kube/config,
# so make targets and test scripts can't act on whatever cluster is the current context.
export KUBECONFIG := $(CURDIR)/.kube/config
# Helm runs as the deployer ServiceAccount, with a 10-minute token written here by
# `make deploy` and deleted when Helm exits (ADR 0009). The admin kubeconfig above is for the
# cluster, platform and tests.
DEPLOYER_KUBECONFIG := $(CURDIR)/.kube/deployer
# Helm's release record goes into ConfigMaps, so the deployer needs no access to Secrets (ADR 0009).
export HELM_DRIVER := configmap

# Pinned CLI tools, downloaded into ./bin and checked against these hashes.
# The hashes are pinned here rather than fetched next to the binary: a checksum served
# from the same place as the binary only detects corruption, not tampering.
# Only linux/amd64 hashes are recorded.
BIN             := $(CURDIR)/bin
KIND_VERSION    := v0.33.0
KIND_SHA256     := aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d
KUBECTL_VERSION := v1.37.1
KUBECTL_SHA256  := 65691ff77eb6fa44c908b77a1082c9f092c3b9733b5cefabec0d1104890e21a8
HELM_VERSION    := v4.3.1
HELM_SHA256     := 0403a88ae20913d11b10a2467b50087721fea7581736da6b9d3992f5357fe54b
GITLEAKS_VERSION := v8.30.1
GITLEAKS_SHA256  := 551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
# Downloaded and hash-checked here, not through aquasecurity/trivy-action (ADR 0011).
TRIVY_VERSION    := v0.76.2
TRIVY_SHA256     := bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf
# Versioned file names: bumping a version makes make download the new binary.
KIND    := $(BIN)/kind-$(KIND_VERSION)
KUBECTL := $(BIN)/kubectl-$(KUBECTL_VERSION)
HELM    := $(BIN)/helm-$(HELM_VERSION)
GITLEAKS := $(BIN)/gitleaks-$(GITLEAKS_VERSION)
TRIVY    := $(BIN)/trivy-$(TRIVY_VERSION)

# Targets not implemented yet fail loudly instead of pretending to succeed.
define todo
	@echo "make $@: not implemented yet ($(1))" >&2; exit 1
endef

.PHONY: help
help: ## List all targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: tools
tools: $(KIND) $(KUBECTL) $(HELM) ## Download pinned kind, kubectl and helm into ./bin (checksum-verified)
	@# Unversioned links, so `kubectl` etc. resolve to the pinned binaries once ./bin is on PATH.
	@cd $(BIN) && ln -sf $(notdir $(KIND)) kind && ln -sf $(notdir $(KUBECTL)) kubectl && ln -sf $(notdir $(HELM)) helm

$(BIN)/.platform-ok:
	@[ "$$(uname -sm)" = "Linux x86_64" ] || { echo "pinned tool hashes are for linux/amd64 only" >&2; exit 1; }
	@mkdir -p $(BIN) && touch $@

$(KIND): $(BIN)/.platform-ok
	curl -fsSLo $@.tmp https://github.com/kubernetes-sigs/kind/releases/download/$(KIND_VERSION)/kind-linux-amd64
	echo "$(KIND_SHA256)  $@.tmp" | sha256sum -c --quiet
	chmod +x $@.tmp && mv $@.tmp $@

$(KUBECTL): $(BIN)/.platform-ok
	curl -fsSLo $@.tmp https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/linux/amd64/kubectl
	echo "$(KUBECTL_SHA256)  $@.tmp" | sha256sum -c --quiet
	chmod +x $@.tmp && mv $@.tmp $@

$(HELM): $(BIN)/.platform-ok
	curl -fsSLo $@.tgz.tmp https://get.helm.sh/helm-$(HELM_VERSION)-linux-amd64.tar.gz
	echo "$(HELM_SHA256)  $@.tgz.tmp" | sha256sum -c --quiet
	tar -xzOf $@.tgz.tmp linux-amd64/helm >$@.tmp && rm $@.tgz.tmp
	chmod +x $@.tmp && mv $@.tmp $@

$(GITLEAKS): $(BIN)/.platform-ok
	curl -fsSLo $@.tgz.tmp https://github.com/gitleaks/gitleaks/releases/download/$(GITLEAKS_VERSION)/gitleaks_$(GITLEAKS_VERSION:v%=%)_linux_x64.tar.gz
	echo "$(GITLEAKS_SHA256)  $@.tgz.tmp" | sha256sum -c --quiet
	tar -xzOf $@.tgz.tmp gitleaks >$@.tmp && rm $@.tgz.tmp
	chmod +x $@.tmp && mv $@.tmp $@

$(TRIVY): $(BIN)/.platform-ok
	curl -fsSLo $@.tgz.tmp https://github.com/aquasecurity/trivy/releases/download/$(TRIVY_VERSION)/trivy_$(TRIVY_VERSION:v%=%)_Linux-64bit.tar.gz
	echo "$(TRIVY_SHA256)  $@.tgz.tmp" | sha256sum -c --quiet
	tar -xzOf $@.tgz.tmp trivy >$@.tmp && rm $@.tgz.tmp
	chmod +x $@.tmp && mv $@.tmp $@

.PHONY: up
up: $(KIND) $(KUBECTL) ## Create the local kind cluster (1 control plane, 2 workers) and local registry
	@if $(KIND) get clusters | grep -qx $(CLUSTER_NAME); then \
		echo "cluster $(CLUSTER_NAME) already exists"; \
	else \
		$(KIND) create cluster --name $(CLUSTER_NAME) --config cluster/kind-config.yaml --wait 120s; \
	fi
	./cluster/registry.sh $(KIND) $(CLUSTER_NAME)
	@# kind's --wait only covers the control plane; workers can still be NotReady here.
	$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=120s
	$(KUBECTL) get nodes -o wide

.PHONY: down
down: $(KIND) ## Delete the local kind cluster and local registry
	$(KIND) delete cluster --name $(CLUSTER_NAME)
	docker rm -f kind-registry >/dev/null 2>&1 || true
	rm -f $(KUBECONFIG) $(DEPLOYER_KUBECONFIG)

.PHONY: kubeconfig
kubeconfig: tools ## Print the export line for kubectl and helm by hand; use: eval "$$(make -s kubeconfig)"
	@# HELM_DRIVER too: without it, helm by hand reads the Secret driver and finds no release.
	@echo "export KUBECONFIG=$(KUBECONFIG) HELM_DRIVER=$(HELM_DRIVER) PATH=$(BIN):\$$PATH"

.PHONY: build
build: ## Build the app container image
	docker build -t $(IMAGE):$(IMAGE_TAG) app

.PHONY: smoke
smoke: build ## Run the image as Kubernetes will (read-only, non-root, no caps) and curl it
	./tests/smoke_container.sh $(IMAGE):$(IMAGE_TAG) $(APP_UID)

.PHONY: load
load: build ## Build the image and push it to the local registry; prints the pinned reference
	docker tag $(IMAGE):$(IMAGE_TAG) $(IMAGE_REF)
	docker push -q $(IMAGE_REF)
	@echo "pinned: $(IMAGE_REF)@$$($(IMAGE_DIGEST_CMD))"

.PHONY: platform
platform: $(KUBECTL) ## Apply platform resources as admin: namespaces (Pod Security labels), admission policies, network policies, deployer RBAC, app Secret
	$(KUBECTL) apply -f platform/namespaces.yaml
	@# Before anything is deployed: the policies only check objects created or updated after them (ADR 0010).
	$(KUBECTL) apply -f platform/admission/
	$(KUBECTL) apply -f platform/networkpolicies/
	$(KUBECTL) apply -f platform/rbac/
	@# The Secret lives outside the chart (ADR 0005), and the deployer can't touch Secrets
	@# (ADR 0009), so the platform creates it. Once, with a random value piped through stdin
	@# so it never appears in process arguments, the shell history or a file. `create` (not
	@# `apply`) also avoids the last-applied-configuration annotation, which would store a
	@# second copy of the value.
	@$(KUBECTL) -n $(NAMESPACE) get secret app-secret >/dev/null 2>&1 || { \
		head -c 32 /dev/urandom | base64 | tr -d '\n' | \
		$(KUBECTL) -n $(NAMESPACE) create secret generic app-secret --from-file=token=/dev/stdin; }

.PHONY: deploy
deploy: load $(HELM) platform ## Push the image, apply platform resources, helm upgrade --install as the deployer ServiceAccount
	./cluster/deployer-kubeconfig.sh $(KUBECTL) $(DEPLOYER_KUBECONFIG)
	@# --wait=watcher: Helm 4 doesn't wait by default. No --rollback-on-failure, so a failed
	@# rollout stays in place for kubectl describe/logs. The deployer kubeconfig is deleted
	@# whether Helm succeeds or fails, so no live token stays on disk.
	KUBECONFIG=$(DEPLOYER_KUBECONFIG) $(HELM) upgrade --install app charts/app --namespace $(NAMESPACE) \
		--set image.registry=$(REGISTRY) --set image.digest=$$($(IMAGE_DIGEST_CMD)) \
		--wait=watcher --timeout 2m; \
		rc=$$?; rm -f $(DEPLOYER_KUBECONFIG); exit $$rc
	$(KUBECTL) -n $(NAMESPACE) get pods -o wide

.PHONY: lint
lint: $(HELM) ## helm lint the chart (placeholder digest, no registry needed)
	$(HELM) lint charts/app -f charts/app/ci/lint-values.yaml

.PHONY: test
test: $(VENV)/.installed ## Run app unit tests (python -m pytest)
	cd app && ../$(PYTHON) -m pytest -v

# Recreate the venv only when the pinned requirements change.
$(VENV)/.installed: app/requirements.txt app/requirements-dev.txt
	python3 -m venv $(VENV)
	$(PYTHON) -m pip install -q -r app/requirements-dev.txt
	touch $@

.PHONY: test-security
test-security: $(KUBECTL) ## Run live control tests in tests/security against the cluster
	@failed=0; for t in tests/security/test_*.sh; do \
		KUBECTL=$(KUBECTL) $$t || failed=1; echo; \
	done; \
	if [ $$failed -eq 0 ]; then echo "ALL SECURITY TESTS PASSED"; else echo "SECURITY TESTS FAILED" >&2; exit 1; fi

.PHONY: clean-test-pods
clean-test-pods: $(KUBECTL) ## Delete pods left behind by a killed security test run
	$(KUBECTL) delete pods -A -l security-test --ignore-not-found

.PHONY: policy-test
policy-test: ## Run Kyverno CLI tests offline (no cluster needed)
	$(call todo,Phase 5)

# --- CI security gates (Phase 7, ADR 0011) -------------------------------------------
# Every gate fails the build on a finding. Accepted findings live in one reviewed place
# each: `# nosec <id>` with a reason for Bandit, tools/trivy/trivyignore.yaml (scoped to a
# file, with a reason and an expiry) for Trivy. The inputs are variables so
# tests/gates/test_gates.sh can run these same targets against planted bad inputs.
SCAN_VENV         := .venv-scan
PIP_TOOLS_VERSION := 7.6.2
SECRETS_REPO ?= .
SAST_SRC     ?= app/src
AUDIT_REQS   ?= app/requirements.txt
SCAN_IMAGE   ?= $(IMAGE):$(IMAGE_TAG)
IAC_DIR      ?= .
TRIVY_IGNORE ?= tools/trivy/trivyignore.yaml
SBOM         ?= sbom.cdx.json
# Scratch space, gitignored, overwritten on each run. Trivy's vulnerability DB lives here
# too rather than in ~/.cache.
CACHE        := $(CURDIR)/.cache
TRIVY_COMMON := --cache-dir $(CACHE)/trivy --quiet
TRIVY_GATE   := $(TRIVY_COMMON) --exit-code 1 --ignorefile $(TRIVY_IGNORE)

# --require-hashes: pip refuses any file whose hash isn't in the lock.
$(SCAN_VENV)/.installed: tools/scan-requirements.txt
	python3 -m venv $(SCAN_VENV)
	$(SCAN_VENV)/bin/pip install -q --require-hashes --only-binary=:all: -r tools/scan-requirements.txt
	touch $@

.PHONY: scan-lock
scan-lock: ## Re-lock tools/scan-requirements.txt (Bandit, pip-audit) with hashes
	@# pip-tools only writes the lock; the lock is what gets reviewed in the diff.
	python3 -m venv $(CACHE)/pip-tools
	$(CACHE)/pip-tools/bin/pip install -q pip-tools==$(PIP_TOOLS_VERSION)
	$(CACHE)/pip-tools/bin/pip-compile -q --generate-hashes --allow-unsafe --strip-extras --no-emit-index-url \
		-o tools/scan-requirements.txt tools/scan-requirements.in

.PHONY: secrets-scan
secrets-scan: $(GITLEAKS) ## Gate: gitleaks over the full git history (a secret deleted later still fails)
	$(GITLEAKS) git --no-banner --redact --verbose $(SECRETS_REPO)

.PHONY: secrets-staged
secrets-staged: $(GITLEAKS) ## Scan only the staged changes for secrets (what the pre-commit hook runs)
	$(GITLEAKS) git --pre-commit --staged --no-banner --redact --verbose $(SECRETS_REPO)

.PHONY: hooks
hooks: $(GITLEAKS) ## Install the repo's git hooks (pre-commit secrets scan) for this clone
	git config core.hooksPath tools/hooks
	@echo "pre-commit secrets scan enabled (git config core.hooksPath tools/hooks)"

.PHONY: sast
sast: $(SCAN_VENV)/.installed ## Gate: Bandit over the app source; any finding fails
	$(SCAN_VENV)/bin/bandit -r $(SAST_SRC)

.PHONY: deps-audit
deps-audit: $(SCAN_VENV)/.installed ## Gate: pip-audit of the pinned runtime requirements; any known vulnerability fails
	@# --no-deps: the file pins every transitive dependency, so it is audited exactly as
	@# written. The image scan separately checks what was actually installed.
	$(SCAN_VENV)/bin/pip-audit -r $(AUDIT_REQS) --no-deps --disable-pip --progress-spinner off

.PHONY: scan-image
scan-image: build $(TRIVY) ## Gate: Trivy image scan; fails on a fixable HIGH/CRITICAL vulnerability or an embedded secret
	$(TRIVY) image $(TRIVY_GATE) --scanners vuln,secret --severity HIGH,CRITICAL --ignore-unfixed $(SCAN_IMAGE)

.PHONY: sbom
sbom: build $(TRIVY) ## Write a CycloneDX SBOM of the app image to sbom.cdx.json
	$(TRIVY) image $(TRIVY_COMMON) --format cyclonedx --output $(SBOM) $(SCAN_IMAGE)
	@echo "wrote $(SBOM)"

.PHONY: scan-iac
scan-iac: $(TRIVY) $(HELM) ## Gate: Trivy misconfiguration scan of the rendered chart, platform manifests, Dockerfile; any finding fails
	@# The chart is scanned as the pinned Helm renders it (what the cluster receives), so
	@# charts/ is skipped in the tree scan, along with third-party and generated dirs.
	@mkdir -p $(CACHE)/rendered
	$(HELM) template app charts/app --namespace $(NAMESPACE) -f charts/app/ci/lint-values.yaml >$(CACHE)/rendered/app-chart.yaml
	@# Both scans always run, so a finding in the chart doesn't hide one in platform/.
	rc=0; \
	$(TRIVY) config $(TRIVY_GATE) --config-data tools/trivy/data $(CACHE)/rendered || rc=1; \
	$(TRIVY) config $(TRIVY_GATE) --config-data tools/trivy/data \
		--skip-dirs charts,bin,.git,.cache,.kube,$(VENV),$(SCAN_VENV) $(IAC_DIR) || rc=1; \
	exit $$rc

.PHONY: scan
scan: secrets-scan sast deps-audit scan-image scan-iac ## Run every CI security gate (make -k scan shows all failures)

.PHONY: test-gates
test-gates: ## Prove each gate rejects a planted bad input and passes on this repo (PASS/FAIL per check)
	./tests/gates/test_gates.sh

.PHONY: images
images: $(HELM) ## Write images.txt: every third-party image, pinned by digest and checked against its registry
	./airgap/list-images.sh $(HELM)

.PHONY: mirror
mirror: ## Copy images.txt into the local registry by digest and verify
	$(call todo,Phase 8)
