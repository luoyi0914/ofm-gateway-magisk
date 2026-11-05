#!/system/bin/sh
# 开机启动，由 KernelSU / Magisk 在 boot 阶段执行。
#
# 这里做的事（顺序不能换）：
#   1. 先把常驻守护进程 ofmd.sh 拉起来 —— 它由开机脚本启动，所以落在系统域，
#      不会因为管理器 App 退出而被回收；面板之后的所有启停都由它执行。
#   2. 再按 AUTOSTART 决定要不要把服务拉起来。
# 即使 AUTOSTART=0，守护进程也照起：否则用户从面板启动时只能降级到
# App 会话里（退出管理器即被回收），那正是要修的那个毛病。

# 模块目录：管理器调用方式不统一 —— Magisk 把目录放进 MODDIR 环境变量，
# KernelSU 则 cd 到模块目录再 `sh service.sh`（此时 $0 只有文件名，推不出目录）。
# 逐个候选目录试，以「里面确实有 config.sh」为准。
case "$0" in
  */*) _self_dir=$(cd "${0%/*}" 2>/dev/null && pwd) ;;
  *) _self_dir= ;;
esac
_moddir=
for _c in "$MODDIR" "$OFM_MODDIR" "$_self_dir" "$_self_dir/.." "$(pwd)" "$(pwd)/.."; do
  [ -n "$_c" ] || continue
  if [ -f "$_c/config.sh" ]; then _moddir=$_c; break; fi
done
MODDIR=${_moddir:-/data/adb/modules/ofm_gateway}
. "$MODDIR/config.sh"
CTL="$MODDIR/common/ofmctl.sh"

# 等 /data 挂好。加超时：正常几秒内就绪，长期不就绪说明环境异常，
# 无上限等待会让这个 boot 脚本一直挂着
_i=0
until [ -d /data/adb ]; do
  _i=$((_i + 1))
  [ "$_i" -ge 60 ] && exit 1
  sleep 1
done

# 守护进程由本脚本拉起 → cgroup 属于系统域，管理器退出不受影响
OFM_MODDIR="$MODDIR" sh "$CTL" daemon start boot

[ "$AUTOSTART" = "1" ] || exit 0

OFM_MODDIR="$MODDIR" OFM_CLIENT=boot sh "$CTL" start
