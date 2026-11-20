#!/usr/bin/env bash
# Build a self-contained KataGo (Metal backend) for macOS arm64.
#
# Usage: build-katago-metal.sh <katago-tag> <out-dir>
# Writes <out-dir>/katago-<tag>-metal-macos-arm64.zip and prints, as the last
# two lines, "size <bytes>" and "sha256 <hex>".
#
# Why from source: Homebrew's KataGo links protobuf, abseil and libzip from
# /opt/homebrew. Here protobuf and abseil are built as static libraries first,
# and the Homebrew prefixes are hidden from CMake, so the result depends only on
# /usr/lib and /System/Library. libzip is then absent (NO_LIBZIP): analysis still
# works, only zipped-model loading is lost.
#
# Dependency versions: abseil 20260817.0 and protobuf v36.2, the versions
# Homebrew built against. Both tags exist upstream, so no substitute is used.
#
# Requirements: an arm64 Mac, Command Line Tools (Swift >= 5.9, codesign, vtool),
# cmake, ninja, pkg-config, git and zip. The script checks these up front and
# checks the finished binary before packaging it.
set -euo pipefail

check_host() {
  [[ $(uname -m) == arm64 ]] || { echo "error: needs an arm64 Mac, found $(uname -m)" >&2; return 1; }
  local tool
  for tool in cmake ninja pkg-config git zip codesign otool vtool; do
    command -v "$tool" > /dev/null || { echo "error: $tool is not on PATH" >&2; return 1; }
  done
}

# Fail unless the binary links only system libraries and targets macOS 13.0.
check_binary() {
  local bin=$1 linked bad
  # Capture first so that a failing otool fails the check instead of reading as "no bad libraries".
  linked=$(otool -L "$bin") || { echo "error: otool -L failed on $bin" >&2; return 1; }
  bad=$(printf '%s\n' "$linked" | tail -n +2 | awk '{print $1}' | grep -v -e '^/usr/lib/' -e '^/System/Library/' || true)
  if [[ -n $bad ]]; then
    echo "error: $bin links libraries outside /usr/lib and /System/Library:" >&2
    echo "$bad" >&2
    return 1
  fi
  vtool -show-build "$bin" | grep -q 'minos 13\.0$' || {
    echo "error: $bin does not report minos 13.0" >&2
    return 1
  }
}

# Sourcing the script only defines the functions above.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0


TAG=${1:?usage: build-katago-metal.sh <katago-tag> <out-dir>}
OUT=${2:?usage: build-katago-metal.sh <katago-tag> <out-dir>}
ABSEIL_TAG=20260817.0
PROTOBUF_TAG=v36.2
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

check_host

mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
DEPS=$WORK/deps

COMMON=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0
  -DCMAKE_CXX_STANDARD=17 "-DCMAKE_INSTALL_PREFIX=$DEPS")

git clone --depth 1 --branch "$TAG" https://github.com/lightvector/KataGo "$WORK/KataGo"
git clone --depth 1 --branch "$ABSEIL_TAG" https://github.com/abseil/abseil-cpp "$WORK/abseil"
git clone --depth 1 --branch "$PROTOBUF_TAG" --recurse-submodules --shallow-submodules \
  https://github.com/protocolbuffers/protobuf "$WORK/protobuf"

# abseil, static
cmake -S "$WORK/abseil" -B "$WORK/abseil-build" "${COMMON[@]}" \
  -DABSL_PROPAGATE_CXX_STD=ON -DABSL_BUILD_TESTING=OFF
cmake --build "$WORK/abseil-build"
cmake --install "$WORK/abseil-build"

# protobuf, static, on the abseil above
cmake -S "$WORK/protobuf" -B "$WORK/protobuf-build" "${COMMON[@]}" \
  -Dprotobuf_BUILD_TESTS=OFF -Dprotobuf_ABSL_PROVIDER=package \
  "-DCMAKE_PREFIX_PATH=$DEPS"
cmake --build "$WORK/protobuf-build"
cmake --install "$WORK/protobuf-build"

# KataGo, Metal backend, with Homebrew hidden. KataGo's own CMakeLists sets the
# deployment target only after project(), and swiftc, which compiles the Swift
# part and does the final link, ignores it, so the binary came out with minos =
# the host OS. Pass the target to the C++ side on the command line and to swiftc
# explicitly through CMAKE_Swift_FLAGS.
export PKG_CONFIG_LIBDIR=$DEPS/lib/pkgconfig
cmake -S "$WORK/KataGo/cpp" -B "$WORK/katago-build" -G Ninja \
  -DUSE_BACKEND=METAL -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
  "-DCMAKE_Swift_FLAGS=-target arm64-apple-macosx13.0" "-DCMAKE_PREFIX_PATH=$DEPS" "-DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local"
cmake --build "$WORK/katago-build"

KATAGO=$WORK/katago-build/katago
codesign --force --sign - --timestamp=none "$KATAGO"
check_binary "$KATAGO"

# package
STAGE=$WORK/stage
mkdir -p "$STAGE"
cp "$KATAGO" "$STAGE/katago"
cp "$WORK/KataGo/LICENSE" "$STAGE/LICENSE"
sed -e "s/@TAG@/$TAG/g" -e "s/@ABSEIL_TAG@/$ABSEIL_TAG/g" -e "s/@PROTOBUF_TAG@/$PROTOBUF_TAG/g" \
  "$SCRIPT_DIR/README-katago.txt.in" > "$STAGE/README.txt"

# Licence texts of everything compiled into the binary besides KataGo itself:
# protobuf and abseil (static libraries), and the cpp/external components the
# Metal build uses (tclap, filesystem, nlohmann_json, katagocoreml). Components
# for other backends (clblast, cutlass, onnx, httplib, half, ...) are not built.
KG=$WORK/KataGo/cpp
LIC=$STAGE/THIRD-PARTY-LICENSES.txt
section() { # name, version, url, licence name, file...
  local name=$1 version=$2 url=$3 licence=$4
  shift 4
  {
    printf '================================================================================\n'
    printf '%s %s\n%s\nLicence: %s\n' "$name" "$version" "$url" "$licence"
    printf '================================================================================\n\n'
    cat "$@"
    printf '\n\n'
  } >> "$LIC"
}
: > "$LIC"
section protobuf "$PROTOBUF_TAG" https://github.com/protocolbuffers/protobuf BSD-3-Clause "$WORK/protobuf/LICENSE"
section abseil "$ABSEIL_TAG" https://github.com/abseil/abseil-cpp Apache-2.0 "$WORK/abseil/LICENSE"
section katagocoreml "vendored in KataGo $TAG (its NOTICE also covers coremltools, MILBlob, ModelPackage, nlohmann_json and FP16)" \
  https://github.com/lightvector/KataGo/tree/"$TAG"/cpp/external/katagocoreml BSD-3-Clause \
  "$KG/external/katagocoreml/LICENSE" "$KG/external/katagocoreml/NOTICE"
section tclap 1.2.5 http://tclap.sourceforge.net MIT "$KG/external/tclap-1.2.5/COPYING"
section filesystem 1.5.8 https://github.com/gulrak/filesystem MIT "$KG/external/filesystem-1.5.8/LICENSE"
sed -n '1,/^\*\//p' "$KG/external/nlohmann_json/json.hpp" > "$WORK/nlohmann-header.txt"
section nlohmann_json 3.8.0 https://github.com/nlohmann/json MIT "$WORK/nlohmann-header.txt"
sed -n '/^ \* The original license/,/^ \*\/$/p' "$KG/core/sha2.cpp" > "$WORK/sha2-license.txt"
section "sha2 (cpp/core/sha2.cpp)" "from Aaron D. Gifford" http://www.aarongifford.com/ BSD-3-Clause "$WORK/sha2-license.txt"
ZIP=$OUT/katago-$TAG-metal-macos-arm64.zip
rm -f "$ZIP"
(cd "$STAGE" && zip -q -X "$ZIP" katago LICENSE THIRD-PARTY-LICENSES.txt README.txt)

echo "size $(stat -f %z "$ZIP")"
echo "sha256 $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
