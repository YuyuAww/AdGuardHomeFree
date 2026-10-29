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

# ---------- 运行时解析出的端口 ----------
DNS_PORT="$(get_dns_port)"

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
