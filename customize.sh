#!/system/bin/sh
# customize.sh - 模块安装/更新入口
# 由 Magisk / KernelSU / APatch 在安装模块时调用。
set -eu

# 兼容 Magisk 注入的变量；KernelSU/APatch 调用方式略有差异
MODDIR="$(cd "$(dirname "$0")" && pwd)"

# 运行时数据目录（配置 / 日志 / 数据）。
# 仅在首次安装时创建并写入默认模板；更新时保留用户已修改的配置。
RTDIR="/data/adb/agh"
if [ ! -f "$RTDIR/AdGuardHome.yaml" ]; then
    mkdir -p "$RTDIR/logs" "$RTDIR/run"
    cp "$MODDIR/bin/AdGuardHome.yaml" "$RTDIR/AdGuardHome.yaml"
fi
chmod 755 "$RTDIR"

# 赋予二进制与脚本执行权限（部分安装器会丢失 x 位；api.cgi 非 .sh 后缀，单独覆盖）
chmod 755 "$MODDIR/bin/AdGuardHome" 2>/dev/null || true
chmod 755 "$MODDIR"/scripts/* 2>/dev/null || true

echo "[AGHFREE] customize.sh 完成"

