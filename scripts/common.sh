#!/system/bin/sh
# common.sh - AdGuardHomeFree 公共函数与路径/工具探测
# 通过 source 引入：. "$MODDIR/scripts/common.sh"

# ---------- 模块根目录 ----------
# 各入口脚本在 source 本文件前已定义 MODDIR；此处做兜底
if [ -z "$MODDIR" ]; then
    MODDIR="$(cd "$(dirname "$0")/.." && pwd)"
fi

# ---------- 运行时数据目录 ----------
RUNTIME_DIR="/data/adb/agh"
LOG_DIR="$RUNTIME_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null

# ---------- busybox 探测 ----------
# 部分设备 busybox 不内置（仅 magisk 自带），优先使用系统 busybox，回退到 magisk 内置
detect_busybox() {
    if [ -x "/system/bin/busybox" ]; then
        BUSYBOX="/system/bin/busybox"
    elif [ -n "$MAGISK_DIR" ] && [ -x "$MAGISK_DIR/bin/busybox" ]; then
        BUSYBOX="$MAGISK_DIR/bin/busybox"
    else
        # 最后兜底：直接调用命令
        BUSYBOX="command"
    fi
}
detect_busybox

# ---------- 简易日志 ----------
log() {
    echo "[AGHFREE $(date '+%F %T')] $*" >> "$LOG_DIR/module.log" 2>/dev/null
}

# ---------- 模块是否处于激活状态（Magisk 模块开关） ----------
is_enabled() {
    # /data/adb/modules/AdGuardHomeFree/.disable 存在则禁用
    [ ! -f "$MODDIR/.disable" ]
}

# ---------- 是否 root 模块环境（KernelSU / APatch / Magisk） ----------
detect_env() {
    if [ -n "$KSU_MODDIR" ] || [ -d "/data/adb/ksu" ]; then
        ENV="ksu"
    elif [ -n "$APATCH" ] || [ -d "/data/adb/ap" ]; then
        ENV="apatch"
    else
        ENV="magisk"
    fi
}
detect_env
