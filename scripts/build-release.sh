#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
archive_path="${AUDIOORBIT_ARCHIVE_PATH:-${project_root}/build/AudioOrbit.xcarchive}"
output_directory="${AUDIOORBIT_OUTPUT_DIRECTORY:-${project_root}/build}"

if [[ -z "${AUDIOORBIT_TEAM_ID:-}" ]]; then
  print -u2 "Set AUDIOORBIT_TEAM_ID to the Apple Developer Team ID used for distribution."
  exit 2
fi

mkdir -p "${output_directory}"

xcodebuild archive \
  -project "${project_root}/AudioOrbit.xcodeproj" \
  -scheme AudioOrbit \
  -configuration Release \
  -archivePath "${archive_path}" \
  DEVELOPMENT_TEAM="${AUDIOORBIT_TEAM_ID}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  clean archive

app_path="${archive_path}/Products/Applications/AudioOrbit.app"
package_path="${output_directory}/AudioOrbit.zip"

codesign --verify --deep --strict --verbose=2 "${app_path}"
ditto -c -k --keepParent "${app_path}" "${package_path}"

print "Created ${package_path}"
