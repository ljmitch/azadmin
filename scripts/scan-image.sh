#!/usr/bin/env bash
set -euo pipefail
umask 077

image="${1:?Usage: scan-image.sh IMAGE [REPORT_DIR]}"
report_dir="${2:-reports/image}"
findings_policy="${IMAGE_FINDINGS_POLICY:-block}"
case "$findings_policy" in
  block|warn) ;;
  *) printf 'Invalid image findings policy. Use block or warn.\n' >&2; exit 2 ;;
esac
mkdir -p "$report_dir"
image_id="$(docker image inspect "$image" --format '{{.Id}}')"
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 2
private_dir="$(mktemp -d)"
trap 'rm -f -- "$private_dir/vulnerabilities.json" "$private_dir/secrets.json"; rmdir -- "$private_dir"' EXIT
trivy --version > "$report_dir/trivy-version.txt"

# Save all severities and unfixed findings; an ignore file must not weaken this gate.
trivy --config /dev/null image --image-src docker --timeout 15m \
  --scanners vuln --ignorefile /dev/null --ignore-unfixed=false \
  --severity UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL --list-all-pkgs=true \
  --format json --output "$private_dir/vulnerabilities.json" "$image_id"
jq -e --arg image "$image_id" \
  '.SchemaVersion == 2 and .ArtifactType == "container_image" and
   .Metadata.ImageID == $image and .Metadata.OS.Family == "ubuntu" and
   (.Results | type == "array") and any(.Results[]; .Class == "os-pkgs" and (.Packages | length) > 0)' \
  "$private_dir/vulnerabilities.json" > /dev/null

# Public-repository artifacts must not contain image-config ENV/history values.
jq 'del(.Metadata.ImageConfig)' "$private_dir/vulnerabilities.json" > "$report_dir/vulnerabilities.json"
trivy --config /dev/null convert --format cyclonedx \
  --output "$report_dir/sbom.cdx.json" "$report_dir/vulnerabilities.json"
jq -e '.bomFormat == "CycloneDX" and (.specVersion | type == "string")' \
  "$report_dir/sbom.cdx.json" > /dev/null

trivy --config /dev/null image --image-src docker --timeout 15m \
  --scanners secret --image-config-scanners secret --ignorefile /dev/null \
  --format json --output "$private_dir/secrets.json" "$image_id"
jq -e --arg image "$image_id" '.SchemaVersion == 2 and .ArtifactType == "container_image" and .Metadata.ImageID == $image and (.Results == null or (.Results | type == "array"))' \
  "$private_dir/secrets.json" > /dev/null
# Retain rule/count evidence only; matched source text never enters artifacts/logs.
jq '{findings:([.Results[]?.Secrets[]?] | length),rules:([.Results[]?.Secrets[]?.RuleID] | group_by(.) | map({rule:.[0],count:length}))}' \
  "$private_dir/secrets.json" > "$report_dir/secrets-summary.json"

blocking="$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH" or .Severity == "CRITICAL")] | length' "$report_dir/vulnerabilities.json")"
secrets="$(jq -er '.findings' "$report_dir/secrets-summary.json")"
eol="$(jq -r '.Metadata.OS.EOSL // false' "$report_dir/vulnerabilities.json")"
result=clean
if (( blocking > 0 || secrets > 0 )) || [[ "$eol" != false ]]; then
  if [[ "$findings_policy" == warn ]]; then result=warning; else result=blocked; fi
fi
jq -n --arg image "$image_id" --argjson blocking "$blocking" --argjson secrets "$secrets" --argjson eol "$eol" \
  --arg policy "$findings_policy" --arg result "$result" \
  '{image:$image,policy:$policy,policy_result:$result,blocking_vulnerabilities:$blocking,secret_findings:$secrets,eol_os:$eol}' \
  > "$report_dir/scan-summary.json"
if [[ -f "${TRIVY_CACHE_DIR:-$HOME/.cache/trivy}/db/metadata.json" ]]; then
  jq '{Version,UpdatedAt,NextUpdate,DownloadedAt}' \
    "${TRIVY_CACHE_DIR:-$HOME/.cache/trivy}/db/metadata.json" > "$report_dir/database-metadata.json"
fi
printf -v summary '%s HIGH/CRITICAL findings, %s secret matches, EOL=%s' "$blocking" "$secrets" "$eol"
printf 'Image policy (%s): %s (%s)\n' "$findings_policy" "$summary" "$result"
if [[ "$result" == warning ]]; then
  printf '::warning title=Image findings for %s::%s\n' "$image" "$summary"
fi
[[ "$result" != blocked ]]
