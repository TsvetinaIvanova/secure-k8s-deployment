SHELL := /bin/bash
.DEFAULT_GOAL := help

CLUSTER_NAME ?= secure-k8s
NAMESPACE    ?= app
VENV         ?= .venv
PYTHON       := $(VENV)/bin/python
IMAGE        ?= secure-k8s-app
IMAGE_TAG    ?= 0.1.0
APP_UID      := 65532

# Targets not implemented yet fail loudly instead of pretending to succeed.
define todo
	@echo "make $@: not implemented yet ($(1))" >&2; exit 1
endef

.PHONY: help
help: ## List all targets
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

.PHONY: up
up: ## Create the local kind cluster (and CNI if needed)
	$(call todo,Phase 2)

.PHONY: down
down: ## Delete the local kind cluster
	$(call todo,Phase 2)

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
