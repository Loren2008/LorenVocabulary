#!/bin/bash
set -euo pipefail

SIGNING_DIR="$HOME/.ielts-vocab/signing"
KEYCHAIN_PATH="$SIGNING_DIR/ielts-vocab-signing.keychain-db"
PASSWORD_FILE="$SIGNING_DIR/keychain-password"
CERTIFICATE_FILE="$SIGNING_DIR/ielts-vocab-local-signing.pem"
IDENTITY_NAME="IELTS Vocab Local Development"

identity_is_ready() {
    security find-identity -v -p codesigning "$KEYCHAIN_PATH" 2>/dev/null \
        | grep -F "\"$IDENTITY_NAME\"" >/dev/null
}

ensure_keychain_is_searchable() {
    local current
    local normalized
    local found=0
    local keychains=()

    while IFS= read -r current; do
        normalized="$(
            printf '%s' "$current" \
                | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//'
        )"
        [ -z "$normalized" ] || keychains+=("$normalized")
        if [ "$normalized" = "$KEYCHAIN_PATH" ]; then
            found=1
        fi
    done < <(security list-keychains -d user)

    if [ "$found" -eq 0 ]; then
        security list-keychains -d user -s "${keychains[@]}" "$KEYCHAIN_PATH"
    fi
}

mkdir -p "$SIGNING_DIR"
chmod 700 "$SIGNING_DIR"

# 已完成初始化时直接复用，不产生任何交互。
if [ -s "$KEYCHAIN_PATH" ] && [ -s "$PASSWORD_FILE" ] && [ -s "$CERTIFICATE_FILE" ]; then
    KEYCHAIN_PASSWORD="$(<"$PASSWORD_FILE")"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
    ensure_keychain_is_searchable
    if identity_is_ready; then
        echo "🔐 本地长期签名已就绪"
        exit 0
    fi

    echo "🔐 正在完成本地签名信任设置（仅首次需要）..."
    security add-trusted-cert -r trustRoot -p codeSign \
        -k "$KEYCHAIN_PATH" "$CERTIFICATE_FILE"

    if identity_is_ready; then
        echo "✅ 本地长期签名已就绪"
        exit 0
    fi

    echo "❌ 本地签名身份仍不可用，请检查系统弹出的信任确认"
    exit 1
fi

# 不覆盖不完整的既有签名资料，避免丢失私钥。
if [ -e "$KEYCHAIN_PATH" ] || [ -e "$PASSWORD_FILE" ] || [ -e "$CERTIFICATE_FILE" ]; then
    echo "❌ 检测到不完整的本地签名资料: $SIGNING_DIR"
    echo "   请先备份该目录，再处理后重新运行。"
    exit 1
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ielts-vocab-signing.XXXXXX")"
TEMP_KEY="$TEMP_DIR/private-key.pem"
TEMP_CERT="$TEMP_DIR/certificate.pem"
TEMP_IDENTITY="$TEMP_DIR/identity.p12"

cleanup() {
    [ ! -e "$TEMP_KEY" ] || unlink "$TEMP_KEY"
    [ ! -e "$TEMP_CERT" ] || unlink "$TEMP_CERT"
    [ ! -e "$TEMP_IDENTITY" ] || unlink "$TEMP_IDENTITY"
    rmdir "$TEMP_DIR" 2>/dev/null || true
}
trap cleanup EXIT

umask 077
KEYCHAIN_PASSWORD="$(openssl rand -base64 36 | tr -d '\n')"
CERTIFICATE_SERIAL="0x$(openssl rand -hex 16)"

printf '%s' "$KEYCHAIN_PASSWORD" > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 3650 \
    -set_serial "$CERTIFICATE_SERIAL" \
    -keyout "$TEMP_KEY" \
    -out "$TEMP_CERT" \
    -config <(printf '%s\n' \
        '[req]' \
        'distinguished_name=dn' \
        'x509_extensions=extensions' \
        'prompt=no' \
        '[dn]' \
        "CN=$IDENTITY_NAME" \
        'O=IELTS Vocab' \
        'OU=Local Development' \
        '[extensions]' \
        'basicConstraints=critical,CA:TRUE' \
        'keyUsage=critical,digitalSignature,keyCertSign' \
        'extendedKeyUsage=codeSigning' \
        'subjectKeyIdentifier=hash' \
        'authorityKeyIdentifier=keyid,issuer') \
    >/dev/null 2>&1

openssl pkcs12 -export \
    -inkey "$TEMP_KEY" \
    -in "$TEMP_CERT" \
    -out "$TEMP_IDENTITY" \
    -passout "pass:$KEYCHAIN_PASSWORD" \
    >/dev/null 2>&1

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security set-keychain-settings -lut 21600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
security import "$TEMP_IDENTITY" \
    -k "$KEYCHAIN_PATH" \
    -f pkcs12 \
    -P "$KEYCHAIN_PASSWORD" \
    -x \
    -T /usr/bin/codesign \
    >/dev/null
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN_PATH" \
    >/dev/null
ensure_keychain_is_searchable

cp "$TEMP_CERT" "$CERTIFICATE_FILE"
chmod 600 "$CERTIFICATE_FILE"

echo "🔐 macOS 将请求确认一次本地代码签名证书，请选择允许。"
security add-trusted-cert -r trustRoot -p codeSign \
    -k "$KEYCHAIN_PATH" "$CERTIFICATE_FILE"

if ! identity_is_ready; then
    echo "❌ 本地签名身份创建失败"
    exit 1
fi

echo "✅ 本地长期签名创建完成（有效期 10 年）"
