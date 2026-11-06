#!/system/bin/sh
# 启停与状态查看。由 service.sh（开机）、action.sh（动作按钮）、
# ofmd.sh（守护进程）和 webroot/index.html（面板）共用。
#
# 启停的分工（v0.6.0 起）：
#   真正起停服务的只有 ofmd.sh 这个常驻守护进程，本脚本的 start/stop/restart
#   只负责「投递请求 + 等结果」。原因是面板里的 exec 跑在管理器 App 的会话里，
#   由它直接起的进程继承 App 的 cgroup，App 一退就被系统回收 ——
#   setsid / nohup 都改变不了 cgroup 归属（KernelSU-Next #1180）。
#   守护进程由开机脚本或动作按钮拉起时落在开机域里，面板退出不影响它。
#
# 被 ofmd.sh 以 OFM_LIB_ONLY=1 引用时只加载函数，不执行末尾的命令分发。

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

# 上游服务锁里记录的产品名（packages/standalone/service.mjs 的 PRODUCT）。
# 判定陈旧锁时要用它，否则会把别的程序写在同名文件里的锁删掉。
UPSTREAM_PRODUCT=our-free-model-standalone
# 服务入口（相对于 APP_DIR）。判活时核这一串，避免 PID 复用误判。
APP_ENTRY=packages/standalone/cli.mjs

ofm_paths() {
  RT_DIR=/data/adb/ofm-runtime
  NODE="$RT_DIR/usr/bin/node"
  APP_DIR="$RT_DIR/app"
  PIDFILE="$DATA_DIR/ofm.pid"
  # 日志按天分文件：$DATA_DIR/logs/ofm-YYYY-MM-DD.log
  # LOG_FILE 保留为旧版单文件日志路径，仅作兼容回退（从旧版升级后旧日志仍可读）
  LOG_DIR="$DATA_DIR/logs"
  LOG_FILE="$DATA_DIR/ofm.log"
  # 旧版（0.5.x）的 FIFO 日志链留下两个文件，现在只剩清理作用
  LOG_FIFO="$DATA_DIR/ofm.log.fifo"
  LOG_PIDFILE="$DATA_DIR/ofm.log.pid"
  LOG_KEEP_DAYS=${LOG_KEEP_DAYS:-14}

  # 守护进程（ofmd.sh）的运行时文件。请求/结果各占一个文件，天然支持并发投递：
  #   queue/<id>.req  投递的请求，内容是一行动作名
  #   queue/<id>.res  执行结果，第一行形如「<rc> <人类可读消息>」
  CONTROL_DIR="$DATA_DIR/control"
  QUEUE_DIR="$CONTROL_DIR/queue"
  OFMD_PIDFILE="$CONTROL_DIR/ofmd.pid"
  OFMD_STARTED="$CONTROL_DIR/ofmd.started"
  OFMD_CGROUP="$CONTROL_DIR/ofmd.cgroup"
  OFMD_PERSIST="$CONTROL_DIR/ofmd.persistent"
  OFMD_LOCKDIR="$CONTROL_DIR/ofmd.lock"
  OFMD_LOG="$CONTROL_DIR/ofmd.log"
  # 「服务应该处于运行状态」的意图标记：开机自启或用户点过启动置 1，点停止置 0。
  # 守护进程据此判断 node 意外退出该不该重新拉起。
  OFMD_WANT="$CONTROL_DIR/want_running"
}
ofm_paths

# config.sh 里可改的不只是端口，改完重启服务就该生效，
# 所以这里重新读一遍并重算路径，避免守护进程一直用着启动时的旧值。
reload_config() {
  . "$MODDIR/config.sh" 2>/dev/null || return 1
  ofm_paths
}

# ---- 按天日志相关辅助 ----

# 日期格式必须是 YYYY-MM-DD，供 WebUI 传参时防路径穿越
valid_day() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# 最新一份日志：优先最新的分天文件，没有则回退旧版单文件 ofm.log
latest_log_file() {
  _ll=$(ls -1 "$LOG_DIR"/ofm-*.log 2>/dev/null | sort -r | head -n 1)
  if [ -n "$_ll" ]; then printf '%s' "$_ll"; return 0; fi
  if [ -f "$LOG_FILE" ]; then printf '%s' "$LOG_FILE"; return 0; fi
  return 1
}

# 只保留最近 $LOG_KEEP_DAYS 个分天文件，更早的删除
cleanup_old_logs() {
  [ -d "$LOG_DIR" ] || return 0
  _keep=$LOG_KEEP_DAYS
  case "$_keep" in ''|*[!0-9]*) _keep=14 ;; esac
  [ "$_keep" -ge 1 ] || return 0
  _cnt=$(ls -1 "$LOG_DIR"/ofm-*.log 2>/dev/null | wc -l)
  [ "$_cnt" -gt "$_keep" ] || return 0
  ls -1 "$LOG_DIR"/ofm-*.log 2>/dev/null | sort | head -n $((_cnt - _keep)) | while IFS= read -r _old; do
    rm -f "$_old"
  done
}

# 今天的日志文件路径
today_log() {
  printf '%s/ofm-%s.log' "$LOG_DIR" "$(date '+%Y-%m-%d')"
}

# 往日志里写一行模块自己的记录（服务输出本身由 node 直接写，见 svc_start 注释）
log_note() {
  _msg=$1
  mkdir -p "$LOG_DIR" 2>/dev/null
  chmod 0700 "$LOG_DIR" 2>/dev/null
  printf '[ofmd] %s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$_msg" >>"$(today_log)" 2>/dev/null
  cleanup_old_logs
}

# 单个日志文件超过 4MB 时截到 2MB：防止某天日志异常膨胀占满数据分区
trim_log() {
  _lf=$(latest_log_file) || return 0
  [ -n "$_lf" ] && [ -f "$_lf" ] || return 0
  _sz=$(wc -c <"$_lf" 2>/dev/null || echo 0)
  if [ "${_sz:-0}" -gt 4194304 ]; then
    tail -c 2097152 "$_lf" >"$_lf.tmp" 2>/dev/null && mv -f "$_lf.tmp" "$_lf"
  fi
}

# ---- 进程判定 ----

pid_alive() {
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$1" 2>/dev/null
}

pid_cmdline() {
  tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null
}

# 进程是否「真正退出」：僵尸（state=Z）已经不再运行，只是父进程还没回收它，
# kill -0 对僵尸仍然返回成功。停服务时若把僵尸当成「还在跑」，
# 就会误报「停止失败」——尤其是停服务这段代码跑在命令替换的子 shell 里、
# 父进程正等着我们返回、没法及时去回收子进程的时候。
pid_gone() {
  case "$1" in ''|*[!0-9]*) return 0 ;; esac
  kill -0 "$1" 2>/dev/null || return 0
  [ "$(sed -n '1s/.*) //p' "/proc/$1/stat" 2>/dev/null | awk '{print $1}')" = "Z" ] && return 0
  return 1
}

# /proc/<pid>/stat 里 comm 字段带括号、可能含空格，所以先截掉最后一个 ')'，
# 之后第 3 段是 pgrp、第 4 段是 session
pid_pgrp() {
  sed -n '1s/.*) //p' "/proc/$1/stat" 2>/dev/null | awk '{print $3}'
}
pid_sid() {
  sed -n '1s/.*) //p' "/proc/$1/stat" 2>/dev/null | awk '{print $4}'
}

# 轮询粒度。toybox/busybox 的 sleep 都支持小数秒，但个别精简 ROM 只认整数，
# 此时 `sleep 0.2` 会直接失败并立刻返回 —— 若还按次数循环，「等 5 秒」就会在
# 几十毫秒内跑完，于是守护进程还没起好就报失败、请求还没处理就报「处理中」。
# 所以先实测一次，把粒度记住，后面的等待都按实测粒度折算成次数。
_ofm_step() {
  if [ -z "${_OFM_STEP:-}" ]; then
    if sleep 0.2 2>/dev/null; then _OFM_STEP=0.2; else _OFM_STEP=1; fi
  fi
  printf '%s' "$_OFM_STEP"
}

# 等某个条件成立，最多等 $1 秒；条件为 $2 起的命令。
# 次数由实测粒度折算，所以不论 sleep 支持不支持小数，总时长都接近 $1 秒。
wait_until() {
  _wu_secs=$1; shift
  _ofm_step >/dev/null   # 直接调用、不用命令替换，探测结果才能留在当前 shell
  case "$_OFM_STEP" in
    0.2) _wu_lim=$((_wu_secs * 5)) ;;
    *)   _wu_lim=$_wu_secs ;;
  esac
  _wu_i=0
  while [ "$_wu_i" -lt "$_wu_lim" ]; do
    "$@" && return 0
    _wu_i=$((_wu_i + 1))
    sleep "$_OFM_STEP" 2>/dev/null || sleep 1
  done
  # 到点再确认一次：最后一次睡眠期间可能刚好达成
  "$@"
}

ensure_dirs() {
  mkdir -p "$DATA_DIR" "$LOG_DIR" "$QUEUE_DIR"
  chmod 0700 "$DATA_DIR" 2>/dev/null
  chmod 0700 "$LOG_DIR" 2>/dev/null
  chmod 0700 "$CONTROL_DIR" "$QUEUE_DIR" 2>/dev/null
}

is_running() {
  [ -f "$PIDFILE" ] || return 1
  _pid=$(cat "$PIDFILE" 2>/dev/null)
  case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
  # PID 会被系统复用，光看 kill -0 会把别的进程误判为服务还在；
  # 再核一下命令行确实是本模块的 node
  pid_alive "$_pid" || return 1
  pid_cmdline "$_pid" | grep -q "$APP_ENTRY"
}

# 上游 service.lock 的自愈判定。
#
# 上游只在 win32/linux 上装进程守卫，Android 上 process.platform='android'，
# acquireProcessGuard() 直接返回 null，于是「EEXIST 即抛错」，陈旧锁永远不会被回收
# —— 表现就是面板点「启动」永远失败。所以模块侧必须自己按同一语义判定。
#
# 上游的保守判据是「只有 ESRCH 能证明进程已退出」。模块以 root 运行、能读 /proc，
# 这里用更强的身份判据：锁里记的 pid 即使还活着，只要它的命令行不是本模块的
# node（那就是 PID 复用，原主早没了），也判定为陈旧。宁可多清一次锁，
# 也不把一个活着的不相干进程当成锁主人；反过来，命令行对得上就绝不删。
# 返回值：0 = 锁不存在或已清掉；1 = 有活跃的锁主人，不能启动。
heal_stale_lock() {
  [ -f "$LOG_FIFO" ] && rm -f "$LOG_FIFO" "$LOG_PIDFILE"
  [ -f "$DATA_DIR/service.lock" ] || return 0

  _lock=$DATA_DIR/service.lock
  is_running && return 1

  _owner_pid=$(sed -n 's/.*"pid": *\([0-9][0-9]*\).*/\1/p' "$_lock" 2>/dev/null | head -n 1)
  _owner_product=$(sed -n 's/.*"product": *"\([^"]*\)".*/\1/p' "$_lock" 2>/dev/null | head -n 1)

  # 不是上游写的锁（或压根不是 JSON）：不认识就不动，交给调用方报错
  if [ "$_owner_product" != "$UPSTREAM_PRODUCT" ]; then
    echo "数据目录里的 service.lock 不属于本服务（product=${_owner_product:-空}），未自动清理" >&2
    return 1
  fi
  if [ -z "$_owner_pid" ]; then
    echo "service.lock 内容无法解析出 pid，未自动清理" >&2
    return 1
  fi

  if pid_alive "$_owner_pid"; then
    if pid_cmdline "$_owner_pid" | grep -q "$APP_ENTRY"; then
      # 真的是本模块的服务还活着（pidfile 丢了），不能删锁
      echo "service.lock 的主进程（pid $_owner_pid）仍在运行" >&2
      return 1
    fi
    log_note "回收陈旧锁：pid $_owner_pid 已被其他进程复用（命令行不匹配）"
  else
    log_note "回收陈旧锁：pid $_owner_pid 已退出"
  fi
  rm -f "$_lock"
  return 0
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
# 取不到就返回空（调用方自行回退）。只扫日志尾部，避免日志很长时拖慢 status/info。
lan_actual_port() {
  _lf=$(latest_log_file) || return 0
  [ -n "$_lf" ] && [ -f "$_lf" ] || return 0
  tail -n 3000 "$_lf" 2>/dev/null \
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

# ---- 守护进程判定 ----

daemon_alive() {
  [ -f "$OFMD_PIDFILE" ] || return 1
  _dp=$(cat "$OFMD_PIDFILE" 2>/dev/null)
  pid_alive "$_dp" || return 1
  pid_cmdline "$_dp" | grep -q 'ofmd.sh'
}

# 0 = 守护进程跑在 App 的 cgroup 里（退出管理器会被回收），1 = 落在系统域
daemon_persistent() {
  _pv=$(cat "$OFMD_PERSIST" 2>/dev/null)
  case "$_pv" in 0|1) printf '%s' "$_pv" ;; *) printf '0' ;; esac
}

# 确保守护进程在跑。$1 = 来源（boot / action / webui / auto），
# 只影响「保活能力」的标注，不影响启动方式。
daemon_ensure() {
  ensure_dirs
  daemon_alive && return 0
  _src=${1:-auto}
  rm -f "$OFMD_PIDFILE"
  # 三个 fd 全部脱离调用方：面板的 exec 会等命令的 stdout 关闭，
  # 守护进程要是继承了它，这条命令就会一直挂着不返回。
  if command -v setsid >/dev/null 2>&1; then
    OFM_MODDIR="$MODDIR" OFM_DAEMON_SOURCE="$_src" \
      setsid sh "$MODDIR/common/ofmd.sh" </dev/null >/dev/null 2>&1 &
  else
    OFM_MODDIR="$MODDIR" OFM_DAEMON_SOURCE="$_src" \
      nohup sh "$MODDIR/common/ofmd.sh" </dev/null >>"$OFMD_LOG" 2>&1 &
  fi
  wait_until 5 daemon_alive
}

# 停掉守护进程（卸载、或用户明确要求时用）。服务本身不随之退出。
daemon_stop() {
  if ! daemon_alive; then
    rm -f "$OFMD_PIDFILE"
    return 0
  fi
  _dp=$(cat "$OFMD_PIDFILE" 2>/dev/null)
  kill -TERM "$_dp" 2>/dev/null
  wait_until 5 pid_gone "$_dp"
  pid_gone "$_dp" || kill -KILL "$_dp" 2>/dev/null
  rm -f "$OFMD_PIDFILE"
  return 0
}

# ---- 服务本体 ----

# 这是唯一真正启动服务的地方，只该由守护进程调用。
svc_start() {
  reload_config
  if is_running; then
    echo "服务已在运行（pid $(cat "$PIDFILE")）"
    return 0
  fi
  OFM_MODDIR="$MODDIR" sh "$MODDIR/common/runtime.sh" now || {
    echo "运行时准备失败（解压或版本不匹配）"
    return 1
  }
  heal_stale_lock || return 1
  rm -f "$PIDFILE"
  trim_log
  ensure_dirs

  cd "$APP_DIR" || { echo "运行时目录不存在：$APP_DIR"; return 1; }

  # arm64 Magpie 引擎随 usr 分发（方案 A，不放进 app 以免被自更新覆盖）。
  # 存在就通过 OFM_MAGPIE_BINARY 指向它（构建期补丁已把这个环境变量接进
  # createMagpieEngine）；不存在则留空，引擎退回上游原有查找逻辑（通常不可用）。
  OFM_MAGPIE_BINARY=
  if [ -x "$RT_DIR/usr/bin/magpie-android-arm64" ]; then
    OFM_MAGPIE_BINARY="$RT_DIR/usr/bin/magpie-android-arm64"
  fi

  # Bun 同理：引擎默认会把 bun 下载到 $HOME/.cache/magpie/bun/<ver>/magpie-bun 再
  # fork/exec。模块版是 root，落盘目录其实可执行，但「随包分发」能省掉一次 33MB 的
  # 联网下载，也让弱网/无网设备能装插件。构建期补丁把它接成 MAGPIE_BUN。
  OFM_MAGPIE_BUN=
  if [ -x "$RT_DIR/usr/bin/magpie-bun" ]; then
    OFM_MAGPIE_BUN="$RT_DIR/usr/bin/magpie-bun"
  fi

  # 服务只在回环地址上监听；局域网是上游自己的中继（独立 Key），
  # 由 --lan / --no-lan 开关，并可从配置里指定端口。
  # 用位置参数逐个传递、逐项加引号，避免 DATA_DIR 等含空格时被再次分词。
  set -- --data-dir "$DATA_DIR"
  [ "$PORT" = "0" ] || set -- --port "$PORT" "$@"
  if [ "$LAN" = "1" ]; then
    set -- "$@" --lan
    [ "$LAN_PORT" = "0" ] || set -- "$@" --lan-port "$LAN_PORT"
  else
    set -- "$@" --no-lan
  fi

  _logf=$(today_log)
  mkdir -p "$LOG_DIR" 2>/dev/null
  log_note "启动服务（pid 由本进程写入 $PIDFILE）"

  # 服务输出直接追加进当天的日志文件：不经管道、不经 FIFO。
  # 旧版走 FIFO 让 log_writer 加时间戳，但 FIFO 只有单个读者，
  # 读端一死 node 下一次写 stdout 就会触发 EPIPE 直接退出（实测约 1.2 秒），
  # 于是「服务莫名其妙掉了」。日志好看不如进程活着。
  #
  # setsid 让 node 自成会话/进程组，停止时按进程组收敛，Magpie 子进程不会变孤儿。
  # pid 由内层 shell 自己写（$$ 就是它 exec 之后的 node 的 pid）：
  # 外层用 `$!` 拿到的可能是 setsid 的包装进程，尤其是本进程已是组长时。
  if command -v setsid >/dev/null 2>&1; then
    OFM_HOME="$DATA_DIR" HOME="$MODDIR" OFM_MAGPIE_BINARY="$OFM_MAGPIE_BINARY" OFM_MAGPIE_BUN="$OFM_MAGPIE_BUN" \
      setsid sh -c 'printf "%s\n" "$$" >"$1"; shift; exec "$@"' \
        ofm-node "$PIDFILE" "$NODE" "$APP_ENTRY" "$@" \
        >>"$_logf" 2>&1 </dev/null &
  else
    # 没有 setsid（极老的 toybox / Magisk v31 起不再自带 busybox）时退化为普通子进程：
    # 停止仍能按 pid 收敛，只是 Magpie 子进程可能成孤儿，启动日志里留一条记录。
    log_note "警告：本机没有 setsid，服务不独立成会话"
    OFM_HOME="$DATA_DIR" HOME="$MODDIR" OFM_MAGPIE_BINARY="$OFM_MAGPIE_BINARY" OFM_MAGPIE_BUN="$OFM_MAGPIE_BUN" \
      sh -c 'printf "%s\n" "$$" >"$1"; shift; exec "$@"' \
        ofm-node "$PIDFILE" "$NODE" "$APP_ENTRY" "$@" \
        >>"$_logf" 2>&1 </dev/null &
  fi

  wait_until 6 is_running
  cleanup_old_logs

  if is_running; then
    echo "服务已启动（pid $(cat "$PIDFILE")，端口 $(port_of | grep . || printf '%s' "$PORT")）"
    return 0
  fi
  # 起不来时把日志里最后几行带出去，否则面板只会显示「失败」而无从排查
  _tail=$(tail -n 3 "$_logf" 2>/dev/null | tr '\n' ' ' | tr -s ' ')
  echo "服务启动失败：${_tail:-没有输出，请查看日志}"
  return 1
}

# 停止服务：按进程组 TERM → 等 → KILL → 确认无残留。只该由守护进程调用。
svc_stop() {
  reload_config
  if ! is_running; then
    # 进程已不在，但可能残留文件；一并清掉
    rm -f "$PIDFILE" "$LOG_PIDFILE" "$LOG_FIFO"
    # 锁若还有主（比如手工起的服务），heal_stale_lock 会拒绝删，这里忽略其结论
    heal_stale_lock >/dev/null 2>&1
    echo "服务本来就没在运行"
    return 0
  fi
  _pid=$(cat "$PIDFILE")
  _sid=$(pid_sid "$_pid")
  _use_group=0
  [ "$_sid" = "$_pid" ] && _use_group=1

  if [ "$_use_group" = 1 ]; then
    kill -TERM -"$_pid" 2>/dev/null
  else
    kill -TERM "$_pid" 2>/dev/null
  fi

  wait_until 10 pid_gone "$_pid"
  # SIGTERM 后等不到再上 SIGKILL，再给它一点回收时间
  if ! pid_gone "$_pid"; then
    if [ "$_use_group" = 1 ]; then kill -KILL -"$_pid" 2>/dev/null; else kill -KILL "$_pid" 2>/dev/null; fi
    sleep 1
  fi

  # 兜底：进程组收敛没成功时（node 不是组长、或旧版留下的孤儿），
  # 按命令行清掉本运行时的 Magpie 子进程
  for _p in $(pidof magpie-android-arm64 2>/dev/null); do
    pid_cmdline "$_p" | grep -q "$RT_DIR" && kill -TERM "$_p" 2>/dev/null
  done
  # bun 是引擎的子进程，同组收敛通常已经带走；漏网的按同样方式清掉
  for _p in $(pidof magpie-bun 2>/dev/null); do
    pid_cmdline "$_p" | grep -q "$RT_DIR" && kill -TERM "$_p" 2>/dev/null
  done

  rm -f "$PIDFILE" "$LOG_PIDFILE" "$LOG_FIFO"
  heal_stale_lock >/dev/null 2>&1
  log_note "服务已停止"
  if ! pid_gone "$_pid"; then
    echo "停止失败：pid $_pid 仍在运行"
    return 1
  fi
  echo "服务已停止"
  return 0
}

# ---- 请求投递（面板 / 动作按钮 / 开机脚本用） ----

# 把动作投递给守护进程并等结果，最多等 $2 秒（默认 12）。
# 输出一行：id=<id> rc=<0|1|2> msg=<单行说明>
#   rc=0 执行成功  rc=1 执行失败  rc=2 超时未完成（不代表失败，调用方继续查状态）
submit_action() {
  _act=$1
  _wait=${2:-12}
  ensure_dirs
  _id="$(date '+%s')-$$-$_act"

  if ! daemon_ensure "${OFM_CLIENT:-webui}"; then
    # 守护进程起不来时的兜底：直接启停，但必须说清代价
    case "$_act" in
      start) _out=$(svc_start 2>&1); _rc=$? ;;
      stop) _out=$(svc_stop 2>&1); _rc=$? ;;
      restart) _out=$(svc_stop 2>&1); _out2=$(svc_start 2>&1); _rc=$?; _out="$_out2" ;;
      *) printf 'id=%s rc=1 msg=未知动作：%s\n' "$_id" "$_act"; return 1 ;;
    esac
    _msg=$(printf '%s' "${_out:-完成}" | tr '\n' ' ' | tr -s ' ')
    printf 'id=%s rc=%s msg=守护进程不可用，已直接执行（退出管理器后可能被回收）：%s\n' \
      "$_id" "${_rc:-1}" "$_msg"
    return 0
  fi

  printf '%s\n' "$_act" >"$QUEUE_DIR/$_id.req.tmp" 2>/dev/null &&
    mv -f "$QUEUE_DIR/$_id.req.tmp" "$QUEUE_DIR/$_id.req" 2>/dev/null || {
      printf 'id=%s rc=1 msg=投递请求失败（队列目录不可写）\n' "$_id"
      return 1
    }

  # 等结果文件出现（守护进程处理完才写）；到点还没有就报「处理中」，由面板继续轮询 info
  _res_seen() { [ -f "$QUEUE_DIR/$_id.res" ]; }
  wait_until "$_wait" _res_seen

  if [ -f "$QUEUE_DIR/$_id.res" ]; then
    _line=$(sed -n '1p' "$QUEUE_DIR/$_id.res" 2>/dev/null)
    rm -f "$QUEUE_DIR/$_id.res"
    _rc=${_line%% *}
    _msg=${_line#* }
    [ "$_rc" = "$_line" ] && _msg=
    case "$_rc" in ''|*[!0-9]*) _rc=1 ;; esac
    [ -n "$_msg" ] || _msg=完成
    printf 'id=%s rc=%s msg=%s\n' "$_id" "$_rc" "$_msg"
    return 0
  fi
  printf 'id=%s rc=2 msg=处理中\n' "$_id"
  return 0
}

# 供守护进程写结果用（它自己调用，避免和面板抢同一个文件）
write_result() {
  _id=$1; _rc=$2; _msg=$3
  _msg=$(printf '%s' "$_msg" | tr '\n' ' ' | tr -s ' ')
  printf '%s %s\n' "$_rc" "${_msg:-完成}" >"$QUEUE_DIR/$_id.res.tmp" 2>/dev/null &&
    mv -f "$QUEUE_DIR/$_id.res.tmp" "$QUEUE_DIR/$_id.res" 2>/dev/null
}

# ---- 命令分发（被 ofmd.sh 引用时不执行） ----

if [ "${OFM_LIB_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

case "$1" in
  # 这三个不再直接起停服务，只投递请求给守护进程
  start) ensure_dirs; submit_action start 20 ;;
  stop) ensure_dirs; submit_action stop "${2:-15}" ;;
  restart) ensure_dirs; submit_action restart 25 ;;
  # 面板用的统一入口：把动作名当参数传，输出格式与上面三个相同。
  # 面板只认这一条协议，动作名由前端给，脚本侧不猜。
  submit)
    case "$2" in
      start|stop|restart) ensure_dirs; submit_action "$2" "${3:-12}" ;;
      *) echo "用法：$0 submit start|stop|restart [等待秒数]" >&2; exit 1 ;;
    esac
    ;;
  # 守护进程内部用（ofmd.sh 通过引用本文件直接调函数，这里留一份 CLI 入口便于排错）
  __svc-start) ensure_dirs; svc_start ;;
  __svc-stop) svc_stop ;;
  daemon)
    case "$2" in
      start) daemon_ensure "${3:-auto}" && echo "守护进程已就绪（pid $(cat "$OFMD_PIDFILE")）" ;;
      stop) daemon_stop && echo "守护进程已停止" ;;
      status)
        if daemon_alive; then
          echo "running=1"
          echo "pid=$(cat "$OFMD_PIDFILE")"
          echo "persistent=$(daemon_persistent)"
          echo "cgroup=$(cat "$OFMD_CGROUP" 2>/dev/null | tr '\n' ' ')"
        else
          echo "running=0"
        fi
        ;;
      *) echo "用法：$0 daemon start|stop|status" >&2; exit 1 ;;
    esac
    ;;
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
      echo "日志目录：$LOG_DIR（按天 ofm-YYYY-MM-DD.log）"
    else
      echo "未运行"
    fi
    if daemon_alive; then
      if [ "$(daemon_persistent)" = "1" ]; then
        echo "守护进程：运行中（pid $(cat "$OFMD_PIDFILE")，系统域，管理器退出不受影响）"
      else
        echo "守护进程：运行中（pid $(cat "$OFMD_PIDFILE")，降级模式：由管理器会话拉起，退出管理器可能被回收）"
      fi
    else
      echo "守护进程：未运行（面板启停需要它；重启手机或点「动作」按钮可恢复）"
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
    echo "log_dir=$LOG_DIR"
    echo "log_file=$(latest_log_file 2>/dev/null || printf '%s' "$LOG_DIR/ofm-$(date '+%Y-%m-%d').log")"
    echo "log_keep_days=$LOG_KEEP_DAYS"
    echo "runtime=$(cat "$RT_DIR/.version" 2>/dev/null)"
    echo "module_version=$(sed -n 's/^version=//p' "$MODDIR/module.prop" 2>/dev/null)"
    echo "device_model=$(getprop ro.product.model 2>/dev/null)"
    echo "android_version=$(getprop ro.build.version.release 2>/dev/null)"
    echo "abi=$(getprop ro.product.cpu.abi 2>/dev/null)"
    # 面板据此决定要不要显示「降级/无守护进程」的警示
    if daemon_alive; then
      echo "daemon=1"
      echo "daemon_pid=$(cat "$OFMD_PIDFILE")"
      echo "daemon_persistent=$(daemon_persistent)"
    else
      echo "daemon=0"
      echo "daemon_pid="
      echo "daemon_persistent=0"
    fi
    echo "daemon_started=$(cat "$OFMD_STARTED" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
    echo "daemon_cgroup=$(cat "$OFMD_CGROUP" 2>/dev/null | tr '\n' ' ' | tr -s ' ')"
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
    _day=$3
    if [ -n "$_day" ]; then
      valid_day "$_day" || { echo "日期格式应为 YYYY-MM-DD" >&2; exit 1; }
      _lf="$LOG_DIR/ofm-$_day.log"
    else
      _lf=$(latest_log_file) || _lf=
    fi
    [ -n "$_lf" ] && [ -f "$_lf" ] || { echo "暂无日志"; exit 0; }
    tail -n "$_n" "$_lf"
    ;;
  # 供 WebUI 日志下拉：一行一个「day=YYYY-MM-DD size=字节」，最新的在前
  log-days)
    if [ -d "$LOG_DIR" ]; then
      ls -1 "$LOG_DIR"/ofm-*.log 2>/dev/null | sort -r | while IFS= read -r _f; do
        _d=${_f##*/}; _d=${_d#ofm-}; _d=${_d%.log}
        _sz=$(wc -c <"$_f" 2>/dev/null || echo 0)
        printf 'day=%s size=%s\n' "$_d" "${_sz:-0}"
      done
    fi
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
  *)
    echo "用法：$0 start|stop|restart|submit <start|stop|restart>|status|info|daemon <start|stop|status>|set-config|log|log-days|console|mgmt-key" >&2
    exit 1
    ;;
esac
