#!/usr/bin/env bash
set -euo pipefail

version=0.76.2
checksum=bc0fc726e017b8927a62b2d3531d7a84ee01769daf5c99ed866dced54089fdbf
destination="${RUNNER_TEMP:?This installer runs on the Linux CI worker}/azadmin-trivy"
mkdir -p "$destination"
archive="$destination/trivy.tar.gz"
curl --fail --silent --show-error --location --retry 3 \
  "https://github.com/aquasecurity/trivy/releases/download/v${version}/trivy_${version}_Linux-64bit.tar.gz" \
  --output "$archive"
printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check --status
tar --extract --gzip --no-same-owner --file "$archive" --directory "$destination" trivy
rm -- "$archive"
printf '%s\n' "$destination" >> "${GITHUB_PATH:?}"
"$destination/trivy" --version
