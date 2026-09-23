#!/bin/bash
# 构建 Release 版 .app 到 dist/，不签名；签名与公证由 CI 统一完成。
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build/DerivedData
rm -rf dist
xcodebuild \
  -project LiveTranslateBridge.xcodeproj \
  -scheme LiveTranslateBridge \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

mkdir -p dist
ditto "$DERIVED/Build/Products/Release/LiveTranslateBridge.app" dist/LiveTranslateBridge.app
echo "Built dist/LiveTranslateBridge.app"
