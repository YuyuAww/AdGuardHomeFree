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
    local logtext="" ver="" loglocked="false"

    agh_is_running && proc="true"

    # DNS 接管判定：IPv4 或 IPv6 的 OUTPUT 链上存在 AGHFREE 跳转即视为已接管
    if $BUSYBOX iptables -t nat -C OUTPUT -j AGHFREE 2>/dev/null; then
        dns="true"
    elif $BUSYBOX ip6tables -t nat -C OUTPUT -j AGHFREE 2>/dev/null; then
        dns="true"
    fi

    # 管理台可达性：使用配置里的实际端口（http.address），不再写死 3000
    if $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ":$ADMIN_PORT"; then
        web="true"
    fi

    # 版本：优先 build-info.txt。grep 不加 ^ 锚点，兼容历史上被写入 UTF-8 BOM 的文件。
    if [ -f "$MODDIR/build-info.txt" ]; then
        ver="$($BUSYBOX grep 'agh_version=' "$MODDIR/build-info.txt" 2>/dev/null | $BUSYBOX head -n1 | $BUSYBOX sed 's/.*agh_version=//')"
    fi
    [ -n "$ver" ] || ver="$($BUSYBOX grep 'version=' "$MODDIR/module.prop" 2>/dev/null | $BUSYBOX head -n1 | $BUSYBOX sed 's/.*version=//')"

    # 日志门控：只有通过令牌校验的请求（api.cgi 传 AGHFREE_LOG=1）才返回内容，
    # 否则本机任意 App 探测 127.0.0.1:5592 就能读到用户的域名访问记录。
    if [ -f "$LOG_DIR/module.log" ]; then
        if [ "${AGHFREE_LOG:-0}" = "1" ]; then
            logtext="$($BUSYBOX tail -n 30 "$LOG_DIR/module.log" 2>/dev/null)"
        else
            loglocked="true"
        fi
    fi

    echo "{"
    echo "  \"ok\":true,"
    echo "  \"process\":$proc,"
    echo "  \"dns\":$dns,"
    echo "  \"web\":$web,"
    echo "  \"dns_port\":$(json_escape "$DNS_PORT"),"
    echo "  \"admin_port\":$(json_escape "$ADMIN_PORT"),"
    echo "  \"ctrl_port\":$(json_escape "$CTRL_PORT_DEFAULT"),"
    echo "  \"version\":\"$(json_escape "$ver")\","
    echo "  \"log_locked\":$loglocked,"
    echo "  \"log\":\"$(json_escape "$logtext")\""
    echo "}"
}

# ---------- 动作实现 ----------
port_listening() {
    $BUSYBOX netstat -tln 2>/dev/null | $BUSYBOX grep -q ":$DNS_PORT"
}

# 有界等待 DNS 端口就绪：AGH 首次加载过滤列表通常需要数秒，固定 sleep 1 不可靠
wait_port() {
    local n="${1:-15}" i=0
    while [ $i -lt "$n" ]; do
        port_listening && return 0
        sleep 1
        i=$((i+1))
    done
    port_listening
}

do_start() {
    # 幂等：已在运行就只补接管规则，不再起第二个实例。
    # 否则连点两次「启动」会起第二个进程，它绑定 5591 失败退出，
    # 看门狗随即判定「进程不在」又重启，日志里会出现莫名其妙的循环。
    if agh_is_running && port_listening; then
        sh "$MODDIR/scripts/iptables.sh" apply
        echo "{\"ok\":true,\"action\":\"start\",\"dns\":true,\"already\":true}"
        return 0
    fi
    agh_start
    wait_port 15
    if port_listening; then
        sh "$MODDIR/scripts/iptables.sh" apply
        echo "{\"ok\":true,\"action\":\"start\",\"dns\":true}"
    else
        echo "{\"ok\":true,\"action\":\"start\",\"dns\":false}"
    fi
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
    wait_port 20
    if port_listening; then
        sh "$MODDIR/scripts/iptables.sh" apply
        echo "{\"ok\":true,\"action\":\"restart\",\"dns\":true}"
    else
        echo "{\"ok\":true,\"action\":\"restart\",\"dns\":false}"
    fi
}

# ---------- 控制台服务（busybox httpd + CGI） ----------
# 生成访问令牌：start/stop/restart 必须携带它（见 scripts/api.cgi）。
# 只有 root 能读 /data/adb/agh/run/api.token（chmod 600），因此本机普通 App
# 无法再通过 127.0.0.1:5592 关闭全机去广告。
gen_token() {
    local raw
    raw="$($BUSYBOX cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
    [ -n "$raw" ] || raw="$(date +%s)-$$-${RANDOM:-0}"
    printf '%s' "$raw" | $BUSYBOX tr -cd '0-9a-zA-Z' | $BUSYBOX cut -c1-32
}

start_server() {
    if [ "${HAVE_BUSYBOX:-0}" != "1" ]; then
        log "控制台服务未启动：未找到 busybox（缺少 httpd），WebUI 请使用模块管理器桥接模式"
        return 0
    fi

    # 运行时 WebUI 根：避免写入只读模块目录，也便于清理
    WEB_ROOT="$RUNTIME_DIR/webui"
    mkdir -p "$WEB_ROOT/cgi-bin"

    # 令牌只在首次生成，之后跨重启复用：
    #   轮换虽更严格，但会让用户每次开机都要重新查看 api.token，实际体验不可用。
    #   文件权限 600 + 位于 /data/adb（0700，adb_data_file 标签）之下，非 root 进程无法读取。
    TOKEN_FILE="$PID_DIR/api.token"
    if [ ! -s "$TOKEN_FILE" ]; then
        TOKEN="$(gen_token)"
        if [ -n "$TOKEN" ]; then
            (umask 077; printf '%s' "$TOKEN" > "$TOKEN_FILE") 2>/dev/null || true
        fi
    fi
    chmod 600 "$TOKEN_FILE" 2>/dev/null || true

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
