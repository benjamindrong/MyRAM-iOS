#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Scripts/reset-myram-mac-local-storage.sh <debug|release> [--dry-run] [--yes]

Stops MyRAMMac and removes only the selected build configuration's local
SwiftData store and external blob storage.

Required parameter:
  debug       Reset only the Debug app-group data.
  release     Reset only the Release app-group data.

Options:
  --dry-run   Print the selected paths without stopping the app or deleting data.
  --yes       Skip the interactive confirmation.
  -h, --help  Show this help text.

The shared sync-state directory at ~/Library/Application Support/MyRAM is not
removed because it is not separated by Debug and Release configuration.
USAGE
}

if (($# == 0)); then
    printf 'Missing required configuration parameter.\n\n' >&2
    usage >&2
    exit 2
fi

configuration="$1"
shift

case "$configuration" in
    debug)
        app_group_identifier="group.com.northsignalstudio.myram.mac.dev.widget"
        expected_confirmation="RESET DEBUG"
        ;;
    release)
        app_group_identifier="group.com.northsignalstudio.myram.mac.widget"
        expected_confirmation="RESET RELEASE"
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        printf 'Invalid configuration: %s\n\n' "$configuration" >&2
        usage >&2
        exit 2
        ;;
esac

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
            printf 'Unknown option: %s\n\n' "$1" >&2
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

group_containers="$user_home/Library/Group Containers"
group_container="$group_containers/$app_group_identifier"
application_support="$group_container/Library/Application Support"

case "$group_container" in
    "$group_containers/group.com.northsignalstudio.myram.mac.dev.widget" | \
    "$group_containers/group.com.northsignalstudio.myram.mac.widget")
        ;;
    *)
        printf 'Refusing unexpected app-group container: %s\n' "$group_container" >&2
        exit 1
        ;;
esac

store="$application_support/MyRAM_Main.store"
store_wal="$application_support/MyRAM_Main.store-wal"
store_shm="$application_support/MyRAM_Main.store-shm"
external_storage="$application_support/.MyRAM_Main_SUPPORT"
targets=(
    "$store"
    "$store_wal"
    "$store_shm"
    "$external_storage"
)

printf 'MyRAMMac %s local data reset will remove:\n' "$configuration"
printf '  %s\n' "${targets[@]}"

if "$dry_run"; then
    printf 'Dry run only; no process was stopped and no files were removed.\n'
    exit 0
fi

if ! "$assume_yes"; then
    printf 'Type %s to continue: ' "$expected_confirmation"
    read -r confirmation
    if [[ "$confirmation" != "$expected_confirmation" ]]; then
        printf 'Cancelled.\n'
        exit 1
    fi
fi

# Closing the executable releases SwiftData and external-storage files.
pkill -9 -x MyRAMMac 2>/dev/null || true

rm -f -- "$store" "$store_wal" "$store_shm"
rm -rf -- "$external_storage"

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

printf 'MyRAMMac %s local storage is clean.\n' "$configuration"
