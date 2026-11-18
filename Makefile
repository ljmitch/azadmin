# Podman shortcuts for GNU make with a POSIX shell. Start the engine first.
IMAGE ?= admin-toolbox
PROFILE ?= core
TAG ?= $(PROFILE)
BASE_IMAGE ?= ubuntu:24.04
DOTNET_SDK_IMAGE ?= mcr.microsoft.com/dotnet/sdk:10.0-noble
DATED := $(shell date -u +%Y-%m-%d)
BUILD_DATE := $(shell date -u +%Y%m%d%H%M%S)

ifeq ($(filter $(PROFILE),core dotnet functions),)
$(error PROFILE must be core, dotnet or functions)
endif

VERSION_SELECTORS := $(shell sed -nE 's/^ARG ([A-Z_]+_VERSION)=latest$$/\1/p' Dockerfile)
VERSION_ARGS := $(foreach name,$(VERSION_SELECTORS),$(if $($(name)),--build-arg '$(name)=$($(name))'))
BUILD_ARGS := --build-arg TOOLBOX_PROFILE=$(PROFILE) \
    --build-arg BASE_IMAGE=$(BASE_IMAGE) \
    --build-arg DOTNET_SDK_IMAGE=$(DOTNET_SDK_IMAGE) $(VERSION_ARGS)

VOLUMES := \
    -v admin_az:/root/.azure \
    -v admin_azps:/root/.Azure \
    -v admin_kube:/root/.kube

.PHONY: build build-tag build-fresh shell shell-stateless verify clean logs volumes volumes-wipe pull-bases refresh size

build: ## Build the selected profile; cached floating tools may be reused.
	podman build $(BUILD_ARGS) -t $(IMAGE):$(TAG) .

build-fresh: ## Pull parents and re-resolve installed tools.
	podman build --pull=always $(BUILD_ARGS) --build-arg BUILD_DATE=$(BUILD_DATE) -t $(IMAGE):$(TAG) .

build-tag: ## Build a dated candidate; verification/scanning precede promotion.
	podman build $(BUILD_ARGS) -t $(IMAGE):$(PROFILE)-$(DATED) .

shell: ## Interactive shell with the workspace and credential volumes.
	podman run -it --rm \
	    -v "$(CURDIR):/work" -w /work \
	    $(VOLUMES) \
	    $(IMAGE):$(TAG)

shell-stateless: ## Fresh credential login without persistent caches.
	podman run -it --rm \
	    -v "$(CURDIR):/work" -w /work \
	    $(IMAGE):$(TAG)

verify: ## Mount verification source read-only and require the selected profile.
	podman run --rm \
	    -v "$(CURDIR):/work:ro" -w /work \
	    $(IMAGE):$(TAG) pwsh -NoProfile -File ./scripts/Verify-Toolbox.ps1 -ExpectedProfile $(PROFILE)

clean: ## Review confirmation before pruning dangling images; volumes remain.
	podman image prune
	podman images $(IMAGE)

logs: ## List local tags and sizes.
	podman images $(IMAGE)

volumes: ## List credential-cache volume names.
	podman volume ls

volumes-wipe: ## Explicitly remove named credentials; next use requires login.
	podman volume rm admin_az admin_azps admin_kube

pull-bases: ## Pull only source images used by the selected profile.
	podman pull $(BASE_IMAGE)
ifneq ($(PROFILE),core)
	podman pull $(DOTNET_SDK_IMAGE)
endif

refresh: ## Pull the published profile; running containers remain unchanged.
	podman pull ghcr.io/ljmitch/azadmin:$(PROFILE)

size: ## Inspect image, cache and volume storage as separate assets.
	podman system df
	podman images $(IMAGE) --format "{{.Repository}}:{{.Tag}} {{.Size}}"
	@podman volume ls --format "{{.Name}}" | while read -r v; do \
	  podman volume inspect "$$v" --format "$$v: {{.Mountpoint}}"; \
	done
