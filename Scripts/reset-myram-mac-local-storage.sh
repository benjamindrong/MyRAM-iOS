#!/usr/bin/env bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: Scripts/reset-myram-mac-local-storage.sh <debug|release> [--dry-run] [--yes]

Stops only the selected MyRAMMac build and removes that configuration's local
SwiftData store, external blob storage, and widget snapshot.

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
        app_bundle_identifier="com.northsignalstudio.myram.mac.dev"
        app_group_identifier="group.com.northsignalstudio.myram.mac.dev.widget"
        expected_confirmation="RESET DEBUG"
        ;;
    release)
        app_bundle_identifier="com.northsignalstudio.myram.mac"
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
widget_snapshot="$application_support/MyRAMWidget/widget-snapshot-v1.json"
targets=(
    "$store"
    "$store_wal"
    "$store_shm"
    "$external_storage"
    "$widget_snapshot"
)

app_control_override="${MYRAMMAC_APP_CONTROL_COMMAND:-}"

run_app_control() {
    local action="$1"

    if [[ -n "$app_control_override" ]]; then
        "$app_control_override" "$app_bundle_identifier" "$action"
        return
    fi

    /usr/bin/osascript -l JavaScript - "$app_bundle_identifier" "$action" <<'JXA'
ObjC.import('AppKit');

function run(argv) {
    const bundleIdentifier = argv[0];
    const action = argv[1];
    const applications = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(bundleIdentifier);
    const count = Number(ObjC.unwrap(applications.count));

    if (action === 'count') {
        return String(count);
    }

    for (let index = 0; index < count; index += 1) {
        const application = applications.objectAtIndex(index);
        if (action === 'terminate') {
            application.terminate;
        } else if (action === 'force-terminate') {
            application.forceTerminate;
        } else {
            throw new Error('Unsupported app-control action: ' + action);
        }
    }

    return '';
}
JXA
}

selected_app_count() {
    local count
    if ! count="$(run_app_control count)"; then
        printf 'Unable to inspect running %s instances. Refusing reset.\n' "$configuration" >&2
        return 1
    fi

    case "$count" in
        '' | *[!0-9]*)
            printf 'Unexpected app-control response: %s\n' "$count" >&2
            return 1
            ;;
    esac

    printf '%s\n' "$count"
}

wait_for_selected_app_exit() {
    local attempt count
    for attempt in 1 2 3 4 5; do
        count="$(selected_app_count)" || return 1
        if [[ "$count" == "0" ]]; then
            return 0
        fi
        /bin/sleep 1
    done

    count="$(selected_app_count)" || return 1
    [[ "$count" == "0" ]]
}

stop_selected_app() {
    local count
    count="$(selected_app_count)" || return 1
    if [[ "$count" == "0" ]]; then
        return 0
    fi

    printf 'Stopping MyRAMMac %s (%s)...\n' "$configuration" "$app_bundle_identifier"
    if ! run_app_control terminate >/dev/null; then
        printf 'Unable to request normal termination for MyRAMMac %s. Refusing reset.\n' "$configuration" >&2
        return 1
    fi
    if wait_for_selected_app_exit; then
        return 0
    fi

    printf 'MyRAMMac %s is still running; requesting force termination...\n' "$configuration"
    if ! run_app_control force-terminate >/dev/null; then
        printf 'Unable to force-terminate MyRAMMac %s. Refusing reset.\n' "$configuration" >&2
        return 1
    fi
    if wait_for_selected_app_exit; then
        return 0
    fi

    printf 'MyRAMMac %s is still running. Refusing to delete local data.\n' "$configuration" >&2
    return 1
}

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

stop_selected_app

rm -f -- "$store" "$store_wal" "$store_shm" "$widget_snapshot"
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
