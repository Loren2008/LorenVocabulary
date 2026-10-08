#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOURCES_DIR="$PROJECT_DIR/Resources"
APP_NAME="IELTS-Vocab.app"
INSTALL_DIR="/Applications"
BUNDLE_NAME="IELTS-Vocab"
BUNDLE_ID="com.ielts.vocab"
LOCAL_SIGNING_SETUP="$PROJECT_DIR/setup_local_signing.sh"
LOCAL_SIGNING_DIR="$HOME/.ielts-vocab/signing"
LOCAL_SIGNING_KEYCHAIN="$LOCAL_SIGNING_DIR/ielts-vocab-signing.keychain-db"
LOCAL_SIGNING_PASSWORD_FILE="$LOCAL_SIGNING_DIR/keychain-password"
LOCAL_SIGNING_CERTIFICATE="$LOCAL_SIGNING_DIR/ielts-vocab-local-signing.pem"

if [ -s "$RESOURCES_DIR/words.db" ]; then
    BUNDLED_DICTIONARY="$RESOURCES_DIR/words.db"
else
    BUNDLED_DICTIONARY=""
    echo "ℹ️  未找到可再分发的 Resources/words.db；将使用 macOS 词典和网络回退。"
    echo "   如有合法授权的本地数据库，可放入 Resources/words.db 后重新构建。"
fi

# 使用固定的本机签名身份，让 macOS 能跨版本识别为同一个 App。
bash "$LOCAL_SIGNING_SETUP"
LOCAL_SIGNING_PASSWORD="$(<"$LOCAL_SIGNING_PASSWORD_FILE")"
security unlock-keychain -p "$LOCAL_SIGNING_PASSWORD" "$LOCAL_SIGNING_KEYCHAIN"

SIGNING_CERT_SHA1="$(
    openssl x509 -in "$LOCAL_SIGNING_CERTIFICATE" -noout -fingerprint -sha1 \
        | sed 's/^.*=//; s/://g'
)"
if [ -z "$SIGNING_CERT_SHA1" ]; then
    echo "❌ 无法读取本地签名证书指纹"
    exit 1
fi
DESIGNATED_REQUIREMENT="designated => anchor = H\"$SIGNING_CERT_SHA1\" and identifier \"$BUNDLE_ID\""

echo "========================================="
echo " IELTS生词本 · 构建 & 安装"
echo "========================================="

# 1. 编译
echo "🔨 编译..."
cd "$PROJECT_DIR"
swift build -c release 2>&1 | tail -3

BUILD_BIN_DIR="$(swift build -c release --show-bin-path)"
BINARY="$BUILD_BIN_DIR/$BUNDLE_NAME"
[ ! -x "$BINARY" ] && echo "❌ 未找到 release 二进制: $BINARY" && exit 1

# 2. 杀掉旧实例
echo ""
echo "🛑 终止旧实例..."
killall "$BUNDLE_NAME" 2>/dev/null || true
sleep 1

# 3. 部署
echo "📦 部署到 $INSTALL_DIR/$APP_NAME..."
rm -rf "$INSTALL_DIR/$APP_NAME"
mkdir -p "$INSTALL_DIR/$APP_NAME/Contents/MacOS"
mkdir -p "$INSTALL_DIR/$APP_NAME/Contents/Resources"

cp "$BINARY" "$INSTALL_DIR/$APP_NAME/Contents/MacOS/$BUNDLE_NAME"
cp "$RESOURCES_DIR/Info.plist" "$INSTALL_DIR/$APP_NAME/Contents/Info.plist"
cp "$RESOURCES_DIR/AppIcon.icns" "$INSTALL_DIR/$APP_NAME/Contents/Resources/" 2>/dev/null || true
if [ -n "$BUNDLED_DICTIONARY" ]; then
    cp "$BUNDLED_DICTIONARY" "$INSTALL_DIR/$APP_NAME/Contents/Resources/words.db"
fi
chmod +x "$INSTALL_DIR/$APP_NAME/Contents/MacOS/$BUNDLE_NAME"

# 4. 使用固定身份签名（辅助功能权限可跨版本保留）
echo "🔐 使用本地长期身份签名..."
codesign --force \
    --keychain "$LOCAL_SIGNING_KEYCHAIN" \
    --sign "$SIGNING_CERT_SHA1" \
    --identifier "$BUNDLE_ID" \
    --requirements "=$DESIGNATED_REQUIREMENT" \
    --entitlements "$RESOURCES_DIR/IELTS-Vocab.entitlements" \
    "$INSTALL_DIR/$APP_NAME" 2>/dev/null || {
    echo "   ⚠️ 签名失败"
    exit 1
}

codesign --verify --strict --verbose=2 "$INSTALL_DIR/$APP_NAME"
codesign --verify --strict --verbose=2 \
    -R="identifier \"$BUNDLE_ID\" and certificate root = H\"$SIGNING_CERT_SHA1\"" \
    "$INSTALL_DIR/$APP_NAME"
SIGNATURE_INFO="$(codesign -dvvv "$INSTALL_DIR/$APP_NAME" 2>&1)"
DESIGNATED_INFO="$(codesign -d -r- "$INSTALL_DIR/$APP_NAME" 2>&1)"

if printf '%s' "$SIGNATURE_INFO" | grep -q 'Signature=adhoc'; then
    echo "❌ 检测到临时签名，已停止部署"
    exit 1
fi
if printf '%s' "$DESIGNATED_INFO" | grep -q 'cdhash'; then
    echo "❌ 签名身份仍绑定构建哈希，已停止部署"
    exit 1
fi
if ! printf '%s' "$SIGNATURE_INFO" | grep -q "Identifier=$BUNDLE_ID"; then
    echo "❌ Bundle 签名标识不一致，已停止部署"
    exit 1
fi

# 5. 启动
echo ""
echo "🚀 启动..."
open "$INSTALL_DIR/$APP_NAME"
sleep 2

# 6. 验证
if pgrep -f "$BUNDLE_NAME" > /dev/null; then
    echo "   ✅ 应用已运行"
else
    echo "   ⚠️ 应用未启动，请手动打开 $INSTALL_DIR/$APP_NAME"
fi

echo ""
echo "========================================="
echo " ✅ 完成！"
echo ""
echo " 首次切换稳定签名：在辅助功能设置中重新允许一次"
echo " 以后更新：直接运行 bash build.sh，不再重复授权"
echo "========================================="
