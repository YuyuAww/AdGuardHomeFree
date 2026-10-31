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
    local run="$1" i=0
    # 反复摘除跳转，避免历史版本重复挂载后残留
    while [ $i -lt 8 ]; do
        $run -t nat -D OUTPUT -j $CHAIN 2>/dev/null || break
        i=$((i+1))
    done
    i=0
    while [ $i -lt 8 ]; do
        $run -t nat -D PREROUTING -j $CHAIN 2>/dev/null || break
        i=$((i+1))
    done
    $run -t nat -F $CHAIN 2>/dev/null
    $run -t nat -X $CHAIN 2>/dev/null
}

apply_family() {
    local run="$1"

    # 幂等：先清理再重建
    clear_family "$run"

    $run -t nat -N $CHAIN 2>/dev/null || true

    # 豁免回环/链路本地网段与 AdGuardHome 自身进程（uid 0）的报文，
    # 避免 bootstrap/上游查询被再次重定向形成环路。按协议族下发各自地址，
    # 否则 ip6tables 会因无法解析 IPv4 字面量而整条失败。
    if [ "$run" = "ipt4" ]; then
        $run -t nat -A $CHAIN -d 127.0.0.0/8 -j RETURN 2>/dev/null
        $run -t nat -A $CHAIN -d 169.254.0.0/16 -j RETURN 2>/dev/null
    else
        $run -t nat -A $CHAIN -d ::1 -j RETURN 2>/dev/null
        $run -t nat -A $CHAIN -d fe80::/10 -j RETURN 2>/dev/null
    fi
    # 豁免 root(uid 0) 的出站报文：AdGuardHome 自身以 root 运行，它访问
    # bootstrap_dns（223.5.5.5:53）时若被重定向回自己，会形成 DNS 环路 → 全机断网。
    # 旧版写作 `... || true`，内核缺 xt_owner 时规则根本没加上却静默继续，
    # 环路风险真实存在。这里改为必须回查成功：失败就清掉半成品并放弃接管
    # （宁可不去广告，也不要断网）。
    if ! $run -t nat -A $CHAIN -m owner --uid-owner 0 -j RETURN 2>/dev/null; then
        log "iptables: 无法添加 uid0 豁免（内核可能缺少 xt_owner），放弃接管以避免 DNS 环路"
        clear_family "$run"
        return 1
    fi

    # 将 TCP/UDP 53 重定向到 AdGuardHome
    $run -t nat -A $CHAIN -p udp --dport 53 -j REDIRECT --to-ports "$REDIR_PORT" 2>/dev/null
    $run -t nat -A $CHAIN -p tcp --dport 53 -j REDIRECT --to-ports "$REDIR_PORT" 2>/dev/null

    # 挂载到 OUTPUT（本机）和 PREROUTING（热点/转发客户端）
    $run -t nat -C OUTPUT -j $CHAIN 2>/dev/null || $run -t nat -A OUTPUT -j $CHAIN 2>/dev/null
    $run -t nat -C PREROUTING -j $CHAIN 2>/dev/null || $run -t nat -A PREROUTING -j $CHAIN 2>/dev/null
}

apply_rules() {
    if has_iptables; then
        # apply_family 返回非 0 表示 uid0 豁免加不上（内核缺 xt_owner）。
        # 此时必须整体放弃：若继续往下挂 IPv6 规则，就变成「v4 不接管、v6 接管」
        # 的半接管状态，AdGuardHome 的 bootstrap 查询在 v6 侧仍会被重定向回自己，
        # 环路风险并未消除，反而更难排查。clear_rules 顺带清掉历史残留规则。
        if ! apply_family ipt4; then
            log "iptables: IPv4 接管失败，已回滚并跳过 IPv6，保持 DNS 直连"
            clear_rules
            return 1
        fi
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
