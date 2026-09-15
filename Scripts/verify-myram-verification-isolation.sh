#!/bin/bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
repo_parent="$(dirname "$repo_root")"
candidate_sha="$(git -C "$repo_root" rev-parse HEAD)"
status_before="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)"

placeholder="$(mktemp -d "$repo_parent/.myram-verification-audit.XXXXXX")"
rmdir "$placeholder"
worktree_path="$placeholder"
manifest_path="$(mktemp "${TMPDIR:-/tmp}/myram-verification-identity.XXXXXX.json")"

cleanup() {
  git -C "$repo_root" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
  rm -f "$manifest_path"
}
trap cleanup EXIT

git -C "$repo_root" worktree add --detach "$worktree_path" "$candidate_sha" >/dev/null
python3 "$worktree_path/Scripts/configure-myram-verification.py" \
  --root "$worktree_path" \
  --manifest-output "$manifest_path" \
  >/dev/null

git -C "$worktree_path" diff --check

status_after="$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)"
if [[ "$status_before" != "$status_after" ]]; then
  echo "Primary checkout changed while generating Verification worktree." >&2
  diff <(printf '%s\n' "$status_before") <(printf '%s\n' "$status_after") || true
  exit 1
fi

python3 - "$manifest_path" <<'PY'
import json
import sys
from pathlib import Path

report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))

assert report["environment"] == "verification"
assert report["application_identifiers"]["verification_ios"] not in report["application_identifiers"]["production_ios"]
assert report["application_identifiers"]["verification_macos"] not in report["application_identifiers"]["production_macos"]
assert report["app_groups"]["verification_ios"] not in report["app_groups"]["production_ios"]
assert report["app_groups"]["verification_macos"] not in report["app_groups"]["production_macos"]
assert report["storage"]["verification_root"] != report["storage"]["production_root"]
assert report["storage"]["verification_swiftdata_store"] != report["storage"]["production_swiftdata_store"]
assert report["multipeer"]["verification_service_type"] != report["multipeer"]["production_service_type"]
assert report["deep_links"]["verification_ios"] != report["deep_links"]["production_ios"]
assert report["deep_links"]["verification_macos"] != report["deep_links"]["production_macos"]

print("MYR-221 isolated Verification configuration: PASS")
print(f"source candidate: {report['source_candidate_sha']}")
print(
    "application IDs: "
    f"iOS={report['application_identifiers']['verification_ios']} "
    f"macOS={report['application_identifiers']['verification_macos']}"
)
print(
    "storage: "
    f"root={report['storage']['verification_root']} "
    f"SwiftData={report['storage']['verification_swiftdata_store']}"
)
print(
    "Multipeer: "
    f"service={report['multipeer']['verification_service_type']} "
    f"Bonjour={report['multipeer']['verification_bonjour_service']}"
)
print("primary checkout unchanged: PASS")
PY
