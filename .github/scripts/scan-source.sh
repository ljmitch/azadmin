#!/usr/bin/env bash
set -euo pipefail
umask 077
mkdir -p reports
private_report="$(mktemp)"
trap 'rm -f -- "$private_report"' EXIT
trivy --config /dev/null fs --scanners secret --ignorefile /dev/null \
  --skip-dirs .git --skip-dirs reports --skip-dirs .cache --skip-dirs .validation \
  --format json --output "$private_report" .
# Trivy fs labels a source-directory report as repository, including clean scans.
jq -e '.SchemaVersion == 2 and .ArtifactType == "repository" and (.Results == null or (.Results | type == "array"))' "$private_report" > /dev/null
jq '{findings:([.Results[]?.Secrets[]?] | length),rules:([.Results[]?.Secrets[]?.RuleID] | group_by(.) | map({rule:.[0],count:length}))}' \
  "$private_report" > reports/source-secrets-summary.json
count="$(jq -er '.findings' reports/source-secrets-summary.json)"
printf 'Source secret policy: %s findings\n' "$count"
(( count == 0 ))
