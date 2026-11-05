#!/system/bin/sh
# 安装时执行：先把运行时解好，避免首次开机时现解。

# 安装阶段本脚本是被 installer source 进来的，$0 指向 installer 自己而不是模块目录，
# 此时只能信任 installer 传进来的 $MODPATH（安装期是 /data/adb/modules_update/<id>）
MODDIR=${MODPATH:-${0%/*}}
[ -f "$MODDIR/config.sh" ] || MODDIR=/data/adb/modules/ofm_gateway

# abort 由管理器安装器提供（Magisk / KernelSU 都有）；单独 sh 跑本脚本时没有，给个退路
fail() {
  if command -v abort >/dev/null 2>&1; then abort "$1"; else echo "$1" >&2; exit 1; fi
}

# 安装期间会替换 /data/adb/ofm-runtime 里的文件，而旧版的守护进程可能正在跑着。
# 它一旦发现服务没了就会按「意图=运行」把 node 重新拉起来 ——
# 拉起的是正要被替换的那份运行时，会留下拿着已删文件的进程。
# 所以先让守护进程退出；重启后 service.sh 会重新拉起新版的守护进程。
if [ -f "$MODDIR/common/ofmctl.sh" ]; then
  OFM_MODDIR="$MODDIR" sh "$MODDIR/common/ofmctl.sh" daemon stop >/dev/null 2>&1
fi

OFM_MODDIR="$MODDIR" sh "$MODDIR/common/runtime.sh" now
_rc=$?

# 退出码 2 = 增量包要求的 usr 指纹与本机不符（设备上没装过基线包，
# 或跳过了一个换 Node 的版本）。这不是文件损坏，要明确告诉用户怎么办。
if [ $_rc = 2 ]; then
  fail "这个增量包只含服务代码（约 2 MB），没有 Node 运行时。
请改刷同版本的完整包（文件名不带 _patch 的那个），装完后即可继续用增量包更新。"
fi

if [ $_rc != 0 ]; then
  # 解压失败（包损坏、空间不足）要让安装可见地失败，
  # 否则重启后服务起不来，用户只会看到「未运行」
  fail "运行时解压失败（$MODDIR/runtime/）。
请确认模块包完整、/data 空间充足后重装。"
fi
