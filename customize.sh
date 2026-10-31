#!/system/bin/sh
# customize.sh - 模块安装/更新入口
# 由 Magisk / KernelSU / APatch 在安装模块时调用。
#
# 约定：安装器注入 $MODPATH 指向模块解包目录；缺失时回退到脚本自身目录，
# 保证三家管理器（以及手工解包调试）都能正确解析路径。
#
# 【重要】本脚本是被安装器 source 执行的（[ -f customize.sh ] && . ./customize.sh），
# 不是独立进程 —— 任何 set 变更都会残留到安装器后面的代码里。
# 历史 bug：此处曾写 `set -u`，nounset 泄漏给安装器后，安装器执行
# `for TARGET in $REPLACE` 时因本模块没有 REPLACE/replace_list 而直接终止，
# 表现为日志里的 `sh: REPLACE: parameter not set` 加
# `Error: Failed to install module script`（模块文件其实已解包完成）。
#
# 因此本脚本的约定是：
#   1. 不启用任何 set 选项。set -e 同样不能用 —— 安装阶段 chmod / cp / 缺少可选
#      文件之类的非关键失败不该中断安装，否则用户会得到「安装成功但模块残缺」。
#   2. 开头显式 `set +u` 兜底，防止调用方开着 nounset 时把我们自己的逻辑带崩。
#   3. 结尾**不**「恢复」nounset。恢复了就等于把地雷重新埋回安装器，
#      下次换台设备/换版本又会以同样的方式失败。
set +u

# 双保险：安装器在本脚本返回后会执行 `for TARGET in $REPLACE`，而本模块没有
# replace 文件，REPLACE 从未被赋值。这里预定义为空字符串，让那段循环零迭代。
# 用 ${REPLACE-}（不带冒号）只在未定义时赋值，不覆盖安装器已有取值。
REPLACE="${REPLACE-}"

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
