#!/usr/bin/env bash
set -euo pipefail

[[ "${GITHUB_REF:?}" == refs/heads/main ]] || { printf 'Publication requires main.\n' >&2; exit 1; }
[[ "${GITHUB_RUN_ID:?}" =~ ^[0-9]+$ && "${GITHUB_RUN_ATTEMPT:?}" =~ ^[0-9]+$ ]] || exit 2
repository="ghcr.io/${GITHUB_REPOSITORY,,}"

# Review every subject before writing any tag; never rebuild between scan and push.
for profile in core dotnet functions; do
  id="$(cat "reports/${profile}/image-id.txt")"
  [[ "$id" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 2
  [[ "$(docker image inspect "admin-toolbox:${profile}" --format '{{.Id}}')" == "$id" ]] || exit 1
  jq -e --arg image "$id" \
    '.image == $image and .blocking_vulnerabilities == 0 and .secret_findings == 0 and .eol_os == false' \
    "reports/${profile}/scan-summary.json" > /dev/null
done
for profile in core dotnet functions; do
  id="$(cat "reports/${profile}/image-id.txt")"
  release_tag="run-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${profile}"
  for tag in "$release_tag" "$profile"; do
    reference="${repository}:${tag}"
    docker tag "$id" "$reference"
    docker push "$reference" | tee "reports/${profile}/push-${tag}.log"
    docker buildx imagetools inspect "$reference" --format '{{json .Manifest}}' \
      > "reports/${profile}/published-${tag}.json"
  done
  if [[ "$profile" == core ]]; then
    docker tag "$id" "${repository}:latest"
    docker push "${repository}:latest" | tee reports/core/push-latest.log
  fi
done
