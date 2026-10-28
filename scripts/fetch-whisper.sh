#!/bin/bash
# 產出 Frameworks/whisper.xcframework(whisper.cpp 推理引擎,macOS 單平台切片,arm64＋x86_64 universal)。
# 二進位 ~35MB 不進 git;clone 本 repo 後先跑這支再 build。
# 需求:cmake(brew install cmake)＋ Xcode **或** Command Line Tools 皆可。全程 ~2-5 分鐘。
#   BUG-40／CLT-07(公開倉 issue #2):舊版硬寫 `-G Xcode`＋`xcodebuild -create-xcframework`,CLT-only 機器一步都走不了。
#   現在:生成器 Unix Makefiles、兩個架構各建一次再 lipo、xcframework 手組(就是一個目錄＋Info.plist)。
#   CLT 沒有 `metal` 編譯器,所以明示 -DGGML_METAL_EMBED_LIBRARY=ON(shader 原始碼嵌進二進位、執行期編),建完驗。
#   上游釘版(二審 10/28):預設 WHISPER_REF 是固定 tag,不追 master;抓不到指定版本就失敗,不偷偷改抓別的。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d /tmp/whisper-build.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

WHISPER_REF="${WHISPER_REF:-v1.9.5}"   # 釘版;要換:WHISPER_REF=v1.9.6 或 commit SHA bash scripts/fetch-whisper.sh

command -v cmake >/dev/null || { echo "需要 cmake:brew install cmake"; exit 1; }
for t in clang++ libtool dsymutil lipo strip; do
  xcrun -f "$t" >/dev/null 2>&1 || { echo "找不到 $t(xcode-select --install 裝 Command Line Tools)"; exit 1; }
done

echo "▶ fetching whisper.cpp @ ${WHISPER_REF}..."
UPSTREAM=https://github.com/ggml-org/whisper.cpp.git
if ! git clone --quiet --depth 1 --branch "$WHISPER_REF" "$UPSTREAM" "$WORK/whisper.cpp" 2>/dev/null; then
  # 不是 branch/tag 就當 commit SHA 抓;還是抓不到 ⇒ 直接失敗,🚫 不退回 master(二審:靜默改版)
  rm -rf "$WORK/whisper.cpp"; mkdir -p "$WORK/whisper.cpp"
  git -C "$WORK/whisper.cpp" init --quiet
  git -C "$WORK/whisper.cpp" fetch --quiet --depth 1 "$UPSTREAM" "$WHISPER_REF" \
    || { echo "❌ 抓不到 whisper.cpp 的 ${WHISPER_REF}(tag／branch／commit 都不是),不建"; exit 1; }
  git -C "$WORK/whisper.cpp" checkout --quiet --detach FETCH_HEAD
fi
cd "$WORK/whisper.cpp"
WHISPER_COMMIT="$(git rev-parse HEAD)"
echo "   resolved ${WHISPER_REF} → ${WHISPER_COMMIT}"

echo "▶ deriving macOS-only build script (Unix Makefiles, no xcodebuild)..."
python3 - <<'PY'
src = open('build-xcframework.sh', encoding='utf-8').read()
lines = src.splitlines(keepends=True)
cut = next(i for i, l in enumerate(lines) if 'Building for iOS sim' in l)
head = ''.join(lines[:cut])
# 上游 macOS 分支把架構寫死成 "arm64 x86_64";我們一次只建一個架構,改成讀環境變數。
needle = 'sdk="macosx"\n            archs="arm64 x86_64"'
assert needle in head, '上游 combine_static_libraries 的 macos 分支長得不一樣,請更新 fetch-whisper.sh'
head = head.replace(needle, 'sdk="macosx"\n            archs="${MACOS_ARCHS:-arm64 x86_64}"')
# libtool 的錯誤別吞掉(少一個 .a 要看得到)
head = head.replace('libtool -static -o "${temp_dir}/combined.a" "${libs[@]}" 2> /dev/null',
                    'libtool -static -o "${temp_dir}/combined.a" "${libs[@]}"')
tail = r'''
build_macos_arch() {   # $1=arch  $2=build dir
    echo "Building for macOS ($1)..."
    cmake -B "$2" -G "Unix Makefiles" \
        "${COMMON_CMAKE_ARGS[@]}" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
        -DCMAKE_OSX_ARCHITECTURES="$1" \
        -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
        -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
        -DWHISPER_COREML="ON" \
        -DWHISPER_COREML_ALLOW_FALLBACK="ON" \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -S .
    cmake --build "$2" -j "$(sysctl -n hw.ncpu)"
    setup_framework_structure "$2" ${MACOS_MIN_OS_VERSION} "macos"
    # 單組態生成器沒有 Release 子目錄 ⇒ release_dir 傳空字串(路徑變 src//libwhisper.a,POSIX 允許)
    MACOS_ARCHS="$1" combine_static_libraries "$2" "" "macos" "false"
}

build_macos_arch arm64  build-macos-arm64
build_macos_arch x86_64 build-macos-x86_64

echo "Creating universal framework (lipo)..."
UNI=build-macos-universal
rm -rf "$UNI"; mkdir -p "$UNI"
cp -R build-macos-arm64/framework "$UNI/"        # 目錄結構／標頭／modulemap／Info.plist 與架構無關
lipo -create build-macos-arm64/framework/whisper.framework/Versions/A/whisper \
             build-macos-x86_64/framework/whisper.framework/Versions/A/whisper \
     -output "$UNI/framework/whisper.framework/Versions/A/whisper"
mkdir -p "$UNI/dSYMs"
cp -R build-macos-arm64/dSYMs/whisper.dSYM "$UNI/dSYMs/"
lipo -create build-macos-arm64/dSYMs/whisper.dSYM/Contents/Resources/DWARF/whisper \
             build-macos-x86_64/dSYMs/whisper.dSYM/Contents/Resources/DWARF/whisper \
     -output "$UNI/dSYMs/whisper.dSYM/Contents/Resources/DWARF/whisper"

echo "Assembling whisper.xcframework (no xcodebuild)..."
XC=build-apple/whisper.xcframework
rm -rf "$XC"; mkdir -p "$XC/macos-arm64_x86_64"
cp -R "$UNI/framework/whisper.framework" "$XC/macos-arm64_x86_64/"
cp -R "$UNI/dSYMs"                       "$XC/macos-arm64_x86_64/"
cat > "$XC/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AvailableLibraries</key>
	<array>
		<dict>
			<key>BinaryPath</key>
			<string>whisper.framework/Versions/A/whisper</string>
			<key>DebugSymbolsPath</key>
			<string>dSYMs</string>
			<key>LibraryIdentifier</key>
			<string>macos-arm64_x86_64</string>
			<key>LibraryPath</key>
			<string>whisper.framework</string>
			<key>SupportedArchitectures</key>
			<array>
				<string>arm64</string>
				<string>x86_64</string>
			</array>
			<key>SupportedPlatform</key>
			<string>macos</string>
		</dict>
	</array>
	<key>CFBundlePackageType</key>
	<string>XFWK</string>
	<key>XCFrameworkFormatVersion</key>
	<string>1.0</string>
</dict>
</plist>
PLIST

echo "Verifying the product..."
BIN="$XC/macos-arm64_x86_64/whisper.framework/Versions/A/whisper"
fail() { echo "❌ 產物驗證失敗:$1"; exit 1; }
ARCHS="$(lipo -archs "$BIN")"
case "$ARCHS" in *arm64*) ;; *) fail "缺 arm64 切片($ARCHS)";; esac
case "$ARCHS" in *x86_64*) ;; *) fail "缺 x86_64 切片($ARCHS)";; esac
MINOS="$(otool -l "$BIN" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
[ "$MINOS" = "${MACOS_MIN_OS_VERSION}" ] || fail "minos=$MINOS,應為 ${MACOS_MIN_OS_VERSION}"
nm -gU "$BIN" | grep -q " _whisper_init_from_file" || fail "缺 _whisper_init_from_file 符號"
nm "$BIN" | grep -q "ggml_metallib" || fail "Metal shader 沒嵌進二進位(GGML_METAL_EMBED_LIBRARY 沒生效)"
otool -L "$BIN" | grep -q "CoreML.framework" || fail "沒連 CoreML"
[ -f "$XC/macos-arm64_x86_64/whisper.framework/Headers/whisper.h" ] || fail "缺 Headers/whisper.h"
[ -f "$XC/macos-arm64_x86_64/whisper.framework/Modules/module.modulemap" ] || fail "缺 module.modulemap"
[ -f "$XC/macos-arm64_x86_64/dSYMs/whisper.dSYM/Contents/Resources/DWARF/whisper" ] || fail "缺 dSYM"
echo "   archs=$ARCHS minos=$MINOS metal=embedded coreml=linked"
'''
open('build-xcframework-macos.sh', 'w', encoding='utf-8').write(head + tail)
PY
bash -n build-xcframework-macos.sh

echo "▶ building (this takes a few minutes; log: $WORK/whisper.cpp/build.log)..."
bash build-xcframework-macos.sh > build.log 2>&1 || { tail -40 build.log; exit 1; }

# 原子替換(二審):先複製到旁邊,再 mv 兩步換掉,複製中途失敗不會毀掉現有可用的那份
FW="$REPO_ROOT/Frameworks"
mkdir -p "$FW"
rm -rf "$FW/whisper.xcframework.new" "$FW/whisper.xcframework.old"
cp -R build-apple/whisper.xcframework "$FW/whisper.xcframework.new"
[ -d "$FW/whisper.xcframework" ] && mv "$FW/whisper.xcframework" "$FW/whisper.xcframework.old"
mv "$FW/whisper.xcframework.new" "$FW/whisper.xcframework"
rm -rf "$FW/whisper.xcframework.old"
printf 'whisper.cpp %s (%s)\nbuilt %s with %s\n' "$WHISPER_REF" "$WHISPER_COMMIT" "$(date '+%Y-%m-%d %H:%M %Z')" "$(xcrun -f clang | sed 's|/usr/bin/clang||')" > "$FW/whisper.xcframework.build-info.txt"
echo "✅ Frameworks/whisper.xcframework ready: whisper.cpp ${WHISPER_REF} (${WHISPER_COMMIT:0:12}), $(lipo -archs "$FW/whisper.xcframework/macos-arm64_x86_64/whisper.framework/Versions/A/whisper")"
