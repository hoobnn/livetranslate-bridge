#!/bin/bash
# 构建 Release 版 .app 到 dist/，不签名；签名与公证由 CI 统一完成。
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build/DerivedData.noindex
rm -rf dist
xcodebuild \
  -project LiveTranslateBridge.xcodeproj \
  -scheme LiveTranslateBridge \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGNING_ALLOWED=NO \
  build

# xcodebuild 会把产物登记到 Launch Services；它与正式版同 bundle ID，
# 留着会让 brew 升级后按 ID 重开时打开这份中间产物。
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -u "$DERIVED/Build/Products/Release/LiveTranslateBridge.app" 2>/dev/null || true

mkdir -p dist
ditto "$DERIVED/Build/Products/Release/LiveTranslateBridge.app" dist/LiveTranslateBridge.app
echo "Built dist/LiveTranslateBridge.app"
