#!/system/bin/sh
# uninstall.sh - 模块卸载清理
# 由 Magisk / KernelSU / APatch 在卸载模块时调用（部分环境不保证执行）。

MODDIR="$(cd "$(dirname "$0")" && pwd)"

# 停止看门狗与 AdGuardHome 进程
pkill -f "adguardhomefree/watchdog.sh" 2>/dev/null || true
pkill -f "$MODDIR/bin/AdGuardHome" 2>/dev/null || true
sleep 1

# 清理 iptables 规则
sh "$MODDIR/scripts/iptables.sh" clear 2>/dev/null || true

# 删除运行时数据（含日志、锁、运行时配置）
rm -rf /data/adb/agh 2>/dev/null || true

echo "[AGHFREE] uninstall.sh 完成"

