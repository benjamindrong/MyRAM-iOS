#!/bin/bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash Scripts/create-myram-verification-worktree.sh [--path PATH]

Creates a detached sibling worktree at the current candidate HEAD and converts
only that disposable checkout into the isolated "MyRAM Verification" variant.
The primary checkout is never modified.

Default PATH:
  <repo-parent>/MyRAM-iOS-Verification-<short-sha>
EOF
}

requested_path=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --path)
      [[ $# -ge 2 ]] || { echo "Missing value for --path" >&2; exit 2; }
      requested_path="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
candidate_sha="$(git -C "$repo_root" rev-parse HEAD)"
short_sha="${candidate_sha:0:12}"
repo_parent="$(dirname "$repo_root")"
worktree_path="${requested_path:-$repo_parent/MyRAM-iOS-Verification-$short_sha}"

case "$worktree_path" in
  "$repo_root"|"$repo_root/"*)
    echo "Refusing to create Verification inside the primary checkout." >&2
    exit 1
    ;;
esac

if [[ -e "$worktree_path" ]]; then
  echo "Refusing to reuse existing path: $worktree_path" >&2
  exit 1
fi

cleanup_on_error() {
  local status=$?
  if [[ $status -ne 0 ]]; then
    git -C "$repo_root" worktree remove --force "$worktree_path" >/dev/null 2>&1 || true
  fi
  exit "$status"
}
trap cleanup_on_error EXIT

git -C "$repo_root" worktree add --detach "$worktree_path" "$candidate_sha"
python3 "$worktree_path/Scripts/configure-myram-verification.py" \
  --root "$worktree_path" \
  --manifest-output "$worktree_path/MYR-221-VERIFICATION-IDENTITY.json"

trap - EXIT

cat <<EOF
MYR-221 Verification worktree prepared.
Source candidate: $candidate_sha
Worktree: $worktree_path
Installed app name: MyRAM Verification
iOS scheme to build: MyRAM
macOS scheme to build: MyRAMMac

This worktree intentionally contains only deterministic environmental identity
changes. Do not commit them. Remove it when the physical campaign is complete:
  git -C "$repo_root" worktree remove --force "$worktree_path"
EOF
