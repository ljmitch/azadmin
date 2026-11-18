#!/usr/bin/env bash
set -euo pipefail
umask 077

version="${BETTERLEAKS_VERSION:-latest}"
case "$version" in
  latest) selector=latest ;;
  *)
    [[ "$version" =~ ^v1\.[0-9]+\.[0-9]+$ ]] || { echo 'Use latest or a stable Betterleaks v1 tag.' >&2; exit 2; }
    selector="tags/$version"
    ;;
esac

if [[ "$(git rev-parse --is-shallow-repository)" != false ]]; then
  echo 'Betterleaks needs a full checkout to scan branch history.' >&2
  exit 2
fi

private_dir="$(mktemp -d)"
trap 'rm -f -- "$private_dir/archive" "$private_dir/betterleaks" "$private_dir/findings.json" "$private_dir/scan.log"; rmdir -- "$private_dir"' EXIT
mkdir -p reports
release="$(curl -fsSL --retry 3 "https://api.github.com/repos/betterleaks/betterleaks/releases/$selector")"
tag="$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name' <<< "$release")"
if [[ ! "$tag" =~ ^v1\.[0-9]+\.[0-9]+$ ]]; then
  echo 'The Betterleaks CLI contract has changed. Review the new major version or select a stable v1 tag.' >&2
  exit 2
fi
if [[ "$version" != latest && "$tag" != "$version" ]]; then
  echo 'Betterleaks version resolution did not return the requested tag.' >&2
  exit 2
fi
asset="betterleaks_${tag#v}_linux_x64.tar.gz"
digest="$(jq -er --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest | select(test("^sha256:[0-9a-f]{64}$"))' <<< "$release")"
curl -fsSL --retry 3 "https://github.com/betterleaks/betterleaks/releases/download/$tag/$asset" -o "$private_dir/archive"
printf '%s  %s\n' "${digest#sha256:}" "$private_dir/archive" | sha256sum -c --status
tar -xzf "$private_dir/archive" --no-same-owner -C "$private_dir" betterleaks
printf 'Betterleaks %s\n' "$tag"

# Findings and scanner output stay private, even on failure. Credential validation
# and target-provided configuration are disabled for untrusted source.
unset BETTERLEAKS_CONFIG BETTERLEAKS_CONFIG_TOML GITLEAKS_CONFIG GITLEAKS_CONFIG_TOML
status=0
"$private_dir/betterleaks" git --log-opts=HEAD --redact=100 --no-banner \
  --ignore-gitleaks-allow --gitleaks-ignore-path "$private_dir" \
  --timeout 300 --exit-code 23 --report-format json --report-path "$private_dir/findings.json" . \
  > "$private_dir/scan.log" 2>&1 || status=$?

if [[ "$status" != 0 && "$status" != 23 ]]; then
  printf 'Betterleaks scan failed (exit %s).\n' "$status" >&2
  exit 1
fi
count="$(jq -er 'if type == "array" then length else error("Expected a Betterleaks findings array") end' "$private_dir/findings.json")"
jq -n --arg version "$tag" --arg archive_sha256 "${digest#sha256:}" --argjson count "$count" \
  '{version:$version,archive_sha256:$archive_sha256,scope:"commits reachable from HEAD",findings:$count}' \
  > reports/betterleaks-summary.json
printf 'Betterleaks history scan: %s findings\n' "$count"
[[ "$status" == 0 && "$count" == 0 ]]
