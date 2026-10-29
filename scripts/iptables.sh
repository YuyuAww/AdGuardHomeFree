#!/system/bin/sh
# iptables.sh - 将 DNS 查询重定向到 AdGuardHome（IPv4 + IPv6）
# 用法：iptables.sh {apply|clear}
MODDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$MODDIR/scripts/common.sh"

# 目标端口：从运行时配置读取（默认 5591）
REDIR_PORT="$DNS_PORT"
[ -n "$REDIR_PORT" ] || REDIR_PORT="$DNS_PORT_DEFAULT"

CHAIN="AGHFREE"
# 是否处理 IPv6 DNS（部分设备缺少 ip6tables 或无 IPv6 栈时自动跳过）
ENABLE_IPV6="${AGHFREE_ENABLE_IPV6:-1}"

ipt4() { $BUSYBOX iptables "$@"; }
ipt6() { $BUSYBOX ip6tables "$@"; }

# 功能探测：直接尝试列出 nat 表，判断 iptables / ip6tables 是否可用
has_iptables() {
    $BUSYBOX iptables -t nat -L >/dev/null 2>&1
}
has_ip6tables() {
    $BUSYBOX ip6tables -t nat -L >/dev/null 2>&1
}

clear_family() {
    local run="$1"
    $run -t nat -D OUTPUT -j $CHAIN 2>/dev/null
    $run -t nat -D PREROUTING -j $CHAIN 2>/dev/null
    $run -t nat -F $CHAIN 2>/dev/null
    $run -t nat -X $CHAIN 2>/dev/null
}

apply_family() {
    local run="$1"

    # 幂等：先清理再重建
    clear_family "$run"

    $run -t nat -N $CHAIN 2>/dev/null || true

    # 豁免回环地址与 AdGuardHome 自身进程（uid 0）的报文，
    # 避免 AdGuardHome 的 bootstrap/上游查询被再次重定向形成环路。
    $run -t nat -A $CHAIN -d 127.0.0.1 -j RETURN 2>/dev/null
    $run -t nat -A $CHAIN -d ::1 -j RETURN 2>/dev/null
    $run -t nat -A $CHAIN -m owner --uid-owner 0 -j RETURN 2>/dev/null || true

    # 将 TCP/UDP 53 重定向到 AdGuardHome
    $run -t nat -A $CHAIN -p udp --dport 53 -j REDIRECT --to-ports "$REDIR_PORT" 2>/dev/null
    $run -t nat -A $CHAIN -p tcp --dport 53 -j REDIRECT --to-ports "$REDIR_PORT" 2>/dev/null

    # 挂载到 OUTPUT（本机）和 PREROUTING（热点/转发客户端）
    $run -t nat -C OUTPUT -j $CHAIN 2>/dev/null || $run -t nat -A OUTPUT -j $CHAIN 2>/dev/null
    $run -t nat -C PREROUTING -j $CHAIN 2>/dev/null || $run -t nat -A PREROUTING -j $CHAIN 2>/dev/null
}

apply_rules() {
    if has_iptables; then
        apply_family ipt4
    else
        log "iptables 不可用，跳过 IPv4 DNS 接管"
    fi

    if [ "$ENABLE_IPV6" = "1" ]; then
        if has_ip6tables; then
            apply_family ipt6
        else
            log "ip6tables 不可用，IPv6 DNS 查询将不经过过滤（仅部分环境）"
        fi
    fi
}

clear_rules() {
    if has_iptables; then
        clear_family ipt4
    fi
    if [ "$ENABLE_IPV6" = "1" ] && has_ip6tables; then
        clear_family ipt6
    fi
}

case "$1" in
    apply) apply_rules ;;
    clear) clear_rules ;;
    *) echo "usage: $0 {apply|clear}" ;;
esac
