#!/system/bin/sh
# uninstall.sh - 模块卸载清理
# 由 Magisk / KernelSU / APatch 在卸载模块时调用（部分环境不保证执行）。

MODDIR="$(cd "$(dirname "$0")" && pwd)"
. "$MODDIR/scripts/common.sh"

# 停止看门狗、控制台服务与 AdGuardHome 进程
# 按 $MODDIR 精确匹配（旧版硬编码 adguardhomefree/，模块目录改名后清理不掉）
$BUSYBOX pkill -f "$MODDIR/scripts/watchdog.sh" 2>/dev/null || true
$BUSYBOX pkill -f "$MODDIR/scripts/control.sh" 2>/dev/null || true
$BUSYBOX pkill -f "httpd.*127.0.0.1:$CTRL_PORT_DEFAULT" 2>/dev/null || true
rm -f "$PID_DIR/watchdog.lock" 2>/dev/null || true
agh_stop
sleep 1

# 清理 iptables 规则（IPv4 + IPv6）
sh "$MODDIR/scripts/iptables.sh" clear 2>/dev/null || true

# 删除运行时数据（含日志、锁、运行时配置）
rm -rf "$RUNTIME_DIR" 2>/dev/null || true

echo "[AGHFREE] uninstall.sh 完成"
