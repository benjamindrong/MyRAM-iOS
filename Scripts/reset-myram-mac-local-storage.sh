#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: Scripts/reset-myram-mac-local-storage.sh [--dry-run] [--yes]

Stops MyRAMMac and removes its local SwiftData store, sync state, and external
blob storage. The default mode asks for confirmation; --yes skips the prompt.
EOF
}

dry_run=false
assume_yes=false

while (($# > 0)); do
    case "$1" in
    --dry-run)
        dry_run=true
        ;;
    --yes)
        assume_yes=true
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        printf 'Unknown option: %s\n' "$1" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
done

user_home="${HOME:?HOME is required}"
if [[ "$user_home" != /* || "$user_home" == "/" ]]; then
    printf 'Refusing unsafe home directory: %s\n' "$user_home" >&2
    exit 1
fi

application_support="$user_home/Library/Application Support"
expected_application_support_suffix="/Library/Application Support"
if [[ "$application_support" != *"$expected_application_support_suffix" ]]; then
    printf 'Refusing unexpected Application Support path: %s\n' "$application_support" >&2
    exit 1
fi

store="$application_support/MyRAM_Main.store"
store_wal="$application_support/MyRAM_Main.store-wal"
store_shm="$application_support/MyRAM_Main.store-shm"
sync_state="$application_support/MyRAM"
external_storage="$application_support/.MyRAM_Main_SUPPORT"
targets=(
    "$store"
    "$store_wal"
    "$store_shm"
    "$sync_state"
    "$external_storage"
)

printf 'MyRAMMac local data reset will remove:\n'
printf '  %s\n' "${targets[@]}"

if "$dry_run"; then
    printf 'Dry run only; no process was stopped and no files were removed.\n'
    exit 0
fi

if ! "$assume_yes"; then
    printf 'Type RESET to continue: '
    read -r confirmation
    if [[ "$confirmation" != "RESET" ]]; then
        printf 'Cancelled.\n'
        exit 1
    fi
fi

# Terminating the exact executable releases SwiftData and external-storage files.
pkill -9 -x MyRAMMac 2>/dev/null || true

rm -f "$store" "$store_wal" "$store_shm"
rm -rf "$sync_state" "$external_storage"

remaining=()
for target in "${targets[@]}"; do
    if [[ -e "$target" || -L "$target" ]]; then
        remaining+=("$target")
    fi
done

if ((${#remaining[@]} > 0)); then
    printf 'Reset incomplete; these paths remain:\n' >&2
    printf '  %s\n' "${remaining[@]}" >&2
    exit 1
fi

printf 'MyRAMMac local storage is clean.\n'
