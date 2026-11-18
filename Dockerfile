# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# azure-admin-toolbox
# Ubuntu + PowerShell 7 + Azure CLI + Az + Microsoft.Graph
# + Terraform + tflint + checkov + kubectl + helm + azcopy + azd
# Optional profiles add .NET 10, then Functions Core Tools v4.
#
# Version philosophy:
#   - Everything floats to latest BY DEFAULT, resolved at build time.
#   - Base/SDK images and yq/Helm expose optional version build args.
#   - Refresh floating layers deliberately with --build-arg BUILD_DATE=<ts>.
# ---------------------------------------------------------------------------

ARG BASE_IMAGE=ubuntu:24.04
ARG DOTNET_SDK_IMAGE=mcr.microsoft.com/dotnet/sdk:10.0-noble
ARG TOOLBOX_PROFILE=core

FROM ${BASE_IMAGE} AS core

# ---- Tool versions ----------------------------------------------------------
# Pass "latest" (the default) to resolve at build time via GitHub releases,
# or pin explicitly, e.g.: --build-arg YQ_VERSION=v4.48.2
ARG YQ_VERSION=latest
ARG HELM_VERSION=latest

# Cache-buster: --build-arg BUILD_DATE=$(Get-Date -Format yyyyMMddHHmm)
# forces re-resolution of every floating layer from this point down.
ARG BUILD_DATE=unknown

LABEL org.opencontainers.image.title="azure-admin-toolbox" \
      org.opencontainers.image.description="Reusable Azure/M365 admin toolbox with optional development profiles" \
      org.opencontainers.image.source="https://github.com/ljmitch/azadmin" \
      org.opencontainers.image.licenses="MIT"

ENV TOOLBOX_PROFILE=core \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    AZURE_CORE_COLLECT_TELEMETRY=false

# Release downloads below are linux-amd64; fail before installing an incompatible set.
RUN test "$(dpkg --print-architecture)" = amd64 \
 || { printf 'This toolbox currently supports linux/amd64 only.\n' >&2; exit 1; }

# ---- Base packages ---------------------------------------------------------
# apt-get install does not upgrade packages already in ubuntu:24.04 (libc6,
# base-files, ...). upgrade first so a cache-bust / --no-cache build takes
# noble-updates + noble-security. --force-confold keeps existing conffiles.
# dnsutils/iputils/netcat: network debugging is a core workload.
# Network extras: extra noble-archive CLIs after the core set. No extra feeds.
# build-essential stays out; managed .NET builds do not need a native compiler.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      wget curl apt-transport-https ca-certificates gnupg lsb-release \
      git unzip zip less jq rsync \
      python3 python3-venv \
      procps \
      dnsutils iputils-ping netcat-openbsd traceroute \
      openssh-client \
      iproute2 mtr-tiny tcptraceroute iputils-tracepath fping hping3 \
      iperf3 tcpdump \
      socat openssl nmap ipcalc whois \
 && rm -rf /var/lib/apt/lists/*

# ---- PostgreSQL client via PGDG (latest stable, not Ubuntu's aged copy) -----
# Ubuntu noble ships postgresql-client-16; PGDG bootstrap script gives 18 and
# auto-tracks. Uses PGDG's official apt.postgresql.org.sh bootstrap.
# postgresql-common creates a server snakeoil key; client tooling must not ship it.
RUN apt-get update && apt-get install -y --no-install-recommends postgresql-common \
 && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
 && apt-get update \
 && apt-get install -y postgresql-client \
 && rm -f /etc/ssl/private/ssl-cert-snakeoil.key /etc/ssl/certs/ssl-cert-snakeoil.pem \
 && rm -rf /var/lib/apt/lists/*

# ---- PowerShell 7 via packages.microsoft.com (PMC) --------------------------
# PMC lag scar: new pwsh announcements can lag the feed by days. See
# docs/TROUBLESHOOTING.md before assuming breakage is ours.
RUN . /etc/os-release \
 && TERM=dumb wget -q https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb \
 && TERM=dumb dpkg -i packages-microsoft-prod.deb && rm packages-microsoft-prod.deb \
 && apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends powershell \
 && rm -rf /var/lib/apt/lists/*

# ---- Azure CLI - separate Microsoft feed (docs-confirmed on noble) -----------
# Ref: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux
RUN mkdir -p /etc/apt/keyrings \
 && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
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
      RESOLVED=$(curl -fsSL https://api.github.com/repos/mikefarah/yq/releases/latest | jq -er '.tag_name | select(startswith("v"))'); \
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
 && TFLINT_RELEASE=$(curl -fsSL https://api.github.com/repos/terraform-linters/tflint/releases/latest | jq -er '.tag_name | select(startswith("v"))') \
 && curl -fsSLO "https://github.com/terraform-linters/tflint/releases/download/${TFLINT_RELEASE}/tflint_linux_amd64.zip" \
 && curl -fsSLO "https://github.com/terraform-linters/tflint/releases/download/${TFLINT_RELEASE}/checksums.txt" \
 && grep -E '^[[:xdigit:]]{64} [ *]tflint_linux_amd64.zip$' checksums.txt > tflint-checksum.txt \
 && sha256sum -c tflint-checksum.txt \
 && unzip -o tflint_linux_amd64.zip -d /usr/local/bin \
 && rm tflint_linux_amd64.zip checksums.txt tflint-checksum.txt \
 && python3 -m venv /opt/checkov \
 && /opt/checkov/bin/python -m pip install --no-cache-dir checkov \
 && ln -s /opt/checkov/bin/checkov /usr/local/bin/checkov

# PEP-668: keep Checkov's dependencies separate from the distro and Azure CLI Python.

# ---- Kubernetes (kubectl + kubelogin via az) ----------------------------------
RUN az aks install-cli

# ---- Helm (floats to latest via GitHub API; pin with --build-arg) --------------
RUN set -eux; \
    if [ "${HELM_VERSION}" = "latest" ]; then \
      RESOLVED=$(curl -fsSL https://api.github.com/repos/helm/helm/releases/latest | jq -er '.tag_name | select(startswith("v"))'); \
    else \
      RESOLVED="${HELM_VERSION}"; \
    fi; \
    echo "Installing helm ${RESOLVED}"; \
    DOWNLOAD_DIR=$(mktemp -d); \
    cd "$DOWNLOAD_DIR"; \
    curl -fsSLO "https://get.helm.sh/helm-${RESOLVED}-linux-amd64.tar.gz"; \
    curl -fsSLO "https://get.helm.sh/helm-${RESOLVED}-linux-amd64.tar.gz.sha256sum"; \
    sha256sum -c "helm-${RESOLVED}-linux-amd64.tar.gz.sha256sum"; \
    tar xzf "helm-${RESOLVED}-linux-amd64.tar.gz" --strip-components=1 -C /usr/local/bin linux-amd64/helm; \
    cd /; \
    rm -rf "$DOWNLOAD_DIR"; \
    helm version --short

# ---- Azure Storage copy tool (azcopy - binary-distributed) ---------------------
RUN curl -fsSL https://aka.ms/downloadazcopy-v10-linux -o /tmp/azcopy.tar.gz \
 && tar xzf /tmp/azcopy.tar.gz --strip-components=1 --wildcards -C /usr/local/bin '*/azcopy' \
 && rm /tmp/azcopy.tar.gz \
 && azcopy --version

# ---- Azure Developer CLI (azd) --------------------------------------------------
RUN curl -fsSL https://aka.ms/install-azd.sh -o /tmp/install-azd.sh \
 && bash /tmp/install-azd.sh \
 && rm /tmp/install-azd.sh

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

# Copy only SDK files; the source image's bundled PowerShell is not needed.
FROM ${DOTNET_SDK_IMAGE} AS dotnet-sdk

FROM core AS dotnet
ENV TOOLBOX_PROFILE=dotnet \
    DOTNET_ROOT=/usr/share/dotnet \
    DOTNET_RUNNING_IN_CONTAINER=true \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    DOTNET_NOLOGO=true \
    DOTNET_USE_POLLING_FILE_WATCHER=true
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      libicu74 libssl3t64 libstdc++6 libatomic1 tzdata \
 && rm -rf /var/lib/apt/lists/*
COPY --from=dotnet-sdk /usr/share/dotnet /usr/share/dotnet
RUN ln -s /usr/share/dotnet/dotnet /usr/local/bin/dotnet

# PMC is already configured by core. Keep GA Core Tools out of admin-only builds.
FROM dotnet AS functions
ENV TOOLBOX_PROFILE=functions
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends azure-functions-core-tools-4 \
 && rm -rf /var/lib/apt/lists/*

# Select a prebuilt stage, not runtime package installation into a running shell.
FROM ${TOOLBOX_PROFILE} AS toolbox
