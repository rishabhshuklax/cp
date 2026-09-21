#!/usr/bin/env bash
#
# Quits a running cp and waits until it has really gone.
#
#     Scripts/quit.sh "build/cp.app/Contents/MacOS/cp"
#
# Matched by bundle path, never by name: `pkill -x cp` would also kill whatever
# /bin/cp happens to be copying at the time. And it waits, because `open` on a
# bundle whose old process is still being torn down fails with error -600.
set -euo pipefail

PATTERN="${1:?usage: quit.sh <path fragment of the running binary>}"

pkill -f "${PATTERN}" 2>/dev/null || exit 0
for _ in $(seq 1 50); do
  pgrep -f "${PATTERN}" >/dev/null 2>&1 || break
  sleep 0.1
done
# One beat more for LaunchServices to notice.
sleep 0.3
