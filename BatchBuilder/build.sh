#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT="$PROJECT_DIR/batch-builder"
SDK_PATH=$(xcrun --show-sdk-path --sdk macosx)

echo "🔨 编译批量构建工具..."
swiftc \
    -import-objc-header "$PROJECT_DIR/bridge.h" \
    -framework CoreServices \
    -framework Foundation \
    -sdk "$SDK_PATH" \
    -target arm64-apple-macosx13.0 \
    -O \
    -o "$OUTPUT" \
    "$PROJECT_DIR/main.swift" \
    -lsqlite3

chmod +x "$OUTPUT"
echo "✅ 已编译: $OUTPUT"
echo ""
echo "用法:"
echo "  $OUTPUT /path/to/wordlist.txt"
