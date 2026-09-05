#!/bin/bash
set -euo pipefail

EXPECTED_BRANCH="BEN-36-MyRAM-sync-endurance-harness"
DURATION_SECONDS="${MYRAM_DURATION_SECONDS:-720}"
RUN_ID="${MYRAM_RUN_ID:-BEN36-$(date -u +%Y%m%dT%H%M%SZ)}"
EXPECTED_HEAD="${MYRAM_EXPECTED_HEAD:-}"
REQUESTED_DEVICE_ID="${MYRAM_DEVICE_ID:-}"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$ROOT" ]] || { echo "ERROR: run inside the MyRAM-iOS repository" >&2; exit 2; }
cd "$ROOT"

EVIDENCE_ROOT="$ROOT/.local-completion/BEN-36-sync-endurance/$RUN_ID"
DERIVED_DATA="$EVIDENCE_ROOT/DerivedData"
LOG_DIR="$EVIDENCE_ROOT/logs"
IOS_EVIDENCE="$EVIDENCE_ROOT/iOS"
MAC_EVIDENCE="$EVIDENCE_ROOT/macOS"
VALIDATION_DIR="$EVIDENCE_ROOT/validation"
DEVICE_JSON="$EVIDENCE_ROOT/devices.json"
IOS_LAUNCH_JSON="$EVIDENCE_ROOT/ios-launch.json"
IOS_POLL_RESULT="$EVIDENCE_ROOT/ios-result-poll.json"
STATE_FILE="$EVIDENCE_ROOT/state.txt"
MAC_PID=""
IOS_PID=""
IOS_BUNDLE_ID=""
DEVICE_ID=""

fail() {
  echo "ERROR: $*" >&2
  printf 'failed\n' > "$STATE_FILE" 2>/dev/null || true
  exit 1
}

record_stage() {
  printf '%s\n' "$1" > "$STATE_FILE"
  printf '[BEN-36] %s\n' "$1"
}

cleanup() {
  set +e
  if [[ -n "$MAC_PID" ]] && kill -0 "$MAC_PID" 2>/dev/null; then
    kill "$MAC_PID" 2>/dev/null || true
    wait "$MAC_PID" 2>/dev/null || true
  fi
  if [[ -n "$DEVICE_ID" && -n "$IOS_PID" ]]; then
    xcrun devicectl device process terminate --device "$DEVICE_ID" --pid "$IOS_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

mkdir -p "$EVIDENCE_ROOT" "$DERIVED_DATA" "$LOG_DIR" "$IOS_EVIDENCE" "$MAC_EVIDENCE" "$VALIDATION_DIR"

record_stage preflight
[[ -n "$EXPECTED_HEAD" ]] || fail "set MYRAM_EXPECTED_HEAD to the exact reviewed PR head before running"
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]+$ ]] || fail "MYRAM_RUN_ID may contain only letters, numbers, dot, underscore, and hyphen"
[[ "$DURATION_SECONDS" =~ ^[0-9]+$ ]] || fail "MYRAM_DURATION_SECONDS must be an integer"
(( DURATION_SECONDS >= 300 && DURATION_SECONDS <= 900 )) || fail "duration must be between 300 and 900 seconds"

for command in git xcodebuild xcrun python3 shasum /usr/libexec/PlistBuddy; do
  command -v "$command" >/dev/null 2>&1 || fail "required command not found: $command"
done

CURRENT_BRANCH="$(git branch --show-current)"
CURRENT_HEAD="$(git rev-parse HEAD)"
[[ "$CURRENT_BRANCH" == "$EXPECTED_BRANCH" ]] || fail "expected branch $EXPECTED_BRANCH, found $CURRENT_BRANCH"
[[ "$CURRENT_HEAD" == "$EXPECTED_HEAD" ]] || fail "expected head $EXPECTED_HEAD, found $CURRENT_HEAD"
[[ -z "$(git status --porcelain)" ]] || fail "working tree must be clean"
python3 -m py_compile Scripts/ben36_validate_endurance.py

git diff --check "$EXPECTED_HEAD^" "$EXPECTED_HEAD" > "$LOG_DIR/git-diff-check.txt" 2>&1 || fail "git diff --check failed"
xcodebuild -version > "$LOG_DIR/xcode-version.txt"
xcrun devicectl --version > "$LOG_DIR/devicectl-version.txt" 2>&1 || true

record_stage resolve-device
xcrun devicectl list devices --json-output "$DEVICE_JSON" > "$LOG_DIR/devicectl-list.txt" 2>&1 || fail "devicectl could not list devices"
DEVICE_ID="$(python3 - "$DEVICE_JSON" "$REQUESTED_DEVICE_ID" <<'PY'
import json, sys
path, requested = sys.argv[1], sys.argv[2]
obj = json.load(open(path, encoding='utf-8'))
devices = obj.get('result', {}).get('devices', [])

def value(d, *paths):
    for path in paths:
        cur = d
        ok = True
        for part in path.split('.'):
            if not isinstance(cur, dict) or part not in cur:
                ok = False; break
            cur = cur[part]
        if ok and cur not in (None, ''):
            return cur
    return None

candidates = []
for d in devices:
    if not isinstance(d, dict):
        continue
    identifier = str(d.get('identifier', ''))
    name = str(value(d, 'properties.name', 'deviceProperties.name') or 'unknown')
    platform = str(value(d, 'properties.platform', 'hardwareProperties.platform') or '')
    product = str(value(d, 'properties.productType', 'hardwareProperties.productType') or '')
    tunnel = str(value(d, 'properties.tunnelState', 'connectionProperties.tunnelState') or '')
    pairing = str(value(d, 'properties.pairingState', 'connectionProperties.pairingState') or '')
    looks_ios = 'ios' in platform.lower() or product.lower().startswith('iphone')
    available = tunnel in ('connected', 'available', '') and pairing in ('paired', '')
    if looks_ios and available and identifier:
        candidates.append((identifier, name))

if requested:
    matches = [item for item in candidates if item[0] == requested or item[1] == requested]
    if len(matches) != 1:
        print('')
        sys.exit(3)
    print(matches[0][0])
    sys.exit(0)

if len(candidates) != 1:
    print('')
    sys.exit(4)
print(candidates[0][0])
PY
)" || fail "could not resolve exactly one available physical iPhone; set MYRAM_DEVICE_ID if multiple devices are present"
[[ -n "$DEVICE_ID" ]] || fail "no available physical iPhone resolved"
printf '%s\n' "$DEVICE_ID" > "$EVIDENCE_ROOT/device-id.txt"

record_stage build
xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAM \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  build > "$LOG_DIR/xcodebuild-ios.log" 2>&1 || fail "iOS Debug build failed"

xcodebuild \
  -project MyRAM.xcodeproj \
  -scheme MyRAMMac \
  -configuration Debug \
  -destination "platform=macOS" \
  -derivedDataPath "$DERIVED_DATA" \
  build > "$LOG_DIR/xcodebuild-macos.log" 2>&1 || fail "macOS Debug build failed"

IOS_APP="$(find "$DERIVED_DATA/Build/Products" -type d -path '*/Debug-iphoneos/MyRAM.app' -print -quit)"
MAC_APP="$(find "$DERIVED_DATA/Build/Products" -type d -path '*/Debug/MyRAMMac.app' -print -quit)"
[[ -d "$IOS_APP" ]] || fail "built iOS app not found"
[[ -d "$MAC_APP" ]] || fail "built macOS app not found"
IOS_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$IOS_APP/Info.plist")"
MAC_EXECUTABLE="$MAC_APP/Contents/MacOS/MyRAMMac"
[[ -x "$MAC_EXECUTABLE" ]] || fail "built macOS executable not found"

record_stage install
xcrun devicectl device install app --device "$DEVICE_ID" "$IOS_APP" > "$LOG_DIR/devicectl-install.txt" 2>&1 || fail "iOS app installation failed; unlock the device and verify Developer Mode"

BENCH_ENV_JSON="$(python3 - "$RUN_ID" "$DURATION_SECONDS" <<'PY'
import json, sys
print(json.dumps({
    'MYRAM_SYNC_BENCHMARK_LOGGING': '1',
    'MYRAM_SYNC_BENCHMARK_RUN_ID': sys.argv[1],
    'MYRAM_SYNC_BENCHMARK_ENDURANCE': '1',
    'MYRAM_SYNC_BENCHMARK_ENDURANCE_SECONDS': sys.argv[2],
}, separators=(',', ':')))
PY
)"

MAC_RUN_ROOT="$HOME/Library/MyRAMSyncEndurance/$RUN_ID/Home/Library/Application Support/MyRAM/SyncBenchmarks"
MAC_RESULT_PATH="$MAC_RUN_ROOT/Endurance/$RUN_ID/endurance-result-macOS.json"
IOS_BENCH_REL="Library/MyRAMSyncEndurance/$RUN_ID/Home/Library/Application Support/MyRAM/SyncBenchmarks"
IOS_RESULT_REL="$IOS_BENCH_REL/Endurance/$RUN_ID/endurance-result-iOS.json"

record_stage launch
(
  export MYRAM_SYNC_BENCHMARK_LOGGING=1
  export MYRAM_SYNC_BENCHMARK_RUN_ID="$RUN_ID"
  export MYRAM_SYNC_BENCHMARK_ENDURANCE=1
  export MYRAM_SYNC_BENCHMARK_ENDURANCE_SECONDS="$DURATION_SECONDS"
  exec "$MAC_EXECUTABLE" UITEST_MODE
) > "$LOG_DIR/macos-app.log" 2>&1 &
MAC_PID=$!

xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  --terminate-existing \
  --environment-variables "$BENCH_ENV_JSON" \
  --json-output "$IOS_LAUNCH_JSON" \
  "$IOS_BUNDLE_ID" -- UITEST_MODE > "$LOG_DIR/devicectl-launch.txt" 2>&1 || fail "iOS endurance app launch failed"

IOS_PID="$(python3 - "$IOS_LAUNCH_JSON" <<'PY'
import json, sys
obj = json.load(open(sys.argv[1], encoding='utf-8'))
found = []
def walk(v):
    if isinstance(v, dict):
        for k, value in v.items():
            if k == 'processIdentifier' and isinstance(value, int):
                found.append(value)
            walk(value)
    elif isinstance(v, list):
        for value in v:
            walk(value)
walk(obj)
print(found[0] if found else '')
PY
)"
[[ -n "$IOS_PID" ]] || fail "devicectl launch succeeded but did not report the iOS process identifier"

record_stage workload
START_EPOCH="$(date +%s)"
DEADLINE=$(( START_EPOCH + DURATION_SECONDS + 210 ))
while true; do
  MAC_READY=0
  IOS_READY=0
  [[ -s "$MAC_RESULT_PATH" ]] && MAC_READY=1
  rm -f "$IOS_POLL_RESULT"
  if xcrun devicectl device copy from \
      --device "$DEVICE_ID" \
      --domain-type appDataContainer \
      --domain-identifier "$IOS_BUNDLE_ID" \
      --source "$IOS_RESULT_REL" \
      --destination "$IOS_POLL_RESULT" >/dev/null 2>&1; then
    [[ -s "$IOS_POLL_RESULT" ]] && IOS_READY=1
  fi
  if (( MAC_READY == 1 && IOS_READY == 1 )); then
    break
  fi
  NOW="$(date +%s)"
  (( NOW < DEADLINE )) || fail "endurance run timed out before both platform results were produced"
  if [[ -n "$MAC_PID" ]] && ! kill -0 "$MAC_PID" 2>/dev/null; then
    fail "macOS endurance app exited before producing its result"
  fi
  sleep 5
done

record_stage collect
xcrun devicectl device process terminate --device "$DEVICE_ID" --pid "$IOS_PID" > "$LOG_DIR/devicectl-terminate.txt" 2>&1 || true
IOS_PID=""
if kill -0 "$MAC_PID" 2>/dev/null; then
  kill "$MAC_PID" 2>/dev/null || true
  wait "$MAC_PID" 2>/dev/null || true
fi
MAC_PID=""

mkdir -p "$IOS_EVIDENCE/SyncBenchmarks" "$MAC_EVIDENCE"
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$IOS_BUNDLE_ID" \
  --source "$IOS_BENCH_REL" \
  --destination "$IOS_EVIDENCE/SyncBenchmarks" > "$LOG_DIR/devicectl-copy-evidence.txt" 2>&1 || fail "could not copy the isolated iOS benchmark evidence directory"

[[ -d "$MAC_RUN_ROOT" ]] || fail "isolated macOS benchmark evidence directory is missing"
cp -R "$MAC_RUN_ROOT" "$MAC_EVIDENCE/SyncBenchmarks"

find_one() {
  local root="$1"
  local pattern="$2"
  local matches
  matches="$(find "$root" -type f -name "$pattern" -print)"
  local count
  count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"
  [[ "$count" == "1" ]] || fail "expected exactly one $pattern under $root; found $count"
  printf '%s\n' "$matches"
}

IOS_RESULT="$(find_one "$IOS_EVIDENCE" 'endurance-result-iOS.json')"
MAC_RESULT="$(find_one "$MAC_EVIDENCE" 'endurance-result-macOS.json')"
IOS_CONTROL="$(find_one "$IOS_EVIDENCE" 'endurance-control-iOS.jsonl')"
MAC_CONTROL="$(find_one "$MAC_EVIDENCE" 'endurance-control-macOS.jsonl')"
IOS_TELEMETRY="$(find_one "$IOS_EVIDENCE" 'sync-benchmark-iOS-*.jsonl')"
MAC_TELEMETRY="$(find_one "$MAC_EVIDENCE" 'sync-benchmark-macOS-*.jsonl')"

record_stage validate
VALIDATION_JSON="$VALIDATION_DIR/endurance-validation.json"
python3 Scripts/ben36_validate_endurance.py \
  --run-id "$RUN_ID" \
  --ios-result "$IOS_RESULT" \
  --mac-result "$MAC_RESULT" \
  --ios-control "$IOS_CONTROL" \
  --mac-control "$MAC_CONTROL" \
  --ios-telemetry "$IOS_TELEMETRY" \
  --mac-telemetry "$MAC_TELEMETRY" \
  --output "$VALIDATION_JSON" > "$LOG_DIR/validator.txt" 2>&1 || {
    cat "$LOG_DIR/validator.txt" >&2
    fail "deterministic cross-device validation failed"
  }

python3 - "$EVIDENCE_ROOT/metadata.json" "$RUN_ID" "$DURATION_SECONDS" "$CURRENT_HEAD" "$DEVICE_ID" "$IOS_BUNDLE_ID" <<'PY'
import json, platform, sys
out, run_id, duration, head, device, bundle = sys.argv[1:]
metadata = {
    'schemaVersion': 1,
    'runID': run_id,
    'durationSeconds': int(duration),
    'gitHead': head,
    'deviceIdentifier': device,
    'iOSBundleIdentifier': bundle,
    'host': platform.platform(),
}
open(out, 'w', encoding='utf-8').write(json.dumps(metadata, indent=2, sort_keys=True) + '\n')
PY

find "$IOS_EVIDENCE" "$MAC_EVIDENCE" "$VALIDATION_DIR" -type f -print0 \
  | sort -z \
  | xargs -0 shasum -a 256 > "$EVIDENCE_ROOT/SHA256SUMS.txt"

record_stage complete
trap - EXIT INT TERM
printf '\nBEN-36 endurance run passed.\nRun ID: %s\nEvidence: %s\nValidation: %s\n' "$RUN_ID" "$EVIDENCE_ROOT" "$VALIDATION_JSON"
