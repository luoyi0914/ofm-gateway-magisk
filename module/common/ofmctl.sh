#!/system/bin/sh
# 启停与状态查看。由 service.sh（开机）和 action.sh（KernelSU 动作按钮）共用。

# 模块目录解析：管理器/开机脚本的调用方式并不统一 —— Magisk 把目录放进 MODDIR 环境变量，
# KernelSU 则是 cd 到模块目录再 `sh <脚本>`（此时 $0 只有文件名，推不出目录）。
# 所以按「显式传入 → $0 所在目录 → 其上级目录 → cwd → cwd 上级」逐个试，
# 以「该目录里真有 config.sh」为准；都不成立才退回固定路径。
resolve_moddir() {
  for _c in "$OFM_MODDIR" "$MODDIR" "$_self_dir" "$_self_dir/.." "$(pwd)" "$(pwd)/.."; do
    [ -n "$_c" ] || continue
    if [ -f "$_c/config.sh" ]; then (cd "$_c" 2>/dev/null && pwd); return 0; fi
  done
  return 1
}
case "$0" in
  */*) _self_dir=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
  *) _self_dir= ;;
esac
_saved_moddir=$MODDIR
MODDIR=$(resolve_moddir) || MODDIR=${_saved_moddir:-/data/adb/modules/ofm_gateway}
. "$MODDIR/config.sh"

RT_DIR=/data/adb/ofm-runtime
NODE="$RT_DIR/usr/bin/node"
APP_DIR="$RT_DIR/app"
PIDFILE="$DATA_DIR/ofm.pid"
LOG_FILE="$DATA_DIR/ofm.log"
LOG_FIFO="$DATA_DIR/ofm.log.fifo"
LOG_PIDFILE="$DATA_DIR/ofm.log.pid"

# 输出会混着行尾的 \r（SSE 进度类日志），先统一成 \n 再打时间戳
stamp_lines() {
  tr '\r' '\n' | while IFS= read -r line; do
    printf '%s %s\n' "$(date '+%m/%d-%H:%M:%S')" "$line"
  done
}
ensure_dirs() {
  mkdir -p "$DATA_DIR"
  chmod 0700 "$DATA_DIR"
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  _pid=$(cat "$PIDFILE" 2>/dev/null)
  case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
  # PID 会被系统复用，光看 kill -0 会把别的进程误判为服务还在；
  # 再核一下命令行确实是本模块的 node
  kill -0 "$_pid" 2>/dev/null || return 1
  tr '\0' ' ' <"/proc/$_pid/cmdline" 2>/dev/null | grep -q 'standalone/cli.mjs'
}

# 上次异常退出会残留锁文件，服务会拒绝启动；只在确认无进程时清理
clear_stale_lock() {
  [ -f "$DATA_DIR/service.lock" ] || return 0
  if is_running; then return 0; fi
  rm -f "$DATA_DIR/service.lock"
}

port_of() {
  sed -n 's/.*"standalonePort": *\([0-9][0-9]*\).*/\1/p' "$DATA_DIR/settings.json" 2>/dev/null | head -n 1
}

key_of() {
  sed -n 's/.*"forwardKey": *"\([^"]*\)".*/\1/p' "$DATA_DIR/settings.json" 2>/dev/null | head -n 1
}

# 本机管理密钥（managementKey）。与 forwardKey（API Key）不同：
# 上游把「模型工作台 / Magpie 引擎 / 供应商 / 订阅 / 路由」等特权路由要求用
# managementKey（或启动时的一次性登录链接）登录控制台，仅用 forwardKey 登录
# 只是普通会话，访问特权页会 403。暴露它，方便用户在控制台里完成特权登录。
mgmt_key() {
  sed -n 's/.*"managementKey": *"\([^"]*\)".*/\1/p' "$DATA_DIR/settings.json" 2>/dev/null | head -n 1
}

lan_key_of() {
  sed -n 's/.*"standaloneLanKey": *"\([^"]*\)".*/\1/p' "$DATA_DIR/settings.json" 2>/dev/null | head -n 1
}

# 中继实际监听端口由服务运行期决定（LAN_PORT=0 时自动分配），
# 落盘的是 standaloneLanPort；未启用时该项可能停在 0
lan_port_of() {
  sed -n 's/.*"standaloneLanPort": *\([0-9][0-9]*\).*/\1/p' "$DATA_DIR/settings.json" 2>/dev/null | head -n 1
}

# 中继「实际」监听的端口。settings.json 里的 standaloneLanPort 只是请求值：
# LAN_PORT=0（自动分配）时它停在 0，真实端口只出现在服务启动日志的
# 「LAN API：http://<ip>:<port>/v1」一行里。这里取最近一次出现的端口，
# 取不到就返回空（调用方自行回退）。只扫日志尾部，避免 ofm.log 很长时拖慢 status/info。
lan_actual_port() {
  [ -f "$LOG_FILE" ] || return 0
  tail -n 3000 "$LOG_FILE" 2>/dev/null \
    | grep -a 'LAN API' | tail -n 1 \
    | sed -n 's#.*:\([0-9][0-9]*\)/v1.*#\1#p'
}

# 写配置。值由调用方校验过，这里只做整行替换，绝不拼接进 shell
save_config() {
  _key=$1
  _val=$2
  _tmp="$MODDIR/config.sh.tmp"
  sed "s|^$_key=.*|$_key=$_val|" "$MODDIR/config.sh" >"$_tmp" || return 1
  mv -f "$_tmp" "$MODDIR/config.sh"
}

start() {
  if is_running; then return 0; fi
  OFM_MODDIR="$MODDIR" sh "$MODDIR/common/runtime.sh" now || return 1
  clear_stale_lock
  rm -f "$PIDFILE"

  # 日志只追加不轮转，长期运行会无限增长。启动前若已超过 4 MB，
  # 只保留最近 2 MB，避免占满数据分区（单次运行期间仍可能继续增长）。
  if [ -f "$LOG_FILE" ]; then
    _sz=$(wc -c <"$LOG_FILE" 2>/dev/null || echo 0)
    if [ "${_sz:-0}" -gt 4194304 ]; then
      tail -c 2097152 "$LOG_FILE" >"$LOG_FILE.tmp" 2>/dev/null && mv -f "$LOG_FILE.tmp" "$LOG_FILE"
    fi
  fi

  cd "$APP_DIR" || return 1

  # arm64 Magpie 引擎随 usr 分发（方案 A，不放进 app 以免被自更新覆盖）。
  # 存在就通过 OFM_MAGPIE_BINARY 指向它（构建期补丁已把这个环境变量接进
  # createMagpieEngine）；不存在则留空，引擎退回上游原有查找逻辑（通常不可用）。
  OFM_MAGPIE_BINARY=
  if [ -x "$RT_DIR/usr/bin/magpie-android-arm64" ]; then
    OFM_MAGPIE_BINARY="$RT_DIR/usr/bin/magpie-android-arm64"
  fi

  # 服务只在回环地址上监听；局域网是上游自己的中继（独立 Key），
  # 由 --lan / --no-lan 开关，并可从配置里指定端口。
  # 用位置参数逐个传递，逐项加引号，避免 DATA_DIR 等含空格时被再次分词。
  set -- --data-dir "$DATA_DIR"
  [ "$PORT" = "0" ] || set -- --port "$PORT" "$@"
  if [ "$LAN" = "1" ]; then
    set -- "$@" --lan
    [ "$LAN_PORT" = "0" ] || set -- "$@" --lan-port "$LAN_PORT"
  else
    set -- "$@" --no-lan
  fi

  # 服务输出先进 FIFO，由 stamp_lines 加时间戳再落盘。
  # 这样 node 的 PID 仍是真实进程（$!），启停不受管道影响。
  rm -f "$LOG_FIFO"
  if ! mkfifo -m 0600 "$LOG_FIFO" 2>/dev/null; then
    # 无法建 FIFO（FIFO 文件系统不支持或目录权限）时退化为直接写日志，
    # 否则服务根本起不来
    OFM_HOME="$DATA_DIR" HOME="$MODDIR" OFM_MAGPIE_BINARY="$OFM_MAGPIE_BINARY" \
      "$NODE" packages/standalone/cli.mjs "$@" >>"$LOG_FILE" 2>&1 &
    echo $! >"$PIDFILE"
    return 0
  fi
  ( stamp_lines <"$LOG_FIFO" >>"$LOG_FILE" ) &
  echo $! >"$LOG_PIDFILE"

  OFM_HOME="$DATA_DIR" HOME="$MODDIR" OFM_MAGPIE_BINARY="$OFM_MAGPIE_BINARY" \
    "$NODE" packages/standalone/cli.mjs "$@" >"$LOG_FIFO" 2>&1 &
  echo $! >"$PIDFILE"
}

stop() {
  if ! is_running; then
    # 进程已不在，但可能残留文件；一并清掉再返回
    [ -f "$LOG_PIDFILE" ] && kill "$(cat "$LOG_PIDFILE")" 2>/dev/null
    rm -f "$PIDFILE" "$LOG_PIDFILE" "$LOG_FIFO" "$DATA_DIR/service.lock"
    return 0
  fi
  _pid=$(cat "$PIDFILE")
  kill "$_pid" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$_pid" 2>/dev/null || break
    sleep 1
  done
  # SIGTERM 后等不到再上 SIGKILL，再给它一点回收时间，
  # 否则下面立即判断可能读到刚发完信号但尚未退出的进程
  if kill -0 "$_pid" 2>/dev/null; then
    kill -9 "$_pid" 2>/dev/null
    sleep 1
  fi
  # 停掉加时间戳的读取进程，否则它在 FIFO 上一直等
  [ -f "$LOG_PIDFILE" ] && kill "$(cat "$LOG_PIDFILE")" 2>/dev/null
  rm -f "$PIDFILE" "$LOG_PIDFILE" "$LOG_FIFO" "$DATA_DIR/service.lock"
}

case "$1" in
  start) ensure_dirs; start ;;
  stop) stop ;;
  restart) stop; ensure_dirs; start ;;
  status)
    if is_running; then
      PORT_NOW=$(port_of)
      [ -n "$PORT_NOW" ] || PORT_NOW=$PORT
      echo "运行中 (pid $(cat "$PIDFILE"))"
      echo "地址：http://127.0.0.1:$PORT_NOW/v1"
      echo "密钥：$(key_of)"
      echo "管理密钥：$(mgmt_key)（进入模型工作台/引擎等特权功能，需用它登录控制台）"
      if [ "$LAN" = "1" ]; then
        _lp=$(lan_port_of)
        # LAN_PORT=0（自动分配）时落盘的是 0，改用启动日志里的实际端口
        if [ -z "$_lp" ] || [ "$_lp" = "0" ]; then
          _lp=$(lan_actual_port)
        fi
        echo "局域网：端口 ${_lp:-0}，Key $(lan_key_of)"
      else
        echo "局域网：未开启"
      fi
      echo "日志：$LOG_FILE"
    else
      echo "未运行"
    fi
    ;;
  # 供 WebUI 解析的机器可读输出，一行一个 key=value
  info)
    if is_running; then
      _isrun=1
      echo "running=1"
      echo "pid=$(cat "$PIDFILE")"
    else
      _isrun=0
      echo "running=0"
      echo "pid="
    fi
    PORT_NOW=$(port_of)
    [ -n "$PORT_NOW" ] || PORT_NOW=$PORT
    echo "port=$PORT_NOW"
    echo "host=127.0.0.1"
    echo "key=$(key_of)"
    echo "mgmt_key=$(mgmt_key)"
    echo "lan=$LAN"
    _lan_req=$(lan_port_of)
    echo "lan_port=$_lan_req"
    # 供 WebUI 展示的真实端口：落盘值若是 0（自动分配）且服务在跑，
    # 就回退到启动日志里的实际端口；否则直接用落盘值
    _lan_actual=$_lan_req
    if [ -z "$_lan_actual" ] || [ "$_lan_actual" = "0" ]; then
      if [ "$_isrun" = "1" ]; then
        _lan_actual=$(lan_actual_port)
      fi
    fi
    echo "lan_actual_port=${_lan_actual:-0}"
    echo "lan_key=$(lan_key_of)"
    echo "autostart=$AUTOSTART"
    echo "data_dir=$DATA_DIR"
    echo "log_file=$LOG_FILE"
    echo "runtime=$(cat "$RT_DIR/.version" 2>/dev/null)"
    ;;
  # 只允许 WebUI 改这几项，且值必须通过校验；不做任意写
  set-config)
    case "$2" in
      port)
        case "$3" in ''|*[!0-9]*) echo "端口必须是数字" >&2; exit 1 ;; esac
        [ "$3" -le 65535 ] || { echo "端口超出范围" >&2; exit 1; }
        save_config PORT "$3" || exit 1
        ;;
      lan)
        case "$3" in
          0|1) save_config LAN "$3" || exit 1 ;;
          *) echo "局域网开关只能是 0 或 1" >&2; exit 1 ;;
        esac
        ;;
      lan_port)
        case "$3" in ''|*[!0-9]*) echo "局域网端口必须是数字" >&2; exit 1 ;; esac
        [ "$3" -le 65535 ] || { echo "端口超出范围" >&2; exit 1; }
        save_config LAN_PORT "$3" || exit 1
        ;;
      autostart)
        case "$3" in
          0|1) save_config AUTOSTART "$3" || exit 1 ;;
          *) echo "开机自启只能是 0 或 1" >&2; exit 1 ;;
        esac
        ;;
      *) echo "未知配置项：$2" >&2; exit 1 ;;
    esac
    ;;
  log)
    _n=${2:-40}
    case "$_n" in ''|*[!0-9]*) _n=40 ;; esac
    [ -f "$LOG_FILE" ] || { echo "暂无日志"; exit 0; }
    tail -n "$_n" "$LOG_FILE"
    ;;
  # 控制台数据：用 API Key 换会话再拉摘要，密钥不进 URL、不落盘。
  # 会话 cookie 从响应头里取、再用 Cookie 头带回：不依赖 curl 的 -c/-b cookie jar
  # （部分环境里的 curl 是只支持 -s/-H/-d/-o 的精简垫片，-c/-b 会让请求直接失败）
  console)
    _port=$(port_of)
    [ -n "$_port" ] || _port=$PORT
    _key=$(key_of)
    [ -n "$_key" ] || { echo "尚未生成 API Key" >&2; exit 1; }
    command -v curl >/dev/null 2>&1 || { echo "缺少 curl，无法读取控制台" >&2; exit 1; }
    _base="http://127.0.0.1:$_port"
    _payload=$(printf '{"key":"%s"}' "$_key")
    _resp=$(curl -s -i -m 10 -X POST "$_base/api/management/session" \
        -H 'Content-Type: application/json' -H "Origin: $_base" -d "$_payload" 2>/dev/null)
    [ -n "$_resp" ] || { echo "无法连接服务" >&2; exit 1; }
    # 取第一段 Set-Cookie 的 name=value（到分号为止）
    _ck=$(printf '%s\n' "$_resp" | sed -n 's/^[Ss]et-[Cc]ookie: *\([^;]*\).*/\1/p' | head -n 1 | tr -d '\r')
    [ -n "$_ck" ] || { echo "登录控制台失败（API Key 可能已更换）" >&2; exit 1; }
    _sum=$(curl -s -m 15 -H "Cookie: $_ck" "$_base/api/management/summary" 2>/dev/null)
    [ -n "$_sum" ] || { echo "读取控制台数据失败" >&2; exit 1; }
    printf '%s\n' "$_sum"
    ;;
  # 打印本机管理密钥，供在控制台完成「特权登录」（模型工作台/引擎需要）
  mgmt-key)
    _k=$(mgmt_key)
    [ -n "$_k" ] || { echo "尚未生成管理密钥（先启动一次服务再试）" >&2; exit 1; }
    printf '%s\n' "$_k"
    ;;
  *) echo "用法：$0 start|stop|restart|status|info|set-config|log|console|mgmt-key" >&2; exit 1 ;;
esac
