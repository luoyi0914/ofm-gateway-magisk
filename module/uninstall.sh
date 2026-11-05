#!/system/bin/sh
# 卸载时执行：停守护进程、停服务、清掉解出来的运行时，保留数据目录。

# 模块目录：逐个候选目录试，以「里面确实有 config.sh」为准；都不成立才退回固定路径
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

if [ -f "$CTL" ]; then
  # 先停服务（此时守护进程还活着，投递能正常执行、结果也能落盘）：
  # 运行中的进程正拿着 /data/adb/ofm-runtime 里的可执行文件，
  # 直接删目录会留下无法再管理的孤儿进程
  OFM_MODDIR="$MODDIR" sh "$CTL" stop
  # 再停守护进程本身，否则它会把刚停掉的服务重新拉起来
  OFM_MODDIR="$MODDIR" sh "$CTL" daemon stop
fi

# 兜底：按命令行精确匹配本模块的 node / 守护进程，防止 pidfile 丢失时漏杀
for _p in $(pidof node 2>/dev/null); do
  tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null | grep -q '/data/adb/ofm-runtime' || continue
  kill "$_p" 2>/dev/null
done
for _p in $(pidof sh 2>/dev/null); do
  tr '\0' ' ' <"/proc/$_p/cmdline" 2>/dev/null | grep -q 'common/ofmd.sh' || continue
  kill "$_p" 2>/dev/null
done

rm -rf /data/adb/ofm-runtime
