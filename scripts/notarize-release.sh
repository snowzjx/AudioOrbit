#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
package_path="${AUDIOORBIT_PACKAGE_PATH:-${project_root}/build/AudioOrbit.zip}"
app_path="${AUDIOORBIT_APP_PATH:-${project_root}/build/AudioOrbit.xcarchive/Products/Applications/AudioOrbit.app}"

if [[ -z "${AUDIOORBIT_NOTARY_PROFILE:-}" ]]; then
  print -u2 "Set AUDIOORBIT_NOTARY_PROFILE to a notarytool Keychain profile name."
  exit 2
fi

if [[ ! -f "${package_path}" ]]; then
  print -u2 "Package not found: ${package_path}"
  exit 2
fi

xcrun notarytool submit "${package_path}" \
  --keychain-profile "${AUDIOORBIT_NOTARY_PROFILE}" \
  --wait
xcrun stapler staple "${app_path}"
xcrun stapler validate "${app_path}"
spctl --assess --type execute --verbose=2 "${app_path}"

print "Notarization, stapling, and Gatekeeper validation succeeded."
