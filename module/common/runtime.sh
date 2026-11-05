#!/system/bin/sh
# 确保 /data/adb/ofm-runtime 里有与模块版本一致的运行时。
# 放在 /data/adb 下而不是模块目录：模块升级时旧目录会被整体清理，其中进程会被一并杀掉。
#
# 运行时由两块组成，可以分开更新：
#   usr/  Node 与它的 Android 依赖库，约 90 MB，只在换 Node 时才变
#   app/  上游服务代码，约 8 MB，每次升级变的都是它
# 完整包带 runtime/usr.tgz + runtime/app.tgz；增量包只带 app.tgz。
# 增量包靠 runtime/usr-rev 里的指纹判断设备上那份 usr 能否直接复用 ——
# 对不上就拒绝安装（退出码 2），让用户改刷完整包，而不是装出半套运行时。
#
# 退出码：0 正常；1 解压失败；2 增量包与本机不匹配，需要完整包。

# 模块目录由调用方传入（$0 在通过 sh 调用时不可靠）
MODDIR=${OFM_MODDIR:-${0%/*}}
RT_DIR=/data/adb/ofm-runtime
RT_CONTENT="$MODDIR/runtime"
RT_VERSION=$(sed -n '1p' "$RT_CONTENT/.version" 2>/dev/null)
[ -n "$RT_VERSION" ] || RT_VERSION=0.1.0
MOD_USR_REV=$(sed -n '1p' "$RT_CONTENT/usr-rev" 2>/dev/null)

err_patch_mismatch() {
  echo "运行时版本不匹配：这个增量包要求 usr 指纹 $MOD_USR_REV，" >&2
  echo "设备上现在是「${1:-空}」。" >&2
  echo "增量包不含 Node 运行时，请改刷同版本的完整包（OFM_Gateway_Magisk_v*.zip）。" >&2
  return 2
}

# 服务正拿着 $RT_DIR 里的可执行文件，替换前必须先停掉。
#
# 服务现在由 ofmctl.sh 用 setsid 拉起，是独立会话/进程组的组长；
# 所以这里优先按进程组发 TERM（Magpie 子进程会跟着一起退，不留孤儿），
# 收敛不了再逐 pid 补 KILL。旧版留下的、不是组长的进程按单 pid 处理。
stop_running() {
  _was_running=0
  for _p in $(pidof node 2>/dev/null); do
    tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null | grep -q "$RT_DIR" && _was_running=1
  done
  [ $_was_running = 1 ] || return 0

  for _p in $(pidof node 2>/dev/null); do
    tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null | grep -q "$RT_DIR" || continue
    # 第 4 段是 session id：等于自身 pid 说明它是组长，可以整组发信号
    _sid=$(sed -n '1s/.*) //p' "/proc/$_p/stat" 2>/dev/null | awk '{print $4}')
    if [ "$_sid" = "$_p" ]; then
      kill -TERM -"$_p" 2>/dev/null
    else
      kill -TERM "$_p" 2>/dev/null
    fi
  done
  _i=0
  while [ "$_i" -lt 5 ]; do
    _alive=0
    for _p in $(pidof node 2>/dev/null); do
      tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null | grep -q "$RT_DIR" && _alive=1
    done
    [ $_alive = 0 ] && break
    _i=$((_i + 1))
    sleep 1
  done
  # 还没退就补 KILL，否则替换 /data/adb/ofm-runtime 会留下拿着已删文件的进程
  for _p in $(pidof node 2>/dev/null); do
    tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null | grep -q "$RT_DIR" || continue
    _sid=$(sed -n '1s/.*) //p' "/proc/$_p/stat" 2>/dev/null | awk '{print $4}')
    if [ "$_sid" = "$_p" ]; then kill -KILL -"$_p" 2>/dev/null; else kill -KILL "$_p" 2>/dev/null; fi
  done
  sleep 1
}

# 先解到同一文件系统下的暂存目录，再改名替换：解压失败时旧的那块仍在，不会留下半套。
# $1 = 目录名（usr 或 app），tgz 里的顶层目录与它同名。
# toybox tar 与 GNU tar 都没有统一可用的 --strip-components，所以解到暂存目录再搬。
swap_in() {
  _name=$1
  mkdir -p "$RT_DIR" || return 1
  _stage="$RT_DIR/.stage-$_name"
  rm -rf "$_stage"
  mkdir -p "$_stage" || return 1
  tar -xzf "$RT_CONTENT/$_name.tgz" -C "$_stage" || { rm -rf "$_stage"; return 1; }
  [ -d "$_stage/$_name" ] || { rm -rf "$_stage"; return 1; }

  # 服务已停，此时替换是安全的。mv 不跨文件系统，才是原子的
  rm -rf "$RT_DIR/$_name"
  mv "$_stage/$_name" "$RT_DIR/$_name" || { rm -rf "$_stage"; return 1; }
  rm -rf "$_stage"
  return 0
}

ensure_runtime() {
  _dev_ver=$(cat "$RT_DIR/.version" 2>/dev/null)
  _dev_rev=$(cat "$RT_DIR/usr-rev" 2>/dev/null)

  # 设备上那份 usr 能不能用：
  #   模块没声明指纹（老格式包）→ 只要 node 在就算能用，沿用旧行为
  #   声明了指纹 → 必须逐个对上，否则就是换了 Node，得整块换
  _have_usr=0
  if [ -x "$RT_DIR/usr/bin/node" ]; then
    if [ -z "$MOD_USR_REV" ]; then
      _have_usr=1
    elif [ "$_dev_rev" = "$MOD_USR_REV" ]; then
      _have_usr=1
    fi
  fi

  # 两块都齐了就不用动：绝大多数「重启服务」走这条快路
  if [ "$_dev_ver" = "$RT_VERSION" ] && [ $_have_usr = 1 ]; then
    return 0
  fi

  # 老格式（v0.4.1 及更早）整包含 runtime-arm64.tgz，按原样整体解压
  if ! [ -f "$RT_CONTENT/app.tgz" ] && [ -f "$RT_CONTENT/runtime-arm64.tgz" ]; then
    stop_running
    _tmp="$RT_DIR.new"
    rm -rf "$_tmp"
    mkdir -p "$_tmp" || return 1
    tar -xzf "$RT_CONTENT/runtime-arm64.tgz" -C "$_tmp" || { rm -rf "$_tmp"; return 1; }
    chmod 0755 "$_tmp/usr/bin/node" || { rm -rf "$_tmp"; return 1; }
    printf '%s\n' "$RT_VERSION" >"$_tmp/.version"
    printf '%s\n' "$MOD_USR_REV" >"$_tmp/usr-rev"
    rm -rf "$RT_DIR"
    mv "$_tmp" "$RT_DIR" || { rm -rf "$_tmp"; return 1; }
    return 0
  fi

  # usr 对不上时，只有完整包能救
  if [ $_have_usr = 0 ]; then
    if [ -f "$RT_CONTENT/usr.tgz" ]; then
      stop_running
      swap_in usr || return 1
      chmod 0755 "$RT_DIR/usr/bin/node" || return 1
      printf '%s\n' "$MOD_USR_REV" >"$RT_DIR/usr-rev"
    else
      err_patch_mismatch "$_dev_rev"
      return 2
    fi
  fi

  [ -f "$RT_CONTENT/app.tgz" ] || {
    echo "模块缺少 runtime/app.tgz（服务代码）" >&2
    return 1
  }
  stop_running
  swap_in app || return 1

  printf '%s\n' "$RT_VERSION" >"$RT_DIR/.version"
  return 0
}

[ "$1" = now ] && ensure_runtime
