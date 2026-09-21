#!/usr/bin/env bash
#
# Assembles Sources/ into a runnable cp.app.
#
# SwiftPM builds a bare Mach-O; a menu-bar app needs a bundle so that LSUIElement
# applies, the Accessibility prompt shows a real app name, and TCC can remember
# the grant across launches. Running the raw binary works but re-prompts every
# time, because an unbundled executable has no stable identity to grant.
set -euo pipefail

CONFIGURATION="${1:-release}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${ROOT}/build/cp.app"

echo "==> swift build -c ${CONFIGURATION}"
swift build -c "${CONFIGURATION}" --package-path "${ROOT}"

BINARY="$(swift build -c "${CONFIGURATION}" --package-path "${ROOT}" --show-bin-path)/cp"
if [[ ! -x "${BINARY}" ]]; then
  echo "error: built binary not found at ${BINARY}" >&2
  exit 1
fi

echo "==> assembling ${APP}"
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"

cp "${BINARY}" "${APP}/Contents/MacOS/cp"
cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"

# Ad-hoc signature. Enough for TCC to keep the Accessibility grant between
# launches on the machine that built it; a real distribution needs a Developer ID
# signature and notarisation.
echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "${APP}"

echo "==> built ${APP}"
