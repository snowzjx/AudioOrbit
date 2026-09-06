#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
E2E_BUILD_DIR="${AUDIOORBIT_E2E_BUILD_DIR:-/tmp/AudioOrbitE2E}"
E2E_APPS_DIR="${AUDIOORBIT_E2E_APPS_DIR:-$HOME/Applications/AudioOrbit Tests}"
mkdir -p "$E2E_BUILD_DIR"
install_apps() {
    python3 "$REPO_DIR/tools/e2e/install.py" --build-dir "$E2E_BUILD_DIR" --apps-dir "$E2E_APPS_DIR"
}
case "${1:-help}" in
  build)
    DRIVER_APP="$E2E_BUILD_DIR/AudioOrbit E2E Driver.app"
    mkdir -p "$DRIVER_APP/Contents/MacOS"
    cp "$REPO_DIR/tools/e2e/Driver-Info.plist" "$DRIVER_APP/Contents/Info.plist"
    xcrun swiftc -parse-as-library -O -module-cache-path "$E2E_BUILD_DIR/ModuleCache" \
      "$REPO_DIR/tools/e2e/Desktop.swift" "$REPO_DIR/tools/e2e/Fixture.swift" \
      -o "$DRIVER_APP/Contents/MacOS/AudioOrbitE2EDriver"
    codesign --force --sign "${AUDIOORBIT_E2E_SIGN_IDENTITY:--}" "$DRIVER_APP"
    set -- -project "$REPO_DIR/AudioOrbit.xcodeproj" -scheme AudioOrbit
    if [ -n "${AUDIOORBIT_E2E_PACKAGES_DIR:-}" ]; then
      set -- "$@" -clonedSourcePackagesDirPath "$AUDIOORBIT_E2E_PACKAGES_DIR" -disableAutomaticPackageResolution
    fi
    xcodebuild "$@" \
      -configuration Debug -derivedDataPath "$E2E_BUILD_DIR/DerivedData" \
      'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG AUDIOORBIT_E2E' \
      PRODUCT_BUNDLE_IDENTIFIER=me.snowzjx.AudioOrbit.E2E \
      OTHER_CODE_SIGN_FLAGS= CODE_SIGN_IDENTITY="${AUDIOORBIT_E2E_SIGN_IDENTITY:--}" build
    if [ ! -f "$E2E_BUILD_DIR/fixture.mp4" ]; then
      rm -f "$E2E_BUILD_DIR/fixture-building.mp4"
      "$DRIVER_APP/Contents/MacOS/AudioOrbitE2EDriver" generate "$E2E_BUILD_DIR/fixture-building.mp4"
      mv "$E2E_BUILD_DIR/fixture-building.mp4" "$E2E_BUILD_DIR/fixture.mp4"
    fi
    "$DRIVER_APP/Contents/MacOS/AudioOrbitE2EDriver" validate-fixture "$E2E_BUILD_DIR/fixture.mp4"
    install_apps
    ;;
  install)
    install_apps
    ;;
  *)
    exec python3 "$REPO_DIR/tools/e2e/run.py" --build-dir "$E2E_BUILD_DIR" --apps-dir "$E2E_APPS_DIR" "$@"
    ;;
esac
