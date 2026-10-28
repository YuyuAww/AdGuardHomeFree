#!/system/bin/sh
MODDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$MODDIR/scripts/common.sh"

REDIR_PORT=5591
CHAIN="AGHFREE"

apply_rules() {
    # 幂等：先清理再重建
    clear_rules

    $BUSYBOX iptables -t nat -N $CHAIN 2>/dev/null

    # 豁免本机回环地址和 AdGuardHome 自身进程的 owner
    $BUSYBOX iptables -t nat -A $CHAIN -d 127.0.0.1 -j RETURN
    $BUSYBOX iptables -t nat -A $CHAIN -m owner --uid-owner 0 -j RETURN 2>/dev/null || true

    # 将 TCP/UDP 53 重定向到 AdGuardHome
    $BUSYBOX iptables -t nat -A $CHAIN -p udp --dport 53 -j REDIRECT --to-ports $REDIR_PORT
    $BUSYBOX iptables -t nat -A $CHAIN -p tcp --dport 53 -j REDIRECT --to-ports $REDIR_PORT

    # 挂载到 OUTPUT（本机）和 PREROUTING（热点客户端，可选）
    $BUSYBOX iptables -t nat -C OUTPUT -j $CHAIN 2>/dev/null || \
        $BUSYBOX iptables -t nat -A OUTPUT -j $CHAIN
    $BUSYBOX iptables -t nat -C PREROUTING -j $CHAIN 2>/dev/null || \
        $BUSYBOX iptables -t nat -A PREROUTING -j $CHAIN
}

clear_rules() {
    $BUSYBOX iptables -t nat -D OUTPUT -j $CHAIN 2>/dev/null
    $BUSYBOX iptables -t nat -D PREROUTING -j $CHAIN 2>/dev/null
    $BUSYBOX iptables -t nat -F $CHAIN 2>/dev/null
    $BUSYBOX iptables -t nat -X $CHAIN 2>/dev/null
}

case "$1" in
    apply) apply_rules ;;
    clear) clear_rules ;;
    *) echo "usage: $0 {apply|clear}" ;;
esac