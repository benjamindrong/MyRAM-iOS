#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SPIKE_DIR="${SCRIPT_DIR:h}"
APP_DIR="${SPIKE_DIR}/.build/MyRAMMacEditorSpike.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"

cd "${SPIKE_DIR}"
swift build

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}"

# Launching as an app bundle gives AppKit normal window/menu activation behavior.
ditto ".build/debug/MyRAMMacEditorSpike" "${MACOS_DIR}/MyRAMMacEditorSpike"
ditto "Resources/MyRAMMacEditorSpike-Info.plist" "${CONTENTS_DIR}/Info.plist"

open "${APP_DIR}"
