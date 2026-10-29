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
# Versioned file names: bumping a version makes make download the new binary.
KIND    := $(BIN)/kind-$(KIND_VERSION)
KUBECTL := $(BIN)/kubectl-$(KUBECTL_VERSION)
HELM    := $(BIN)/helm-$(HELM_VERSION)

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
	rm -f $(KUBECONFIG)

.PHONY: kubeconfig
kubeconfig: tools ## Print the export line for kubectl by hand; use: eval "$$(make -s kubeconfig)"
	@echo "export KUBECONFIG=$(KUBECONFIG) PATH=$(BIN):\$$PATH"

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
platform: $(KUBECTL) ## Apply platform resources: namespaces with Pod Security labels
	$(KUBECTL) apply -f platform/namespaces.yaml

.PHONY: deploy
deploy: load $(HELM) platform ## Push the image, apply platform resources, create the app Secret if missing, helm upgrade --install
	@# The Secret lives outside the chart (ADR 0005). It is created once with a random value,
	@# piped through stdin so it never appears in process arguments, the shell history or a file.
	@# `create` (not `apply`) also avoids the last-applied-configuration annotation, which would
	@# store a second copy of the value.
	@$(KUBECTL) -n $(NAMESPACE) get secret app-secret >/dev/null 2>&1 || { \
		head -c 32 /dev/urandom | base64 | tr -d '\n' | \
		$(KUBECTL) -n $(NAMESPACE) create secret generic app-secret --from-file=token=/dev/stdin; }
	@# --wait=watcher: Helm 4 doesn't wait by default. No --rollback-on-failure, so a failed
	@# rollout stays in place for kubectl describe/logs.
	$(HELM) upgrade --install app charts/app --namespace $(NAMESPACE) \
		--set image.registry=$(REGISTRY) --set image.digest=$$($(IMAGE_DIGEST_CMD)) \
		--wait=watcher --timeout 2m
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

.PHONY: policy-test
policy-test: ## Run Kyverno CLI tests offline (no cluster needed)
	$(call todo,Phase 5)

.PHONY: scan
scan: ## Scan the image and manifests (Trivy)
	$(call todo,Phase 7)

.PHONY: images
images: $(HELM) ## Write images.txt: every third-party image, pinned by digest and checked against its registry
	./airgap/list-images.sh $(HELM)

.PHONY: mirror
mirror: ## Copy images.txt into the local registry by digest and verify
	$(call todo,Phase 8)
