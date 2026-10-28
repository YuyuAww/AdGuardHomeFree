#!/system/bin/sh
# watchdog.sh - AdGuardHome 进程守护
# 由 service.sh 后台启动；周期性检测主进程，异常退出时有限次重启。
MODDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$MODDIR/scripts/common.sh"

CFG="/data/adb/agh/AdGuardHome.yaml"
[ -f "$CFG" ] || CFG="$MODDIR/bin/AdGuardHome.yaml"

MAX_RESTARTS=10   # 重启窗口内最多重启次数
WINDOW=600        # 重启计数窗口（秒）
CHECK_INTERVAL=20

COUNT=0
START_TS=$(date +%s)

while true; do
    sleep $CHECK_INTERVAL

    if ! $BUSYBOX pgrep -f "$MODDIR/bin/AdGuardHome" > /dev/null 2>&1; then
        NOW=$(date +%s)
        # 滑动窗口：超出窗口则重置计数
        if [ $((NOW - START_TS)) -gt $WINDOW ]; then
            COUNT=0
            START_TS=$NOW
        fi
        COUNT=$((COUNT + 1))

        if [ $COUNT -gt $MAX_RESTARTS ]; then
            log "watchdog: AdGuardHome 重启超限 (${COUNT}/${MAX_RESTARTS})，停止守护并清除 DNS 接管"
            sh "$MODDIR/scripts/iptables.sh" clear
            exit 1
        fi

        log "watchdog: 检测到 AdGuardHome 退出，第 ${COUNT} 次重启"
        sh "$MODDIR/scripts/iptables.sh" clear

        export SSL_CERT_DIR="/system/etc/security/cacerts/"
        "$MODDIR/bin/AdGuardHome" -c "$CFG" -w "/data/adb/agh" \
            >> /data/adb/agh/logs/agh.log 2>&1 &

        # 等待端口就绪后再重新接管 DNS
        j=0
        while [ $j -lt 15 ]; do
            if $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ':5591'; then
                break
            fi
            sleep 1
            j=$((j + 1))
        done
        if $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ':5591'; then
            sh "$MODDIR/scripts/iptables.sh" apply
        fi
    fi
done