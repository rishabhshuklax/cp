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

# Ad-hoc signature, with the designated requirement pinned to the bundle id.
#
# This is the difference between granting Accessibility once and granting it
# after every build. TCC remembers the app by its designated requirement, and
# the default ad-hoc requirement is a cdhash — which changes with every byte of
# the binary, so the next build is a different app as far as the system is
# concerned and the grant silently stops applying. Naming the identifier
# instead keeps one identity across rebuilds.
#
# Not --deep: it re-signs nested code that a single-binary bundle does not have,
# and Apple has deprecated it.
echo "==> codesign (ad-hoc, designated requirement pinned to dev.cp.clipboard)"
codesign --force --sign - \
  --requirements '=designated => identifier "dev.cp.clipboard"' \
  "${APP}"

codesign -d -r- "${APP}" 2>&1 | sed -n 's/^designated/    designated/p'
echo "==> built ${APP}"
