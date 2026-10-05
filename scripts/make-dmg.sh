#!/usr/bin/env bash
#
# make-dmg.sh —— 把 NiceLyricsX 打成可直接分发的 DMG。
#
# 用法:
#   bash scripts/make-dmg.sh                 # Release(默认)
#   CONFIGURATION=Debug bash scripts/make-dmg.sh
#
# 产物:dist/NiceLyricsX-<CFBundleShortVersionString>.dmg
#
# 关于签名:工程用的是 ad-hoc 签名("Sign to Run Locally"),没有 Developer ID,
# 所以分发给别人时对方首次打开会被 Gatekeeper 拦一次,需要右键 → 打开。
# 要彻底消除这个提示只能走 Apple Developer ID 签名 + 公证(notarize)。
#
set -euo pipefail

APP_NAME="NiceLyricsX"
SCHEME="NiceLyricsX"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT/build"
DIST_DIR="$ROOT/dist"
CONFIGURATION="${CONFIGURATION:-Release}"

PLIST="$ROOT/LyricsMenu/Resources/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")"
DMG="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"
APP="$BUILD_DIR/Build/Products/${CONFIGURATION}/${APP_NAME}.app"

echo "==> 构建 ${APP_NAME} ${VERSION} (${CONFIGURATION})"
xcodebuild \
  -project "$ROOT/LyricsMenu.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$BUILD_DIR" \
  build \
  | grep -E "error:|warning: [A-Z]|BUILD (SUCCEEDED|FAILED)" || true

if [ ! -d "$APP" ]; then
  echo "❌ 构建产物不存在:$APP" >&2
  exit 1
fi

echo "==> 组装 staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

# 本机构建产物一般没有 quarantine,这里清一次以防万一(不清会让用户第一次打开被拦)
xattr -cr "$STAGE/${APP_NAME}.app" 2>/dev/null || true

echo "==> 打包 DMG"
mkdir -p "$DIST_DIR"
rm -f "$DMG"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

echo "==> 校验"
hdiutil verify "$DMG" >/dev/null

MOUNT_POINT="$(mktemp -d)"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null
echo "    挂载内容:"
ls -1 "$MOUNT_POINT" | sed 's/^/      /'
test -d "$MOUNT_POINT/${APP_NAME}.app" || { echo "❌ DMG 里没有 ${APP_NAME}.app" >&2; exit 1; }
test -L "$MOUNT_POINT/Applications" || { echo "❌ DMG 里缺少 Applications 软链" >&2; exit 1; }
hdiutil detach "$MOUNT_POINT" >/dev/null
rmdir "$MOUNT_POINT"

echo "==> 签名信息"
codesign -dv "$APP" 2>&1 | grep -E "Identifier|Signature|TeamIdentifier|flags" | sed 's/^/    /' || true

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo ""
echo "✅ $DMG"
echo "   体积:$SIZE"
echo "   sha256:$SHA"
