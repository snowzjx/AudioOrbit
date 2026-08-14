#!/bin/zsh
set -euo pipefail

script_dir="${0:A:h}"
project_root="${script_dir:h}"
package_path="${AUDIOORBIT_PACKAGE_PATH:-${project_root}/build/AudioOrbit.zip}"
app_path="${AUDIOORBIT_APP_PATH:-${project_root}/build/AudioOrbit.xcarchive/Products/Applications/AudioOrbit.app}"
notary_profile="${AUDIOORBIT_NOTARY_PROFILE:-AudioOrbit-Notary}"

if [[ ! -f "${package_path}" ]]; then
  print -u2 "Package not found: ${package_path}"
  exit 2
fi

xcrun notarytool submit "${package_path}" \
  --keychain-profile "${notary_profile}" \
  --wait \
  --output-format json > "${project_root}/build/notary-result.json"

submission_id="$(jq -r '.id' "${project_root}/build/notary-result.json")"
status="$(jq -r '.status' "${project_root}/build/notary-result.json")"
cat "${project_root}/build/notary-result.json"

if [[ "${status}" != "Accepted" ]]; then
  xcrun notarytool log "${submission_id}" \
    --keychain-profile "${notary_profile}" || true
  exit 1
fi

xcrun stapler staple "${app_path}"
xcrun stapler validate "${app_path}"
spctl --assess --type execute --verbose=2 "${app_path}"

# Recreate the public ZIP after stapling so the distributed app carries the ticket.
rm -f "${package_path}" "${package_path}.sha256"
ditto -c -k --keepParent "${app_path}" "${package_path}"
shasum -a 256 "${package_path}" > "${package_path}.sha256"

print "Notarization, stapling, Gatekeeper validation, and final packaging succeeded."
