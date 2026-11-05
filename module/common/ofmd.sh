#!/system/bin/sh
# OFM 守护进程。整份模块里唯一真正「起停服务」的执行者。
#
# 为什么需要它：面板（KernelSU WebUI）里的 exec 跑在管理器 App 的会话里，
# 由它直接起的进程继承 App 的 cgroup，App 一退就被系统清理 ——
# setsid / nohup / disown 都改不了 cgroup 归属（KernelSU-Next #1180 有实测）。
# 所以面板只投递请求，真正的启停交给这个守护进程：
#   开机时由 service.sh 拉起 → 落在系统域，管理器怎么退都不受影响；
#   面板/动作按钮里起不来时才由 ofmctl.sh 就地拉起 → 落在 App 域，
#   此时会把 ofmd.persistent 记成 0，面板据此显示「降级模式」提示。
#
# 协议（与 ofmctl.sh 的 submit_action 对应）：
#   $QUEUE_DIR/<id>.req  一行动作名（start / stop / restart）
#   $QUEUE_DIR/<id>.res  第一行「<rc> <消息>」，写完即删 req
# 请求/结果各占一个文件，不共享队列游标，所以并发的投递不会互相吃请求。

OFM_LIB_ONLY=1
OFM_MODDIR=${OFM_MODDIR:-${0%/*}}
. "$OFM_MODDIR/common/ofmctl.sh"

_running=1
trap '_running=0' TERM INT HUP

# 关掉从调用方继承来的杂项 fd（3~9）。管理器执行命令时会盯着自己的管道等 EOF，
# 守护进程是常驻的，只要它还握着那个写端，面板那条 exec 就永远不返回。
for _fd in 3 4 5 6 7 8 9; do
  eval "exec ${_fd}>&-" 2>/dev/null
done

# 0 = 系统域（管理器退出不受影响）；1 = App 域（会一起被回收）
detect_persistent() {
  _cg_all=$(cat /proc/self/cgroup 2>/dev/null)
  # cgroup v2 统一层级是「0::<path>」；cgroup v1 是每个控制器一行
  _path=$(printf '%s\n' "$_cg_all" | sed -n 's/^0:://p' | head -n 1)
  if [ -z "$_path" ]; then
    _path=$(printf '%s\n' "$_cg_all" | sed -n 's#^[0-9][0-9]*:[^:]*:\(/apps.*\)$#\1#p' | head -n 1)
  fi
  [ -n "$_path" ] || _path=unknown
  printf '%s\n' "$_path" >"$OFMD_CGROUP" 2>/dev/null
  case "$_path" in
    */apps/*)
      # 管理器把 App 的进程放在 /apps/<包名>；动作按钮与开机脚本落在 /apps 本身。
      # 带点的那一段就是包名，说明我们继承了 App 的 cgroup。
      _rest=${_path##*/apps/}
      case "$_rest" in
        *.*) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    *) return 0 ;;
  esac
}

acquire_lock() {
  ensure_dirs
  if mkdir "$OFMD_LOCKDIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$OFMD_LOCKDIR/pid" 2>/dev/null
    return 0
  fi
  # 锁被占：里面的 pid 还活着、且确实是守护进程，才认
  _old=$(cat "$OFMD_LOCKDIR/pid" 2>/dev/null)
  if pid_alive "$_old" && pid_cmdline "$_old" | grep -q 'ofmd.sh'; then
    return 1
  fi
  rm -rf "$OFMD_LOCKDIR" 2>/dev/null
  if mkdir "$OFMD_LOCKDIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$OFMD_LOCKDIR/pid" 2>/dev/null
    return 0
  fi
  return 1
}

release_lock() {
  _old=$(cat "$OFMD_LOCKDIR/pid" 2>/dev/null)
  [ "$_old" = "$$" ] && rm -rf "$OFMD_LOCKDIR" 2>/dev/null
  [ -f "$OFMD_PIDFILE" ] && [ "$(cat "$OFMD_PIDFILE" 2>/dev/null)" = "$$" ] && rm -f "$OFMD_PIDFILE"
}

clean_queue() {
  # 面板没来得及取就消失的结果文件、写到一半的临时文件，留一小时足够。
  # 文件名形如 <epoch>-<pid>-<动作>.res，直接拿前缀算年龄：
  # 不依赖 find 的 -mmin/-delete（老 toybox 未必有这两项）。
  _now=$(date '+%s')
  case "$_now" in ''|*[!0-9]*) return 0 ;; esac
  for _f in "$QUEUE_DIR"/*.res "$QUEUE_DIR"/*.tmp; do
    [ -f "$_f" ] || continue
    _base=${_f##*/}
    _ts=${_base%%-*}
    case "$_ts" in ''|*[!0-9]*) rm -f "$_f" 2>/dev/null; continue ;; esac
    [ $((_now - _ts)) -gt 3600 ] && rm -f "$_f" 2>/dev/null
  done
}

# 处理队列里所有请求，返回处理条数
process_queue() {
  _n=0
  for _req in "$QUEUE_DIR"/*.req; do
    [ -f "$_req" ] || continue
    _id=${_req##*/}
    _id=${_id%.req}
    _act=$(sed -n '1p' "$_req" 2>/dev/null | tr -d '\r\n ')
    rm -f "$_req" 2>/dev/null
    case "$_act" in
      start)
        _out=$(svc_start 2>&1); _rc=$?
        if [ "$_rc" = 0 ]; then printf '1\n' >"$OFMD_WANT" 2>/dev/null; fi
        ;;
      stop)
        _out=$(svc_stop 2>&1); _rc=$?
        if [ "$_rc" = 0 ]; then printf '0\n' >"$OFMD_WANT" 2>/dev/null; fi
        ;;
      restart)
        _out1=$(svc_stop 2>&1); _rc1=$?
        _out=$(svc_start 2>&1); _rc=$?
        [ "$_rc1" = 0 ] || _out="停止阶段：$_out1 $_out"
        if [ "$_rc" = 0 ]; then printf '1\n' >"$OFMD_WANT" 2>/dev/null; fi
        ;;
      *)
        _out="未知动作：$_act"; _rc=1
        ;;
    esac
    [ -n "$_out" ] || _out=完成
    write_result "$_id" "$_rc" "$_out"
    log_note "请求 $_act（id $_id）→ rc=$_rc：$_out"
    _n=$((_n + 1))
  done
  printf '%s' "$_n"
}

# 服务意外退出时按意图标记拉回。连续失败要退避，避免把电量和日志刷爆。
_fail=0
_next_try=0
supervise() {
  [ "$(sed -n '1p' "$OFMD_WANT" 2>/dev/null)" = "1" ] || return 0
  is_running && { _fail=0; return 0; }

  _now=$(date '+%s')
  case "$_now" in ''|*[!0-9]*) _now=0 ;; esac
  [ "$_now" -ge "$_next_try" ] || return 0

  log_note "服务不在运行（意图=运行），尝试拉起"
  _out=$(svc_start 2>&1); _rc=$?
  if [ "$_rc" = 0 ]; then
    _fail=0
    log_note "已自动拉起：$_out"
  else
    _fail=$((_fail + 1))
    _delay=$((_fail * 10))
    [ "$_delay" -gt 120 ] && _delay=120
    _next_try=$((_now + _delay))
    log_note "自动拉起失败（第 $_fail 次，${_delay}s 后重试）：$_out"
  fi
}

# ---- 启动 ----

if ! acquire_lock; then
  # 已有一份在跑，不重复起
  exit 0
fi

reload_config
ensure_dirs
printf '%s\n' "$$" >"$OFMD_PIDFILE" 2>/dev/null

detect_persistent
if [ $? = 0 ]; then
  printf '1\n' >"$OFMD_PERSIST" 2>/dev/null
  _pmode="系统域"
else
  printf '0\n' >"$OFMD_PERSIST" 2>/dev/null
  _pmode="App 域（退出管理器会被回收）"
fi
date '+%Y-%m-%d %H:%M:%S' >"$OFMD_STARTED" 2>/dev/null
log_note "守护进程启动（pid $$，来源 ${OFM_DAEMON_SOURCE:-未知}，cgroup 归属 $_pmode）"

# 记录「用户意图」：要不要让服务一直跑着（1/0）。supervise() 只按它拉回。
case "${OFM_DAEMON_SOURCE:-manual}" in
  boot)
    # 开机：按 config.sh 的 AUTOSTART 重置意图，避免上次手动停止的状态卡到下次开机
    if [ "$AUTOSTART" = "1" ]; then
      printf '1\n' >"$OFMD_WANT" 2>/dev/null
    else
      printf '0\n' >"$OFMD_WANT" 2>/dev/null
    fi
    ;;
  *)
    # 面板/动作按钮临时拉起：不动既有意图；没有历史记录时才按当前状态推断
    if [ -f "$OFMD_WANT" ]; then
      :
    elif is_running; then
      printf '1\n' >"$OFMD_WANT" 2>/dev/null
    else
      printf '0\n' >"$OFMD_WANT" 2>/dev/null
    fi
    ;;
esac

# ---- 主循环 ----

_loop=0
while [ "$_running" = "1" ]; do
  _n=$(process_queue)
  [ "${_n:-0}" = "0" ] && supervise
  _loop=$((_loop + 1))
  # 每 5 分钟顺手清一次过期结果文件
  [ $((_loop % 300)) = 0 ] && [ "$_loop" -gt 0 ] && clean_queue
  sleep 1
done

release_lock
log_note "守护进程退出（pid $$）"
exit 0
