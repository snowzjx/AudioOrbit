#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
archive_path="${AUDIOORBIT_ARCHIVE_PATH:-${project_root}/build/AudioOrbit.xcarchive}"
output_directory="${AUDIOORBIT_OUTPUT_DIRECTORY:-${project_root}/build}"
team_id="${AUDIOORBIT_TEAM_ID:-A47Y4XPLXR}"
version="${AUDIOORBIT_VERSION:-0.3.1}"

mkdir -p "${output_directory}"

xcodebuild archive \
  -project "${project_root}/AudioOrbit.xcodeproj" \
  -scheme AudioOrbit \
  -configuration Release \
  -archivePath "${archive_path}" \
  DEVELOPMENT_TEAM="${team_id}" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  ENABLE_HARDENED_RUNTIME=YES \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  MARKETING_VERSION="${version}" \
  clean archive

app_path="${archive_path}/Products/Applications/AudioOrbit.app"
package_path="${output_directory}/AudioOrbit.zip"

codesign --verify --deep --strict --verbose=2 "${app_path}"
codesign -dvv "${app_path}"
ditto -c -k --keepParent "${app_path}" "${package_path}"
shasum -a 256 "${package_path}" > "${package_path}.sha256"

print "Created ${package_path} and ${package_path}.sha256"
