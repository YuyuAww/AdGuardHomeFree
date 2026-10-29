#!/system/bin/sh
# control.sh - 模块控制台服务 + 控制动作
# 两种调用方式：
#   1) 无参数（由 service.sh 调用）：启动 busybox httpd 控制台服务（127.0.0.1:5592），
#      提供 WebUI 页面与 /cgi-bin/api.cgi 状态/启停接口。
#   2) 带动作参数（由 WebUI 的 ksu.exec 桥 或 api.cgi 调用）：
#      control.sh status|start|stop|restart
#      输出 JSON 到 stdout，供桥接层解析。
MODDIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$MODDIR/scripts/common.sh"

PORT="$CTRL_PORT_DEFAULT"

# ---------- JSON 工具 ----------
json_escape() {
    # 稳健的 JSON 字符串转义（用于日志/路径输出）。
    # awk 逐行处理：行内容转义引号/反斜杠；行间由默认 ORS（换行）拼接为 \n。
    printf '%s' "$1" | $BUSYBOX awk '{
        gsub(/\\/, "\\\\");
        gsub(/"/, "\\\"");
        gsub(/\t/, "\\t");
        gsub(/\r/, "\\r");
        printf "%s\\n", $0;
    }' 2>/dev/null
}

# ---------- 状态采集 ----------
status_json() {
    local proc="false" dns="false" web="false"
    local logtext="" ver=""

    agh_is_running && proc="true"

    # DNS 接管判定：OUTPUT 链上存在 AGHFREE 链
    if $BUSYBOX iptables -t nat -C OUTPUT -j AGHFREE 2>/dev/null; then
        dns="true"
    fi

    # 管理台可达性：ADMIN_PORT 有监听
    if $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ":$ADMIN_PORT_DEFAULT"; then
        web="true"
    fi

    # 版本：优先 build-info.txt
    if [ -f "$MODDIR/build-info.txt" ]; then
        ver="$($BUSYBOX grep '^agh_version=' "$MODDIR/build-info.txt" | $BUSYBOX head -n1 | $BUSYBOX sed 's/^agh_version=//')"
    fi
    [ -n "$ver" ] || ver="$($BUSYBOX grep '^version=' "$MODDIR/module.prop" 2>/dev/null | $BUSYBOX head -n1 | $BUSYBOX sed 's/^version=//')"

    # 最近日志（module.log 尾部）
    if [ -f "$LOG_DIR/module.log" ]; then
        logtext="$($BUSYBOX tail -n 30 "$LOG_DIR/module.log" 2>/dev/null)"
    fi

    echo "{"
    echo "  \"ok\":true,"
    echo "  \"process\":$proc,"
    echo "  \"dns\":$dns,"
    echo "  \"web\":$web,"
    echo "  \"dns_port\":$(json_escape "$DNS_PORT"),"
    echo "  \"admin_port\":$(json_escape "$ADMIN_PORT_DEFAULT"),"
    echo "  \"ctrl_port\":$(json_escape "$CTRL_PORT_DEFAULT"),"
    echo "  \"version\":\"$(json_escape "$ver")\","
    echo "  \"log\":\"$(json_escape "$logtext")\""
    echo "}"
}

# ---------- 动作实现 ----------
do_start() {
    agh_start
    sleep 1
    if $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ":$DNS_PORT"; then
        sh "$MODDIR/scripts/iptables.sh" apply
    fi
    echo "{\"ok\":true,\"action\":\"start\"}"
}

do_stop() {
    sh "$MODDIR/scripts/iptables.sh" clear
    agh_stop
    echo "{\"ok\":true,\"action\":\"stop\"}"
}

do_restart() {
    sh "$MODDIR/scripts/iptables.sh" clear
    agh_stop
    sleep 1
    agh_start
    sleep 1
    if $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ":$DNS_PORT"; then
        sh "$MODDIR/scripts/iptables.sh" apply
    fi
    echo "{\"ok\":true,\"action\":\"restart\"}"
}

# ---------- 控制台服务（busybox httpd + CGI） ----------
start_server() {
    # 运行时 WebUI 根：避免写入只读模块目录，也便于清理
    WEB_ROOT="$RUNTIME_DIR/webui"
    mkdir -p "$WEB_ROOT/cgi-bin"

    # 页面与 CGI 复制到运行时目录（幂等）
    cp -f "$MODDIR/webroot/index.html" "$WEB_ROOT/index.html" 2>/dev/null || true
    cp -f "$MODDIR/scripts/api.cgi"   "$WEB_ROOT/cgi-bin/api.cgi" 2>/dev/null || true
    chmod 755 "$WEB_ROOT/cgi-bin/api.cgi" 2>/dev/null || true

    # 停掉旧的控制台实例
    $BUSYBOX pkill -f "httpd.*127.0.0.1:$PORT" 2>/dev/null || true
    sleep 1

    # 启动（不 daemonize，交给 shell 后台管理）
    export MODDIR
    nohup "$BUSYBOX" httpd -p "127.0.0.1:$PORT" -h "$WEB_ROOT" \
        >> "$LOG_DIR/control.log" 2>&1 &
    echo $! > "$PID_DIR/control.pid" 2>/dev/null || true

    log "控制台服务已启动 (http://127.0.0.1:$PORT)"
}

# ---------- 分发 ----------
case "${1:-}" in
    status)  status_json ;;
    start)   do_start ;;
    stop)    do_stop ;;
    restart) do_restart ;;
    "")      start_server ;;
    *)
        echo "usage: $0 {status|start|stop|restart}" >&2
        exit 2
        ;;
esac
