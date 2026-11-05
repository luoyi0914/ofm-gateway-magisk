#!/system/bin/sh
# KernelSU / Magisk 模块页面的「动作」按钮。
#
# 动作按钮和开机脚本一样，是在系统域里跑的（管理器会用 switch_cgroups 脱离 App 的
# cgroup），所以它也是「把守护进程放到正确位置」的合法入口：面板里的执行器不行。
# 因此这里先确保守护进程在跑，再让守护进程去做启停。

# 动作按钮的调用方式与开机脚本一致：可能只给文件名、cwd 是模块目录。
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
CTL="$MODDIR/common/ofmctl.sh"
export OFM_MODDIR="$MODDIR" OFM_CLIENT=action

# 顺手把守护进程拉到位（已经是它自己就不重复起）
sh "$CTL" daemon start action >/dev/null 2>&1

STATE=$(sh "$CTL" status)

# 没有图形界面，用控制台菜单
while true; do
  echo "OFM 本机网关"
  echo "$STATE"
  echo "1) 重启服务"
  echo "2) 停止服务"
  echo "3) 启动服务"
  echo "4) 退出"
  printf '选择：'
  # stdin 不是终端或已关闭时，read 会立即返回非 0，
  # 不break就会死循环刷屏
  read -r choice || break
  case "$choice" in
    1) sh "$CTL" restart ;;
    2) sh "$CTL" stop ;;
    3) sh "$CTL" start ;;
    4) exit 0 ;;
    *) continue ;;
  esac
  # 启停请求已经由守护进程执行完才返回（超时会带 rc=2），不用再盲等
  STATE=$(sh "$CTL" status)
done
