#!/bin/bash
# Builds the `myparrot` CLI (release), signs it, and installs to ~/bin/myparrot.
# 與 build-app.sh 的關係:憑證選擇邏輯同一套;whisper.framework 不隨 CLI 發——
# rpath 指向 ~/Applications/MyParrot.app/Contents/Frameworks 借 app 的框架
# (app 未裝→WhisperCpp 引擎不可用,CLI 自動回退 apple 引擎,不影響其他功能)。
set -euo pipefail
cd "$(dirname "$0")/.."

echo "▶ swift build -c release --product MyParrotCLI"
swift build -c release --product MyParrotCLI

BIN=".build/release/MyParrotCLI"
DEST_DIR="${MYPARROT_CLI_DEST:-$HOME/bin}"
DEST="$DEST_DIR/myparrot"
[ -f "$BIN" ] || { echo "❌ 找不到 $BIN"; exit 1; }

mkdir -p "$DEST_DIR"
rm -f "$DEST"
cp "$BIN" "$DEST"

# --- rpath:借已安裝 app 的 whisper.framework -------------------------------
APP_FW="$HOME/Applications/MyParrot.app/Contents/Frameworks"
install_name_tool -add_rpath "$APP_FW" "$DEST" 2>/dev/null || true
if [ ! -d "$APP_FW/whisper.framework" ]; then
  echo "⚠️ $APP_FW/whisper.framework 不存在 — whisper 引擎會回退 apple。"
  echo "   要用 whisper:先跑 scripts/build-app.sh 裝 app。"
fi

# --- 簽章身分(同 build-app.sh 的優先序;TCC 記錄綁簽章身分,穩定憑證才記得住) --
HARDENED=0
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  SIGN_ID="$CODESIGN_IDENTITY"; HARDENED=1
else
  SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Developer ID Application[^"]*"' | head -1 | tr -d '"' || true)"
  [ -z "$SIGN_ID" ] && SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -oE '"Apple Development[^"]*"' | head -1 | tr -d '"' || true)"
  if [ -n "$SIGN_ID" ]; then HARDENED=1
  elif security find-identity 2>/dev/null | grep -q "MyParrot Dev"; then SIGN_ID="MyParrot Dev"
  else SIGN_ID="-"; echo "▶ 無憑證,ad-hoc 簽章(TCC 每次重 build 會重問)"; fi
fi

# Hardened Runtime 下麥克風要 audio-input entitlement(同 app,共用同一份檔)。
CODESIGN_OPTS=()
[ "$HARDENED" = 1 ] && CODESIGN_OPTS=(--options runtime --timestamp)
codesign --force --sign "$SIGN_ID" "${CODESIGN_OPTS[@]}" \
  --entitlements Resources/MyParrot.entitlements "$DEST"
echo "▶ codesign: $SIGN_ID"

# --- 驗證:__info_plist 讀得回 + 簽章 strict ---------------------------------
if otool -s __TEXT __info_plist "$DEST" | grep -q "__info_plist"; then
  echo "▶ __info_plist 已嵌入(TCC usage descriptions 可用)"
else
  echo "❌ __info_plist 缺失 — record 會直接 crash;檢查 Package.swift linkerSettings"; exit 1
fi
codesign --verify --strict "$DEST" && echo "▶ 簽章 strict 驗證通過"

echo "✅ 已安裝 $DEST"
if [[ ":$PATH:" != *":$DEST_DIR:"* ]]; then
  echo "   ⚠️ PATH 不含 $DEST_DIR — 加進 shell rc:export PATH=\"$DEST_DIR:\$PATH\""
fi
echo "   首跑 record 會依序跳 麥克風/系統音訊 權限(歸屬=你的終端機 app)。"
