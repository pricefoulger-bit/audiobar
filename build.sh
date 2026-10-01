#!/bin/bash
# Rebuild AudioBar.app with swiftc. Requires Xcode Command Line Tools on macOS 14+.
# Swift 5 language mode avoids Swift 6 strict-concurrency errors on 6.1 / 6.2 toolchains.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="AudioBar"
BUILD_DIR="${ROOT}/build"
APP="${BUILD_DIR}/${APP_NAME}.app"
CONTENTS="${APP}/Contents"
MACOS="${CONTENTS}/MacOS"

rm -rf "${APP}"
mkdir -p "${MACOS}"

cp "${ROOT}/Support/Info.plist" "${CONTENTS}/Info.plist"
printf 'APPL????' > "${CONTENTS}/PkgInfo"

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
case "${ARCH}" in
  arm64) TARGET="arm64-apple-macos14.0" ;;
  x86_64) TARGET="x86_64-apple-macos14.0" ;;
  *)
    echo "Unsupported architecture: ${ARCH}" >&2
    exit 1
    ;;
esac

swiftc \
  -swift-version 5 \
  -O \
  -target "${TARGET}" \
  -sdk "${SDK}" \
  -framework Foundation \
  -framework AppKit \
  -framework CoreAudio \
  -framework AudioToolbox \
  -framework ServiceManagement \
  -framework IOBluetooth \
  -framework Network \
  -o "${MACOS}/${APP_NAME}" \
  "${ROOT}/Sources/AudioBar/AudioTypes.swift" \
  "${ROOT}/Sources/AudioBar/CoreAudioSystem.swift" \
  "${ROOT}/Sources/AudioBar/BluetoothAddress.swift" \
  "${ROOT}/Sources/AudioBar/AppConfig.swift" \
  "${ROOT}/Sources/AudioBar/BluetoothClient.swift" \
  "${ROOT}/Sources/AudioBar/PeerService.swift" \
  "${ROOT}/Sources/AudioBar/AudioModel.swift" \
  "${ROOT}/Sources/AudioBar/Symbols.swift" \
  "${ROOT}/Sources/AudioBar/DeviceListView.swift" \
  "${ROOT}/Sources/AudioBar/PopoverViewController.swift" \
  "${ROOT}/Sources/AudioBar/main.swift"

codesign --force --deep --sign - "${APP}"

echo "Built ${APP}"
