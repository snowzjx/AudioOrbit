#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
duration="${1:-5m}"
output_path="${AUDIOORBIT_TRACE_PATH:-${project_root}/build/AudioOrbit-Time-Profiler.trace}"

mkdir -p "${output_path:h}"

if ! pgrep -x AudioOrbit >/dev/null; then
  print -u2 "Start AudioOrbit and create the routes to measure before running this script."
  exit 2
fi

xcrun xctrace record \
  --template "Time Profiler" \
  --attach AudioOrbit \
  --time-limit "${duration}" \
  --output "${output_path}"

print "Created ${output_path}"
