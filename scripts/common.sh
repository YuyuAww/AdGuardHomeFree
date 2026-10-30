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
PID_DIR="$RUNTIME_DIR/run"
mkdir -p "$LOG_DIR" "$PID_DIR" 2>/dev/null

# ---------- 默认端口（可被 bin/AdGuardHome.yaml 覆盖，见 get_dns_port） ----------
DNS_PORT_DEFAULT=5591
ADMIN_PORT_DEFAULT=3000
CTRL_PORT_DEFAULT=5592

# ---------- busybox 探测 ----------
# 部分设备 busybox 不内置（仅 magisk 自带），优先使用系统 busybox，回退到 magisk 内置
# 结果：BUSYBOX 为 busybox 可执行文件路径；找不到时为空字符串。
# 空字符串是安全的：所有调用点写作 `$BUSYBOX grep`（不加引号），展开后等价于
# `grep`，会走 PATH（Android 上即 toybox 提供的同名命令）。
# 唯一例外是 `"$BUSYBOX" httpd`：busybox 缺失时没有 httpd，需用 HAVE_BUSYBOX 判断。
HAVE_BUSYBOX=0
detect_busybox() {
    local c
    for c in /data/adb/magisk/busybox /system/bin/busybox /system/xbin/busybox; do
        if [ -x "$c" ]; then
            BUSYBOX="$c"
            HAVE_BUSYBOX=1
            return 0
        fi
    done
    # Magisk 的 busybox 位于 magisk --path 指向的 tmpfs 目录（/sbin 或 /debug_ramdisk）
    if command -v magisk > /dev/null 2>&1; then
        c="$(magisk --path 2>/dev/null)"
        if [ -n "$c" ] && [ -x "$c/busybox" ]; then
            BUSYBOX="$c/busybox"
            HAVE_BUSYBOX=1
            return 0
        fi
    fi
    BUSYBOX=""
    HAVE_BUSYBOX=0
}
detect_busybox

# ---------- 从配置读取 DNS 端口（dns.port），失败回退默认 ----------
get_dns_port() {
    local cfg="$1"
    [ -n "$cfg" ] || cfg="$RUNTIME_DIR/AdGuardHome.yaml"
    if [ -f "$cfg" ]; then
        # dns.port 是配置中唯一形如 "  port: <num>" 的键（http 用 address，不用 port）
        local p
        p="$($BUSYBOX grep -E '^[[:space:]]*port:[[:space:]]*[0-9]+' "$cfg" 2>/dev/null \
            | $BUSYBOX head -n1 \
            | $BUSYBOX sed -E 's/.*port:[[:space:]]*([0-9]+).*/\1/')"
        if [ -n "$p" ]; then
            echo "$p"
            return 0
        fi
    fi
    echo "$DNS_PORT_DEFAULT"
}

# ---------- 从配置读取管理台端口（http.address 形如 127.0.0.1:3000） ----------
get_admin_port() {
    local cfg="$1"
    [ -n "$cfg" ] || cfg="$RUNTIME_DIR/AdGuardHome.yaml"
    if [ -f "$cfg" ]; then
        local p
        # 只匹配 http.address 的尾部端口；dns.port 是独立键，不会被这条正则命中
        p="$($BUSYBOX sed -n 's/^[[:space:]]*address:[[:space:]]*.*:\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$cfg" 2>/dev/null | $BUSYBOX head -n1)"
        if [ -n "$p" ]; then
            echo "$p"
            return 0
        fi
    fi
    echo "$ADMIN_PORT_DEFAULT"
}

# ---------- 运行时解析出的端口 ----------
DNS_PORT="$(get_dns_port)"
ADMIN_PORT="$(get_admin_port)"

# ---------- 简易日志（带轮转，单文件上限 512KB） ----------
LOG_MAX=524288
rotate_log() {
    local f="$1"
    [ -f "$f" ] || return 0
    local sz
    sz=$($BUSYBOX wc -c < "$f" 2>/dev/null | $BUSYBOX tr -d ' ' || echo 0)
    if [ "$sz" -gt "$LOG_MAX" ] 2>/dev/null; then
        $BUSYBOX mv "$f" "$f.1" 2>/dev/null || true
    fi
}

log() {
    local entry="[AGHFREE $(date '+%F %T')] $*"
    rotate_log "$LOG_DIR/module.log"
    echo "$entry" >> "$LOG_DIR/module.log" 2>/dev/null
}

# ---------- 模块是否处于激活状态（Magisk 模块开关） ----------
is_enabled() {
    # Magisk / KernelSU / APatch 的禁用标记是 disable（无点号），remove 表示待卸载。
    # 任一存在即视为不应启动。
    [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ]
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

# ---------- AdGuardHome 主进程管理 ----------
AGH_BIN="$MODDIR/bin/AdGuardHome"

agh_is_running() {
    $BUSYBOX pgrep -f "$AGH_BIN" > /dev/null 2>&1
}

agh_start() {
    local cfg="$RUNTIME_DIR/AdGuardHome.yaml"
    [ -f "$cfg" ] || cfg="$MODDIR/bin/AdGuardHome.yaml"
    export SSL_CERT_DIR="/system/etc/security/cacerts/"
    nohup "$AGH_BIN" -c "$cfg" -w "$RUNTIME_DIR" \
        >> "$LOG_DIR/agh.log" 2>&1 &
    echo $! > "$PID_DIR/agh.pid" 2>/dev/null || true
}

agh_stop() {
    $BUSYBOX pkill -f "$AGH_BIN" 2>/dev/null || true
    rm -f "$PID_DIR/agh.pid" 2>/dev/null || true
}
