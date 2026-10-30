#!/system/bin/sh
# service.sh - 开机/服务阶段入口
# 由 Magisk / KernelSU / APatch 在启动服务时调用。
MODDIR=${0%/*}
. "$MODDIR/scripts/common.sh"

# 若配置缺失（极少发生），回退到模块内置模板
CFG="$RUNTIME_DIR/AdGuardHome.yaml"
if [ ! -f "$CFG" ]; then
    mkdir -p "$RUNTIME_DIR"
    cp "$MODDIR/bin/AdGuardHome.yaml" "$CFG"
fi

# 模块被禁用则直接退出
if ! is_enabled; then
    log "模块已被 disable/remove 标记，跳过启动"
    exit 0
fi

# 等待网络基本就绪（有界等待，最多 30 秒）
i=0
while [ $i -lt 30 ]; do
    if $BUSYBOX ip route show default 2>/dev/null | $BUSYBOX grep -q default; then
        break
    fi
    sleep 1
    i=$((i+1))
done

# 清理旧实例（先停看门狗，再停主进程，避免看门狗立刻重启主进程）
# 按 $MODDIR 精确匹配，避免模块目录改名后匹配失败导致看门狗叠加
$BUSYBOX pkill -f "$MODDIR/scripts/watchdog.sh" 2>/dev/null || true
agh_stop
sleep 1

# 启动 AdGuardHome（工作目录用运行时目录，避免在只读模块目录写数据）
log "启动 AdGuardHome (cfg=$CFG, dns_port=$DNS_PORT, admin_port=$ADMIN_PORT)"
agh_start

# 等待 DNS 端口就绪（有界，最多 15 秒）
i=0
while [ $i -lt 15 ]; do
    if $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ":$DNS_PORT"; then
        break
    fi
    sleep 1
    i=$((i+1))
done

# 仅在 AdGuardHome 就绪后才接管 DNS，避免启动期间断网
if $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ":$DNS_PORT"; then
    sh "$MODDIR/scripts/iptables.sh" apply
    log "DNS 已接管 (port $DNS_PORT)"
else
    log "AdGuardHome 未就绪，跳过 DNS 接管"
fi

# 启动控制台服务（WebUI 状态/启停 API，busybox httpd + CGI）
if [ -f "$MODDIR/scripts/control.sh" ]; then
    nohup sh "$MODDIR/scripts/control.sh" >> "$LOG_DIR/control.log" 2>&1 &
fi

# 启动看门狗（后台常驻）
nohup sh "$MODDIR/scripts/watchdog.sh" >> "$LOG_DIR/watchdog.log" 2>&1 &
