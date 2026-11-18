#!/usr/bin/env bash
set -euo pipefail

image="${1:?Usage: test-image.sh IMAGE PROFILE [REPORT_DIR]}"
profile="${2:?Choose core, dotnet or functions}"
report_dir="${3:-reports/${profile}}"
case "$profile" in core|dotnet|functions) ;; *) printf 'Unknown profile\n' >&2; exit 2 ;; esac
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$report_dir"
image_id="$(docker image inspect "$image" --format '{{.Id}}')"
[[ "$image_id" =~ ^sha256:[0-9a-f]{64}$ ]] || exit 2
printf '%s\n' "$image_id" > "$report_dir/image-id.txt"
docker image inspect "$image_id" --format '{{json .}}' | jq \
  '{Id,Os,Architecture,Size,Created,Labels:{source:.Config.Labels["org.opencontainers.image.source"],revision:.Config.Labels["org.opencontainers.image.revision"]}}' \
  > "$report_dir/image-metadata.json"

# ping's Ubuntu file capability needs NET_RAW even for its version flag.
# No external packet path, host credentials, engine socket or writable repo is supplied.
docker run --rm --network none --cap-drop ALL --cap-add NET_RAW \
  --security-opt no-new-privileges:true \
  --mount "type=bind,source=${repo_root},target=/work,readonly" \
  --workdir /work "$image_id" \
  pwsh -NoProfile -File /work/scripts/Verify-Toolbox.ps1 -ExpectedProfile "$profile" \
  > "$report_dir/verify.log" 2>&1 || {
    cat "$report_dir/verify.log"
    exit 1
  }
cat "$report_dir/verify.log"

docker run --rm --network none --cap-drop ALL --cap-add NET_RAW \
  --security-opt no-new-privileges:true \
  --mount "type=bind,source=${repo_root},target=/work,readonly" \
  --workdir /work "$image_id" \
  pwsh -NoProfile -File /work/scripts/Test-VerifyToolbox.ps1 \
  > "$report_dir/verify-regression.log" 2>&1 || {
    cat "$report_dir/verify-regression.log"
    exit 1
  }
cat "$report_dir/verify-regression.log"
