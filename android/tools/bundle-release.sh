#!/bin/zsh
# Builds the signed Play bundle (app/build/outputs/bundle/release/app-release.aab).
# The upload key is ~/.android-keys/bitecurve/upload.jks; its password is in the macOS
# Keychain item "android-upload-key-bitecurve". Neither is ever committed.
set -e
cd "$(dirname "$0")/.."
export BITECURVE_UPLOAD_KEYSTORE="$HOME/.android-keys/bitecurve/upload.jks"
export BITECURVE_UPLOAD_PASSWORD="$(security find-generic-password -s android-upload-key-bitecurve -w)"
./gradlew --no-daemon clean bundleRelease
