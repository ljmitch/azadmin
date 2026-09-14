# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# azure-admin-toolbox
# Ubuntu 24.04 LTS (noble) + PowerShell 7 + Azure CLI + Az + Microsoft.Graph
#
# Version philosophy:
#   - Everything floats to latest BY DEFAULT, resolved at build time.
#   - Anything can be pinned by passing an explicit --build-arg.
#   - Refresh floating layers deliberately with --build-arg BUILD_DATE=<ts>.
# ---------------------------------------------------------------------------

FROM ubuntu:24.04

# ---- Tool versions ----------------------------------------------------------
# Pass "latest" (the default) to resolve at build time via GitHub releases,
# or pin explicitly, e.g.: --build-arg YQ_VERSION=v4.48.2
ARG YQ_VERSION=latest
ARG HELM_VERSION=latest

# Cache-buster: --build-arg BUILD_DATE=$(Get-Date -Format yyyyMMddHHmm)
# forces re-resolution of every floating layer from this point down.
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="azure-admin-toolbox" \
      org.opencontainers.image.description="Reusable Azure/M365 admin toolbox (pwsh7, az, Az, Graph, TF, AKS)" \
      org.opencontainers.image.source="PRIVATE REPO"

# ---- Base packages (all apt tooling landed UP FRONT - nothing later) --------
# apt-get install does not upgrade packages already in ubuntu:24.04 (libc6,
# base-files, ...). upgrade first so a cache-bust / --no-cache build takes
# noble-updates + noble-security. --force-confold keeps existing conffiles.
# dnsutils/iputils/netcat: network debugging is a core workload.
# build-essential stays out (no compilation in this image).
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      wget curl apt-transport-https ca-certificates gnupg lsb-release \
      git unzip zip less jq rsync \
      python3 python3-pip \
      dnsutils iputils-ping netcat-openbsd traceroute \
      openssh-client rsync \
 && rm -rf /var/lib/apt/lists/*

# ---- PostgreSQL client via PGDG (latest stable, not Ubuntu's aged copy) -----
# Ubuntu noble ships postgresql-client-16; PGDG bootstrap script gives 18 and
# auto-tracks. Uses PGDG's official apt.postgresql.org.sh bootstrap.
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-common \
 && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
 && apt-get update \
 && apt-get install -y postgresql-client \
 && rm -rf /var/lib/apt/lists/*

# ---- PowerShell 7 via packages.microsoft.com (PMC) ---------------------------
# PMC lag scar: new pwsh announcements can lag the feed by days. See
# docs/TROUBLESHOOTING.md before assuming breakage is ours.
RUN . /etc/os-release \
 && TERM=dumb wget -q https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb \
 && TERM=dumb dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y powershell \
 && rm -rf /var/lib/apt/lists/*

# ---- Azure CLI - separate Microsoft feed (docs-confirmed on noble) -----------
# Ref: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux
RUN mkdir -p /etc/apt/keyrings \
 && curl -sLS https://packages.microsoft.com/keys/microsoft.asc \
      | gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg \
 && chmod go+r /etc/apt/keyrings/microsoft.gpg \
 && AZ_DIST=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") \
 && printf 'Types: deb\nURIs: https://packages.microsoft.com/repos/azure-cli/\nSuites: %s\nComponents: main\nArchitectures: %s\nSigned-by: /etc/apt/keyrings/microsoft.gpg\n' \
      "$AZ_DIST" "$(dpkg --print-architecture)" \
      > /etc/apt/sources.list.d/azure-cli.sources \
 && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y azure-cli \
 && rm -rf /var/lib/apt/lists/*

# ---- GitHub CLI (gh) ----------------------------------------------------------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
     -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y gh \
 && rm -rf /var/lib/apt/lists/*

# ---- Azure CLI extensions (admin-relevant) ------------------------------------
RUN az extension add --name azure-devops --yes \
 && az extension add --name aks-preview --yes \
 && az extension add --name ssh --yes

# ---- Bicep (bundled with az) --------------------------------------------------
RUN az bicep install

# ---- yq (floats to latest via GitHub API; pin with --build-arg) --------------
RUN set -eux; \
    if [ "${YQ_VERSION}" = "latest" ]; then \
      RESOLVED=$(curl -s https://api.github.com/repos/mikefarah/yq/releases/latest | jq -r '.tag_name'); \
    else \
      RESOLVED="${YQ_VERSION}"; \
    fi; \
    echo "Installing yq ${RESOLVED}"; \
    curl -sSfL -o /usr/local/bin/yq \
      "https://github.com/mikefarah/yq/releases/download/${RESOLVED}/yq_linux_amd64"; \
    chmod +x /usr/local/bin/yq; \
    yq --version

# ---- Terraform (HashiCorp apt, codename-resolved) + tflint + checkov ----------
# Codename from /etc/os-release so this layer survives a later Ubuntu bump.
RUN wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor \
       -o /usr/share/keyrings/hashicorp-archive-keyring.gpg \
 && CODENAME=$(grep -oP '(?<=UBUNTU_CODENAME=).*' /etc/os-release || lsb_release -cs) \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com ${CODENAME} main" \
        > /etc/apt/sources.list.d/hashicorp.list \
 && apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y terraform \
 && rm -rf /var/lib/apt/lists/* \
 && cd /tmp \
 && curl -sSfLO https://github.com/terraform-linters/tflint/releases/latest/download/tflint_linux_amd64.zip \
 && curl -sSfLO https://github.com/terraform-linters/tflint/releases/latest/download/checksums.txt \
 && sha256sum --ignore-missing -c checksums.txt \
 && unzip -o tflint_linux_amd64.zip -d /usr/local/bin \
 && rm tflint_linux_amd64.zip checksums.txt \
 && pip3 install --break-system-packages --no-cache-dir checkov

# PEP-668 note: noble marks pip as externally-managed; --break-system-packages
# is acceptable in a single-purpose container image.

# ---- Kubernetes (kubectl + kubelogin via az) ----------------------------------
RUN az aks install-cli

# ---- Helm (floats to latest via GitHub API; pin with --build-arg) --------------
RUN set -eux; \
    if [ "${HELM_VERSION}" = "latest" ]; then \
      RESOLVED=$(curl -s https://api.github.com/repos/helm/helm/releases/latest | jq -r '.tag_name'); \
    else \
      RESOLVED="${HELM_VERSION}"; \
    fi; \
    echo "Installing helm ${RESOLVED}"; \
    curl -fsSL "https://get.helm.sh/helm-${RESOLVED}-linux-amd64.tar.gz" \
      | tar xz --strip-components=1 -C /usr/local/bin linux-amd64/helm; \
    helm version --short

# ---- Azure Storage copy tool (azcopy - binary-distributed) ---------------------
RUN curl -sL https://aka.ms/downloadazcopy-v10-linux \
      | tar xz --strip-components=1 --wildcards -C /usr/local/bin '*/azcopy' \
 && azcopy --version

# ---- Azure Developer CLI (azd) --------------------------------------------------
RUN curl -fsSL https://aka.ms/install-azd.sh | bash

# ---- PowerShell modules (Az + curated Graph leaves + Exchange) ----------------
# Gallery latest at build time. Real .ps1 (not a backslash-continued -Command
# string): a # inside a joined RUN line comments out the rest of the install.
# See docs/TROUBLESHOOTING.md scar 18.
COPY scripts/Install-PsModules.ps1 /tmp/Install-PsModules.ps1
RUN pwsh -NoProfile -File /tmp/Install-PsModules.ps1 \
 && rm -f /tmp/Install-PsModules.ps1

# ---- Optional PowerShell profile (helpers, prompt) ------------------------------
COPY config/powershell/Microsoft.PowerShell_profile.ps1 \
     /root/.config/powershell/Microsoft.PowerShell_profile.ps1

WORKDIR /work
CMD ["pwsh"]
