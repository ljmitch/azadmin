# ---------------------------------------------------------------------------
# One-liners around podman build / run.
# Requires GNU make. Podman machine must be running.
# ---------------------------------------------------------------------------

IMAGE   := admin-toolbox
TAG     := latest
DATED   := $(shell date +%Y-%m-%d)
BUILD_DATE := $(shell date +%Y%m%d%H%M)

VOLUMES := \
    -v admin_az:/root/.azure \
    -v admin_azps:/root/.Azure \
    -v admin_graph:/root/.local/share/IdentityCache \
    -v admin_kube:/root/.kube

.PHONY: build build-tag build-fresh shell shell-stateless verify clean logs volumes volumes-wipe pull-bases refresh size

build:          ## Build :latest (floats come from cache unless --build-arg-d)
	podman build -t $(IMAGE):$(TAG) .

build-fresh:    ## Build, but re-resolve all floating tools (cache-bust)
	podman build --build-arg BUILD_DATE=$(BUILD_DATE) -t $(IMAGE):$(TAG) .

build-tag:      ## Build a date-stamped tag, then alias :latest to it
	podman build -t $(IMAGE):$(DATED) .
	podman tag $(IMAGE):$(DATED) $(IMAGE):$(TAG)

shell:          ## Interactive shell with cwd + all cred volumes mounted (default)
	podman run -it --rm \
	    -v $(CURDIR):/work -w /work \
	    $(VOLUMES) \
	    $(IMAGE):$(TAG)

shell-stateless: ## Interactive shell with NO credential caches - fresh login every time
	podman run -it --rm \
	    -v $(CURDIR):/work -w /work \
	    $(IMAGE):$(TAG)

verify:         ## Run the smoke test against :latest - MUST bind-mount the repo
	podman run --rm \
	    -v $(CURDIR):/work -w /work \
	    $(IMAGE):$(TAG) pwsh -NoProfile -File ./scripts/Verify-Toolbox.ps1

clean:          ## Prune dangling <none>:<none> build remnants (leaves volumes alone)
	podman image prune
	podman images $(IMAGE)

logs:           ## Show every existing tag of the image
	podman images $(IMAGE)

volumes:        ## List the volume names that are credential caches
	podman volume ls

volumes-wipe:   ## Wipe every credential volume (forces fresh login across the board)
	podman volume rm admin_az admin_azps admin_graph admin_kube

pull-bases:     ## Refresh upstream base images this Dockerfile pulls from
	podman pull ubuntu:24.04
	podman pull registry.access.redhat.com/ubi9/ubi:latest

refresh:        ## Mass refresh :latest tags on all remote images (registry-mirrored)
	podman images --format "{{.Repository}}:{{.Tag}}" | \
	  while read -r img; do \
	    case "$$img" in \
	      localhost/*|*azurecr.io*) continue ;; \
	      *:latest) podman pull "$$img" || true ;; \
	    esac; \
	  done

size:           ## Show what toolbox layers + volumes are actually consuming
	podman system df
	podman images $(IMAGE) --format "{{.Repository}}:{{.Tag}} {{.Size}}"
	@podman volume ls --format "{{.Name}}" | while read -r v; do \
	  podman volume inspect "$$v" --format "$$v: {{.Mountpoint}}"; \
	done
