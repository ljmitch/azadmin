#!/usr/bin/env bash
set -euo pipefail

# Exercise the real wrappers with report fixtures and CLI doubles, without an engine or network.
command -v jq > /dev/null
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
fixture_parent="$(cd -- "${TMPDIR:-/tmp}" && pwd -P)"
fixture="$(mktemp -d "${fixture_parent}/azadmin-scan-tests.XXXXXXXX")"
cleanup() {
  [[ "${fixture%/*}" == "$fixture_parent" && "${fixture##*/}" == azadmin-scan-tests.* ]] || exit 2
  rm -rf -- "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/bin" "$fixture/work"
export SCAN_TEST_FIXTURE="$fixture"
export SCAN_TEST_IMAGE_ID="sha256:$(printf '%064d' 1)"

cat > "$fixture/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1 $2" == 'image inspect' ]] || exit 90
printf '%s\n' "$SCAN_TEST_IMAGE_ID"
MOCK
cat > "$fixture/bin/trivy" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
command=''; scanner=''; output=''
while (( $# )); do
  case "$1" in
    --version) printf 'Trivy fixture\n'; exit 0 ;;
    image|fs|convert) command="$1" ;;
    --scanners) scanner="$2"; shift ;;
    --output) output="$2"; shift ;;
  esac
  shift
done
[[ -n "$output" ]] || exit 91
case "$command" in
  convert)
    [[ "$SCAN_TEST_SCENARIO" != convert-error ]] || exit 23
    if [[ "$SCAN_TEST_SCENARIO" == invalid-sbom ]]; then
      printf '{"bomFormat":"invalid"}\n' > "$output"
    else
      printf '{"bomFormat":"CycloneDX","specVersion":"1.6","components":[]}\n' > "$output"
    fi
    ;;
  image)
    if [[ "$scanner" == vuln ]]; then
      [[ "$SCAN_TEST_SCENARIO" != vuln-error ]] || exit 24
      cp "$SCAN_TEST_FIXTURE/vulnerability.json" "$output"
    elif [[ "$scanner" == secret ]]; then
      [[ "$SCAN_TEST_SCENARIO" != secret-error ]] || exit 25
      cp "$SCAN_TEST_FIXTURE/secret.json" "$output"
    else exit 92
    fi
    ;;
  fs)
    [[ "$SCAN_TEST_SCENARIO" != source-error ]] || exit 26
    cp "$SCAN_TEST_FIXTURE/source.json" "$output"
    ;;
  *) exit 93 ;;
esac
MOCK
chmod +x "$fixture/bin/docker" "$fixture/bin/trivy"
export PATH="$fixture/bin:$PATH"
export TRIVY_CACHE_DIR="$fixture/cache"

jq -n --arg image "$SCAN_TEST_IMAGE_ID" \
  '{SchemaVersion:2,ArtifactType:"container_image",Metadata:{ImageID:$image,OS:{Family:"ubuntu",Name:"24.04"},ImageConfig:{Env:["AZADMIN_TEST_CONFIG_PRIVATE"]}},Results:[{Target:"Ubuntu",Class:"os-pkgs",Type:"ubuntu",Packages:[{Name:"libc6",Version:"1"}]}]}' \
  > "$fixture/base-vulnerability.json"
jq -n --arg image "$SCAN_TEST_IMAGE_ID" \
  '{SchemaVersion:2,ArtifactType:"container_image",Metadata:{ImageID:$image},Results:null}' \
  > "$fixture/base-secret.json"
printf '{"SchemaVersion":2,"ArtifactType":"repository","ArtifactName":".","Results":null}\n' > "$fixture/base-source.json"

passed=0
image_case() {
  local scenario="$1" expected="$2" actual=0
  export SCAN_TEST_SCENARIO="$scenario"
  cp "$fixture/base-vulnerability.json" "$fixture/vulnerability.json"
  cp "$fixture/base-secret.json" "$fixture/secret.json"
  case "$scenario" in
    medium)
      jq '.Results[0].Vulnerabilities=[{VulnerabilityID:"fixture-medium",Severity:"MEDIUM"}]' "$fixture/base-vulnerability.json" > "$fixture/vulnerability.json" ;;
    high-unfixed)
      jq '.Results[0].Vulnerabilities=[{VulnerabilityID:"fixture-high",Severity:"HIGH",Status:"will_not_fix",FixedVersion:""}]' "$fixture/base-vulnerability.json" > "$fixture/vulnerability.json" ;;
    critical)
      jq '.Results[0].Vulnerabilities=[{VulnerabilityID:"fixture-critical",Severity:"CRITICAL",FixedVersion:"2"}]' "$fixture/base-vulnerability.json" > "$fixture/vulnerability.json" ;;
    secret-array) jq '.Results=[]' "$fixture/base-secret.json" > "$fixture/secret.json" ;;
    secret-match)
      jq '.Results=[{Class:"secret",Secrets:[{RuleID:"fixture-rule",Severity:"LOW",Match:"AZADMIN_TEST_MATCH_PRIVATE"}]}]' "$fixture/base-secret.json" > "$fixture/secret.json" ;;
    eol) jq '.Metadata.OS.EOSL=true' "$fixture/base-vulnerability.json" > "$fixture/vulnerability.json" ;;
    no-inventory) jq '.Results=[]' "$fixture/base-vulnerability.json" > "$fixture/vulnerability.json" ;;
    wrong-image) jq '.Metadata.ImageID="sha256:wrong"' "$fixture/base-vulnerability.json" > "$fixture/vulnerability.json" ;;
    wrong-os) jq '.Metadata.OS.Family="unknown"' "$fixture/base-vulnerability.json" > "$fixture/vulnerability.json" ;;
    invalid-json) printf '{\n' > "$fixture/vulnerability.json" ;;
    wrong-schema) jq '.SchemaVersion=999' "$fixture/base-vulnerability.json" > "$fixture/vulnerability.json" ;;
    invalid-secret) printf '{}\n' > "$fixture/secret.json" ;;
  esac
  if bash "$repo_root/scripts/scan-image.sh" admin-toolbox:fixture "$fixture/reports-$scenario" > "$fixture/log-$scenario" 2>&1; then
    actual=0
  else actual=$?
  fi
  if [[ "$expected" == pass ]]; then
    [[ "$actual" == 0 ]] || { printf 'FAIL: %s should pass (exit %s)\n' "$scenario" "$actual"; cat "$fixture/log-$scenario"; exit 1; }
    jq -e 'has("components") and .bomFormat=="CycloneDX"' "$fixture/reports-$scenario/sbom.cdx.json" > /dev/null
  else
    [[ "$actual" != 0 ]] || { printf 'FAIL: %s passed unexpectedly\n' "$scenario"; exit 1; }
  fi
  if grep -RqE 'AZADMIN_TEST_(CONFIG|MATCH)_PRIVATE' "$fixture/reports-$scenario" "$fixture/log-$scenario"; then
    printf 'FAIL: private image configuration or secret match reached retained output\n'; exit 1
  fi
  if [[ "$scenario" == high-unfixed || "$scenario" == critical ]]; then
    jq -e '.blocking_vulnerabilities==1' "$fixture/reports-$scenario/scan-summary.json" > /dev/null
  elif [[ "$scenario" == secret-match ]]; then
    jq -e '.findings==1 and .rules[0].rule=="fixture-rule"' "$fixture/reports-$scenario/secrets-summary.json" > /dev/null
  fi
  passed=$((passed + 1))
  printf 'PASS: image %s\n' "$scenario"
}

for scenario in clean secret-array medium; do image_case "$scenario" pass; done
for scenario in high-unfixed critical secret-match eol no-inventory wrong-image wrong-os invalid-json wrong-schema invalid-secret invalid-sbom vuln-error secret-error convert-error; do
  image_case "$scenario" fail
done

for scenario in source-clean source-array source-secret source-invalid source-wrong-type source-error; do
  export SCAN_TEST_SCENARIO="$scenario"
  cp "$fixture/base-source.json" "$fixture/source.json"
  case "$scenario" in
    source-array) jq '.Results=[]' "$fixture/base-source.json" > "$fixture/source.json" ;;
    source-secret)
      jq '.Results=[{Secrets:[{RuleID:"fixture-source",Match:"AZADMIN_TEST_MATCH_PRIVATE"}]}]' "$fixture/base-source.json" > "$fixture/source.json" ;;
    source-invalid) printf '{}\n' > "$fixture/source.json" ;;
    source-wrong-type) jq '.ArtifactType="container_image"' "$fixture/base-source.json" > "$fixture/source.json" ;;
  esac
  actual=0
  if (cd "$fixture/work" && bash "$repo_root/.github/scripts/scan-source.sh") > "$fixture/log-$scenario" 2>&1; then actual=0; else actual=$?; fi
  if [[ "$scenario" == source-clean || "$scenario" == source-array ]]; then
    [[ "$actual" == 0 ]] || { printf 'FAIL: clean source scan did not pass\n'; exit 1; }
  else
    [[ "$actual" != 0 ]] || { printf 'FAIL: %s passed unexpectedly\n' "$scenario"; exit 1; }
  fi
  if grep -Rq 'AZADMIN_TEST_MATCH_PRIVATE' "$fixture/work/reports" "$fixture/log-$scenario"; then
    printf 'FAIL: source secret match reached retained output\n'; exit 1
  fi
  passed=$((passed + 1))
  printf 'PASS: %s\n' "$scenario"
done
printf 'Scan-policy regression checks passed: %s\n' "$passed"
