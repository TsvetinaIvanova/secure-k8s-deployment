SHELL := /bin/bash
.DEFAULT_GOAL := help

CLUSTER_NAME ?= secure-k8s
NAMESPACE    ?= app
VENV         ?= .venv
PYTHON       := $(VENV)/bin/python
IMAGE        ?= secure-k8s-app
IMAGE_TAG    ?= 0.1.0
APP_UID      := 65532
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
up: $(KIND) $(KUBECTL) ## Create the local kind cluster (1 control plane, 2 workers)
	@if $(KIND) get clusters | grep -qx $(CLUSTER_NAME); then \
		echo "cluster $(CLUSTER_NAME) already exists"; \
	else \
		$(KIND) create cluster --name $(CLUSTER_NAME) --config cluster/kind-config.yaml --wait 120s; \
	fi
	@# kind's --wait only covers the control plane; workers can still be NotReady here.
	$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=120s
	$(KUBECTL) get nodes -o wide

.PHONY: down
down: $(KIND) ## Delete the local kind cluster
	$(KIND) delete cluster --name $(CLUSTER_NAME)
	rm -f $(KUBECONFIG)

.PHONY: kubeconfig
kubeconfig: ## Print the export line for using kubectl against this cluster by hand
	@echo "export KUBECONFIG=$(KUBECONFIG) PATH=$(BIN):\$$PATH"

.PHONY: build
build: ## Build the app container image
	docker build -t $(IMAGE):$(IMAGE_TAG) app

.PHONY: smoke
smoke: build ## Run the image as Kubernetes will (read-only, non-root, no caps) and curl it
	./tests/smoke_container.sh $(IMAGE):$(IMAGE_TAG) $(APP_UID)

.PHONY: load
load: ## Build the image and load it into kind
	$(call todo,Phase 2)

.PHONY: deploy
deploy: ## helm upgrade --install the app into namespace app
	$(call todo,Phase 2)

.PHONY: test
test: $(VENV)/.installed ## Run app unit tests (python -m pytest)
	cd app && ../$(PYTHON) -m pytest -v

# Recreate the venv only when the pinned requirements change.
$(VENV)/.installed: app/requirements.txt app/requirements-dev.txt
	python3 -m venv $(VENV)
	$(PYTHON) -m pip install -q -r app/requirements-dev.txt
	touch $@

.PHONY: test-security
test-security: ## Run live control tests in tests/security against the cluster
	$(call todo,Phase 3)

.PHONY: policy-test
policy-test: ## Run Kyverno CLI tests offline (no cluster needed)
	$(call todo,Phase 5)

.PHONY: scan
scan: ## Scan the image and manifests (Trivy)
	$(call todo,Phase 7)

.PHONY: images
images: ## Write images.txt: every platform image pinned by digest
	$(call todo,Phase 2)

.PHONY: mirror
mirror: ## Copy images.txt into the local registry by digest and verify
	$(call todo,Phase 8)
