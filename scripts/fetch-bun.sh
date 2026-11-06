#!/usr/bin/env bash
# 取 arm64 的 Bun，落到 $CACHE_DIR/bun-android-arm64（默认 $ROOT/.cache）。
#
# 为什么需要它：Magpie 装 @magpie-community 插件时要 `bun add`。它默认把 bun 下载到
# $XDG_CACHE_HOME/magpie/bun/<ver>/magpie-bun 再 fork/exec，而 Android 10+ 的应用私有
# 目录是 noexec，于是每个插件安装都死在：
#     bun add @magpie-community/xxx@latest: fork/exec …/magpie-bun: permission denied
# 只有 nativeLibraryDir / usr/bin 这类随包分发的只读位置可执行，所以 bun 必须随包走：
#   APK  → jniLibs/arm64-v8a/libbun.so（见 android-app/scripts/prepare-runtime-libs.sh）
#   模块 → usr/bin/magpie-bun（见 scripts/build.sh 的 inject_bun）
# 两处都由引擎侧 MAGPIE_BUN 指向（上游 internal/plugin/bun.go 的 Bun() 首行就读它，
# 走这个短路就不会再联网下载，也不会覆盖我们放的这份）。
#
# 用法：
#   bash scripts/fetch-bun.sh                    # 下载并校验
#   OFM_BUN_URL=... bash scripts/fetch-bun.sh    # 镜像/离线源
#   OFM_BUN_FROM_CACHE=1 bash scripts/fetch-bun.sh  # 已有产物，只校验
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${OFM_CACHE_DIR:-$ROOT/.cache}"
BUN_BIN="bun-android-arm64"
BUN_VERSION="1.4.2"
BUN_ZIP_NAME="bun-linux-aarch64-android.zip"
# 来源 zip 的哈希与 Magpie 上游 internal/plugin/bun.go 的 bunSums 一致。
BUN_ZIP_SHA256="a1c7e2983f1bb65146beb256a4d72449f23042412bc2cf278aa6397ba27e0274"
# 解包后的可执行文件本体。换 Bun 版本时上面两个都要改，构建会在校验阶段停下。
EXPECT_BUN_SHA256="f2970336bfccf36e4e8a408b25c627122f210e941672f184198c31f4dbd377a0"
DEFAULT_BUN_URL="https://github.com/oven-sh/bun/releases/download/bun-v$BUN_VERSION/$BUN_ZIP_NAME"
BUN_URL="${OFM_BUN_URL:-$DEFAULT_BUN_URL}"

sha256_of() { sha256sum "$1" | cut -d' ' -f1; }

mkdir -p "$CACHE_DIR"

if [ "${OFM_BUN_FROM_CACHE:-0}" != "1" ]; then
  echo "拉取 Bun $BUN_VERSION：$BUN_URL"
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  case "$BUN_URL" in
    file://*|http://*|https://*) curl -fsSL --retry 3 -o "$TMP/$BUN_ZIP_NAME" "$BUN_URL" ;;
    *) echo "不支持的 URL 方案: $BUN_URL" >&2; exit 2 ;;
  esac
  [ "$(sha256_of "$TMP/$BUN_ZIP_NAME")" = "$BUN_ZIP_SHA256" ] \
    || { echo "Bun zip 哈希不匹配（上游换版本了？同步改 BUN_VERSION/BUN_ZIP_SHA256/EXPECT_BUN_SHA256）" >&2; exit 1; }
  command -v unzip >/dev/null 2>&1 || { echo "需要安装 unzip" >&2; exit 1; }
  unzip -qq -o "$TMP/$BUN_ZIP_NAME" -d "$TMP/bun" \
    || { echo "Bun zip 解压失败" >&2; exit 1; }
  cp -f "$TMP/bun/bun-linux-aarch64-android/bun" "$CACHE_DIR/$BUN_BIN"
  chmod 0755 "$CACHE_DIR/$BUN_BIN"
fi

[ -f "$CACHE_DIR/$BUN_BIN" ] || { echo "缺少 $CACHE_DIR/$BUN_BIN" >&2; exit 1; }
[ "$(sha256_of "$CACHE_DIR/$BUN_BIN")" = "$EXPECT_BUN_SHA256" ] \
  || { echo "$BUN_BIN 哈希不匹配" >&2; exit 1; }
echo "Bun 就绪：$CACHE_DIR/$BUN_BIN"
