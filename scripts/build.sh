#!/system/bin/sh
# 组装运行时并打出可刷入的模块包。
#
# 用法：
#   ./scripts/build.sh                 完整包：组装 app + 带 usr 运行时（含 arm64 引擎，约 61 MB）
#   ./scripts/build.sh --patch         增量包：只带 app（约 2 MB），复用设备上的 usr
#   ./scripts/build.sh --usr <src>     指定 usr 来源（usr 目录，或含 usr/ 的 tgz）
#   ./scripts/build.sh --app <dir>     复用已组装好的 app 目录，跳过上游拉取（离线构建）
#   ./scripts/build.sh --upstream <v>  指定上游服务版本（默认 2.8.0）
#
# 运行时 = Node（含 Android 依赖库） + 上游独立服务源码。
# 仓库不存二进制：Node 侧放 .cache/，服务代码现场从上游取，都不进版本库。
#
# 为什么分两种包：
#   usr/ 是 Node 与它的 Android 依赖库及 arm64 Magpie 引擎，解压后约 150 MB，压成约 57 MB；
#   app/ 是上游服务代码，解压后约 8 MB，压成约 2 MB，每次升级变的正是它。
#   完整包两块都带；增量包只带 app，安装时核对设备上 usr 的指纹后原地复用。
#   于是日常升级的下载量从约 61 MB 降到约 2 MB。
#
# 上游 2.6 起仓库里多了约 100 MB 的平台二进制（Windows 工作台引擎 + 分片），
# Android 用不上：拉源码用 partial clone + sparse，组装时也不带进 app/。

set -e

ROOT=$(cd "${0%/*}/.." && pwd)
VERSION=$(sed -n 's/^version=//p' "$ROOT/module/module.prop")
VCODE=$(sed -n 's/^versionCode=//p' "$ROOT/module/module.prop")
UPSTREAM_VERSION=${UPSTREAM_VERSION:-2.8.0}
REPO_URL=${OFM_SOURCE_REPO:-https://github.com/Ebony-Vinyl/dsh-our-free-model.git}
# 构建目录放到系统临时区：proot 下在工作区内跑 git clone / tar 容易被静默限制
WORK=${OFM_BUILD_DIR:-${TMPDIR:-/tmp}/ofm-build}
# 基础运行时缓存不能放进 $WORK：脚本开头会整目录重建
CACHE="$ROOT/.cache"
DIST="$ROOT/dist"

# arm64 Magpie 引擎（方案 A）：二进制随 usr 分发（app 自更新只认单文件 4MB，
# 肯定放不下 61MB 的引擎），元数据（engine.json/LICENSE/NOTICE）随 app 分发。
# 两者都由 scripts/build-magpie-engine.mjs 生成到 .cache/，可用环境变量覆盖。
ENGINE_BIN=${OFM_MAGPIE_ENGINE:-$CACHE/magpie-android-arm64}
ENGINE_META=${OFM_MAGPIE_META:-$CACHE/magpie-meta}

# ---------------- 参数 ----------------

MODE=full
USR_SRC=
APP_SRC=

while [ $# -gt 0 ]; do
  case "$1" in
    --full)    MODE=full;  shift ;;
    --patch)   MODE=patch; shift ;;
    --usr|--runtime)
      [ -n "$2" ] || { echo "$1 后面要跟 usr 来源（usr 目录或含 usr/ 的 tgz）" >&2; exit 1; }
      USR_SRC=$2; shift 2 ;;
    --app)
      [ -n "$2" ] || { echo "--app 后面要跟已组装好的 app 目录" >&2; exit 1; }
      APP_SRC=$2; shift 2 ;;
    --upstream)
      [ -n "$2" ] || { echo "--upstream 后面要跟上游版本号" >&2; exit 1; }
      UPSTREAM_VERSION=$2; shift 2 ;;
    -h|--help)
      sed -n '2,19p' "$ROOT/scripts/build.sh" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知参数：$1（用 --help 看用法）" >&2; exit 1 ;;
  esac
done

# module.prop 的键名写错（如误写成 .description）不会报错，只是管理器静默忽略该字段，
# 所以在这里显式校验必填键与不允许的键
PROP="$ROOT/module/module.prop"
for key in id name version versionCode author description; do
  grep -q "^$key=" "$PROP" || { echo "module.prop 缺少必需的键：$key" >&2; exit 1; }
done
BAD=$(grep -n '^[^a-zA-Z]' "$PROP" | grep -v '^[0-9]*:#' || true)
[ -z "$BAD" ] || { echo "module.prop 有非法行（键名不能以非字母开头）：" >&2; echo "$BAD" >&2; exit 1; }

# update.json 与实际包不一致时，管理器会推错版本或反复提示更新
JSON_VERSION=$(sed -n 's/.*"version": *"v\{0,1\}\([^"]*\)".*/\1/p' "$ROOT/update.json")
JSON_CODE=$(sed -n 's/.*"versionCode": *\([0-9][0-9]*\).*/\1/p' "$ROOT/update.json")
[ "$JSON_VERSION" = "$VERSION" ] || {
  echo "update.json 的 version（$JSON_VERSION）与 module.prop（$VERSION）不一致" >&2
  exit 1
}
[ "$JSON_CODE" = "$VCODE" ] || {
  echo "update.json 的 versionCode（$JSON_CODE）与 module.prop（$VCODE）不一致" >&2
  exit 1
}

rm -rf "$WORK"
mkdir -p "$WORK/module/runtime" "$WORK/module/common" "$DIST"

# ---------------- usr 指纹 ----------------
#
# 增量包靠它判断「设备上那份 usr 能不能直接复用」。
#
# 注意：不能用 usr.tgz 的字节哈希。本机是 toybox tar，CI 是 GNU tar，
# 同样的 usr 内容打出来的 tgz 必然不同字节 —— 那样本机打的增量包就永远装不进
# CI 出的基线包。这里按「相对路径 + 大小 + 逐文件 sha256」算内容摘要，
# 与打包工具、压缩级别、mtime 全都无关。

usr_rev() {
  ( cd "$1" || return 1
    find . -type f | LC_ALL=C sort | while IFS= read -r f; do
      printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
    done | sha256sum | cut -c1-16 )
}

# 把各种形态的 usr 来源规范成「一个含 usr/ 的目录」
materialize_usr() {
  _src=$1
  _dst=$2
  mkdir -p "$_dst"
  if [ -d "$_src" ]; then
    # 已经是 usr 目录，或包含 usr/ 的目录，都试一遍
    if [ -d "$_src/usr" ]; then
      cp -a "$_src/usr" "$_dst/usr"
    else
      cp -a "$_src" "$_dst/usr"
    fi
  elif [ -f "$_src" ]; then
    tar -xzf "$_src" -C "$_dst" usr || return 1
  else
    echo "找不到 usr 运行时：$_src" >&2
    return 1
  fi
  [ -x "$_dst/usr/bin/node" ] || { echo "usr 运行时里没有可执行的 usr/bin/node" >&2; return 1; }
}

# 把 arm64 引擎二进制塞进 usr/bin/（必须在算 usr_rev 与打 usr.tgz 之前调用，
# 这样指纹与包内容都含引擎；用户从旧包升级时指纹不符会被提示改刷完整包，安全）
inject_engine() {
  _usr_dir=$1
  if [ ! -f "$ENGINE_BIN" ]; then
    echo "缺少 arm64 Magpie 引擎：$ENGINE_BIN" >&2
    echo "先在能编译的机器上运行 node scripts/build-magpie-engine.mjs（或设 OFM_MAGPIE_ENGINE 指向已有二进制）" >&2
    return 1
  fi
  mkdir -p "$_usr_dir/usr/bin"
  cp -f "$ENGINE_BIN" "$_usr_dir/usr/bin/magpie-android-arm64"
  chmod 0755 "$_usr_dir/usr/bin/magpie-android-arm64"
}

# 引擎元数据随 app 分发：让状态面板能显示引擎版本/来源，并满足升级器的运行时资产清单
install_engine_meta() {
  if [ ! -f "$ENGINE_META/engine.json" ]; then
    echo "缺少引擎元数据：$ENGINE_META/engine.json" >&2
    echo "先运行 node scripts/build-magpie-engine.mjs（或设 OFM_MAGPIE_META）" >&2
    return 1
  fi
  mkdir -p "$APP_DIR/vendor/magpie"
  cp -f "$ENGINE_META/engine.json" "$APP_DIR/vendor/magpie/engine.json"
  if [ -f "$ENGINE_META/LICENSE" ]; then cp -f "$ENGINE_META/LICENSE" "$APP_DIR/vendor/magpie/LICENSE"; fi
  if [ -f "$ENGINE_META/NOTICE.md" ]; then cp -f "$ENGINE_META/NOTICE.md" "$APP_DIR/vendor/magpie/NOTICE.md"; fi
  return 0
}

# ---------------- app：上游服务代码 ----------------

APP_DIR="$WORK/app"

if [ -n "$APP_SRC" ]; then
  # 离线/复用构建：直接拿一份已组装好的 app 目录
  [ -d "$APP_SRC" ] || { echo "找不到 app 目录：$APP_SRC" >&2; exit 1; }
  cp -a "$APP_SRC" "$APP_DIR"
else
  # 服务代码从源码组装：升级服务逻辑不必等上游重新出 APK
  SRC_DIR="$WORK/src"

  # 上游仓库里有约 100 MB 的平台二进制（65 MB 的 Windows 工作台引擎 + 33.5 MB 分片），
  # Android 一点都用不上。全量浅克隆要在这台手机上拖十几分钟且几乎必断，
  # 所以用 partial clone + sparse 只下载真要打进包的那 12 MB。
  # 老 git 或不支持 partial clone 的代理退回全量浅克隆（慢，但总能成）。
  fetch_src() {
    _tag="v$UPSTREAM_VERSION"
    rm -rf "$SRC_DIR"
    if git clone --filter=blob:none --no-checkout --depth 1 --branch "$_tag" \
         --single-branch "$REPO_URL" "$SRC_DIR" 2>/dev/null &&
       git -C "$SRC_DIR" sparse-checkout set --no-cone \
         '/package.json' '/icon.svg' \
         '/src/*' '!/src/engine-parts/*' \
         '/packages/standalone/*' '!/packages/standalone/frontend/*' \
         '/vendor/channel-pack/*' 2>/dev/null &&
       git -C "$SRC_DIR" checkout "$_tag" >/dev/null 2>&1; then
      return 0
    fi
    echo "partial clone 不可用，退回全量浅克隆（约 100 MB）" >&2
    rm -rf "$SRC_DIR"
    git clone --depth 1 --branch "$_tag" --single-branch "$REPO_URL" "$SRC_DIR"
  }

  fetch_src || { echo "拉不到上游源码：$REPO_URL（v$UPSTREAM_VERSION）" >&2; exit 1; }

  GOT=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' "$SRC_DIR/package.json" | head -n 1)
  [ "$GOT" = "$UPSTREAM_VERSION" ] || {
    echo "上游版本不符：期望 $UPSTREAM_VERSION，取到 $GOT" >&2
    exit 1
  }

  # 独立服务实际运行所需：src/ + packages/standalone/ + vendor/channel-pack/
  #
  # 上游 2.6 起 standalone 多了 workbench / library / providers / routing /
  # client-terminal 等模块，逐个列文件清单迟早漏一个 —— 漏了就是开机即
  # ERR_MODULE_NOT_FOUND。所以整目录复制，只排掉开发期的东西。
  python3 - "$SRC_DIR" "$APP_DIR" <<'PY'
import os, shutil, sys
src, app = sys.argv[1], sys.argv[2]
os.makedirs(app, exist_ok=True)

def copy(rel, ignore=()):
    shutil.copytree(os.path.join(src, rel), os.path.join(app, rel),
                    ignore=shutil.ignore_patterns(*ignore), dirs_exist_ok=True)

# engine-parts 是 Windows 引擎的 8 个分片（33.5 MB），Android 上跑不了；
# 留着会把 app 块从 3 MB 顶到 36 MB，增量包就没意义了
copy('src', ('engine-parts',))

# frontend/ 是管理页的 React 源码，运行时用的是构建好的 web/ 产物；
# node_modules 与 lock 只有开发时装依赖用得上
copy('packages/standalone', ('node_modules', 'package-lock.json',
                            'tsconfig.json', 'frontend'))

# 渠道包仍按清单取：同目录的 src/*.ts 是 TypeScript 源码，运行只要构建产物
vp = os.path.join(src, 'vendor/channel-pack')
dv = os.path.join(app, 'vendor/channel-pack')
os.makedirs(dv, exist_ok=True)
for name in ('pack.js', 'qoder-auth-wasm.wasm', 'LICENSE', 'NOTICE.md', 'package.json', 'locale'):
    s = os.path.join(vp, name)
    if os.path.isdir(s):
        shutil.copytree(s, os.path.join(dv, name), dirs_exist_ok=True)
    else:
        shutil.copy2(s, os.path.join(dv, name))

# 引擎的图标：读不到也不影响启动（try/catch），顺手带上
icon = os.path.join(src, 'icon.svg')
if os.path.isfile(icon):
    shutil.copy2(icon, os.path.join(app, 'icon.svg'))
PY
fi

# ofmctl.sh 以 "$RT_DIR/app" 为工作目录启动 CLI，层级不能变
for _d in packages/standalone/cli.mjs packages/standalone/service.mjs vendor/channel-pack/pack.js; do
  [ -e "$APP_DIR/$_d" ] || { echo "app 组装不完整：缺少 $_d" >&2; exit 1; }
done

# 引擎元数据（engine.json/LICENSE/NOTICE）随 app 分发。--app 复用的 app 目录
# 若来自完整构建，已自带这些文件，无需重复安装。
if [ -z "$APP_SRC" ]; then
  install_engine_meta || exit 1
fi

# OpenAI 兼容修补：chat/completions 入口只认 system/user/assistant/tool，
# 收到 role:"developer" 直接 400。新版客户端（DSH 的 pi-ai）对自定义 baseURL
# 会把握手用的系统提示发成 developer，于是第一个请求就被拒 —— 表现为
# 「换这个通道一个字都发不出去」。上游自己的 /v1/responses 本来就接受
# developer（折成 system），这里按同样语义把 chat/completions 补齐。
# 锚点找不到就构建失败，不会出一个「看起来修了」的包。
if _node=$(command -v node 2>/dev/null); then
  "$_node" "$ROOT/scripts/openai-developer-compat.mjs" "$APP_DIR" ||
    { echo "OpenAI 兼容修补失败（上游结构可能变了）" >&2; exit 1; }
  # 把 OFM_MAGPIE_BINARY 接进 createMagpieEngine，让服务用 usr 里的 arm64 引擎
  "$_node" "$ROOT/scripts/magpie-binary-env.mjs" "$APP_DIR" ||
    { echo "Magpie 引擎环境变量补丁失败（上游结构可能变了）" >&2; exit 1; }
else
  echo "没有 node，无法做运行期补丁" >&2; exit 1
fi

# 把 service.mjs 的 import 图整个走一遍：漏文件在这里就炸，
# 不用等刷进设备、开机后才发现 ERR_MODULE_NOT_FOUND
if [ -n "$_node" ]; then
  "$_node" --input-type=module -e "import('file://$APP_DIR/packages/standalone/service.mjs')" ||
    { echo "app 的 import 图不完整（上面是缺的模块）" >&2; exit 1; }
else
  echo "没有 node，跳过 import 图检查（CI 与本机都应该有）" >&2
fi

tar -czf "$WORK/module/runtime/app.tgz" -C "$WORK" app

# app 块不该超过 10 MB。超了八成是把 Windows 引擎分片（33.5 MB）打进去了，
# 那增量包会从 3 MB 涨回 36 MB，双包机制直接失效 —— 宁可构建失败
_app_bytes=$(wc -c <"$WORK/module/runtime/app.tgz" | tr -d ' ')
[ "$_app_bytes" -lt 10485760 ] || {
  echo "app.tgz 有 $((_app_bytes / 1048576)) MB，超过 10 MB 上限；检查 engine-parts 是否被打进 app/" >&2
  exit 1
}
echo "app.tgz：$((_app_bytes / 1048576)).$((_app_bytes % 1048576 * 10 / 1048576)) MB"

# ---------------- usr：按模式决定带不带 ----------------

if [ -z "$USR_SRC" ]; then
  if [ -n "$OFM_NODE_RUNTIME" ] && [ -f "$OFM_NODE_RUNTIME" ]; then
    USR_SRC="$OFM_NODE_RUNTIME"
  else
    USR_SRC="$CACHE/node-runtime-arm64.tgz"
  fi
fi

if [ "$MODE" = full ]; then
  materialize_usr "$USR_SRC" "$WORK/usr-src" || exit 1
  inject_engine "$WORK/usr-src" || exit 1
  USR_REV=$(usr_rev "$WORK/usr-src/usr")
  tar -czf "$WORK/module/runtime/usr.tgz" -C "$WORK/usr-src" usr
elif [ -n "$OFM_USR_REV" ]; then
  # 显式给了指纹就不再解一遍 90 MB
  USR_REV=$OFM_USR_REV
else
  materialize_usr "$USR_SRC" "$WORK/usr-src" || exit 1
  inject_engine "$WORK/usr-src" || exit 1
  USR_REV=$(usr_rev "$WORK/usr-src/usr")
fi

[ -n "$USR_REV" ] || { echo "算不出 usr 指纹" >&2; exit 1; }

printf '%s\n' "$VERSION" >"$WORK/module/runtime/.version"
printf '%s\n' "$USR_REV" >"$WORK/module/runtime/usr-rev"

# ---------------- 模块脚本 ----------------

# 只取打包所需的文件，运行时二进制不进仓库
cp "$ROOT/module/module.prop" "$ROOT/module/customize.sh" "$ROOT/module/service.sh" \
   "$ROOT/module/uninstall.sh" "$ROOT/module/action.sh" "$ROOT/module/config.sh" \
   "$WORK/module/"
cp "$ROOT/module/common/ofmctl.sh" "$ROOT/module/common/runtime.sh" "$WORK/module/common/"
chmod 0755 "$WORK/module"/*.sh "$WORK/module/common"/*.sh

# webroot 的权限与 SELinux 上下文由 KernelSU 安装时自己设置，这里不碰
cp -r "$ROOT/module/webroot" "$WORK/module/webroot"

# ---------------- 打包 ----------------

if [ "$MODE" = full ]; then
  OUT="$DIST/OFM_Gateway_Magisk_v$VERSION.zip"
else
  OUT="$DIST/OFM_Gateway_Magisk_v${VERSION}_patch.zip"
fi
rm -f "$OUT"

# -0：运行时 tgz 已是压缩态，再 zip 一遍纯属浪费
if command -v zip >/dev/null 2>&1; then
  ( cd "$WORK/module" && zip -r -0 -q "$OUT" . )
else
  python3 - "$WORK/module" "$OUT" <<'PY'
import os, sys, zipfile
src, out = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_STORED) as z:
    for base, _dirs, files in os.walk(src):
        for name in files:
            full = os.path.join(base, name)
            z.write(full, os.path.relpath(full, src))
PY
fi

echo "类型：$([ "$MODE" = full ] && echo '完整包（含 usr）' || echo '增量包（仅 app）')"
echo "usr 指纹：$USR_REV"
echo "已生成：$OUT"
ls -lh "$OUT"
