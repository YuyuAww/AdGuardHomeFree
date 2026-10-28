#!/system/bin/sh
# service.sh - 开机/服务阶段入口
# 由 Magisk / KernelSU / APatch 在启动服务时调用。
MODDIR=${0%/*}
. "$MODDIR/scripts/common.sh"

# 若配置缺失（极少发生），回退到模块内置模板
CFG="/data/adb/agh/AdGuardHome.yaml"
if [ ! -f "$CFG" ]; then
    mkdir -p /data/adb/agh
    cp "$MODDIR/bin/AdGuardHome.yaml" "$CFG"
fi

# 模块被禁用则直接退出
if ! is_enabled; then
    log "模块已被 .disable 标记，跳过启动"
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

# 清理旧实例
$BUSYBOX pkill -f "$MODDIR/bin/AdGuardHome" 2>/dev/null || true
$BUSYBOX pkill -f "adguardhomefree/watchdog.sh" 2>/dev/null || true
sleep 1

# 启动 AdGuardHome（工作目录用运行时目录，避免在只读模块目录写数据）
export SSL_CERT_DIR="/system/etc/security/cacerts/"
log "启动 AdGuardHome (cfg=$CFG)"
"$MODDIR/bin/AdGuardHome" \
    -c "$CFG" \
    -w "/data/adb/agh" \
    >> /data/adb/agh/logs/agh.log 2>&1 &

# 等待 DNS 端口就绪（有界，最多 15 秒）
i=0
while [ $i -lt 15 ]; do
    if $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ':5591'; then
        break
    fi
    sleep 1
    i=$((i+1))
done

# 仅在 AdGuardHome 就绪后才接管 DNS，避免启动期间断网
if $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ':5591'; then
    sh "$MODDIR/scripts/iptables.sh" apply
    log "DNS 已接管 (port 5591)"
else
    log "AdGuardHome 未就绪，跳过 DNS 接管"
fi

# 启动看门狗（后台常驻）
nohup sh "$MODDIR/scripts/watchdog.sh" >> /data/adb/agh/logs/watchdog.log 2>&1 &
