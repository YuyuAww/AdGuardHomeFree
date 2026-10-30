#!/system/bin/sh
# customize.sh - 模块安装/更新入口
# 由 Magisk / KernelSU / APatch 在安装模块时调用。
#
# 约定：安装器注入 $MODPATH 指向模块解包目录；缺失时回退到脚本自身目录，
# 保证三家管理器（以及手工解包调试）都能正确解析路径。
# 注意：这里只用 set -u，不使用 set -e —— 安装阶段任何一条非关键命令失败
# （chmod、cp、缺少可选文件）都不应中断安装，否则用户会得到「安装成功但模块残缺」。
set -u

MODDIR="${MODPATH:-}"
if [ -z "$MODDIR" ]; then
    MODDIR="$(cd "$(dirname "$0")" && pwd)"
fi

RTDIR="/data/adb/agh"

# ui_print 由 Magisk / KernelSU / APatch 安装器注入。手工解包调试或个别旧版
# 安装器没有这个函数，这里补一个回退实现，避免满屏 "ui_print: not found"。
if ! command -v ui_print > /dev/null 2>&1; then
    ui_print() { echo "$1"; }
fi

ui_print "- 安装目录: $MODDIR"

# 权限：部分安装器会丢失 x 位；api.cgi 无 .sh 后缀，由 scripts/* 通配一起覆盖。
chmod 755 "$MODDIR/bin/AdGuardHome" 2>/dev/null || true
chmod 755 "$MODDIR"/*.sh 2>/dev/null || true
chmod 755 "$MODDIR"/scripts/* 2>/dev/null || true

# 运行时数据目录（配置 / 日志 / 锁）。
# 仅在首次安装时写入默认模板；更新时保留用户已修改的配置。
mkdir -p "$RTDIR/logs" "$RTDIR/run" 2>/dev/null || true
chmod 755 "$RTDIR" 2>/dev/null || true

if [ ! -f "$RTDIR/AdGuardHome.yaml" ]; then
    if cp "$MODDIR/bin/AdGuardHome.yaml" "$RTDIR/AdGuardHome.yaml" 2>/dev/null; then
        ui_print "- 已初始化默认配置: $RTDIR/AdGuardHome.yaml"
    else
        ui_print "! 配置模板复制失败，service.sh 会在开机时重试"
    fi
else
    ui_print "- 保留已有配置: $RTDIR/AdGuardHome.yaml"
fi

# 二进制缺失时给出明确提示：仓库不含二进制，需 CI 产物或本地 -DownloadBinary。
if [ ! -x "$MODDIR/bin/AdGuardHome" ]; then
    ui_print "! bin/AdGuardHome 缺失或不可执行，模块将无法启动 AdGuardHome"
    ui_print "  请使用 CI 产物，或本地执行 ./build.ps1 -DownloadBinary 重新打包"
fi

ui_print "[AGHFREE] customize.sh 完成"
