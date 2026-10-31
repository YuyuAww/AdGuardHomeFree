#!/system/bin/sh
# api.cgi - WebUI 控制台 API（busybox httpd CGI）
# 由 scripts/control.sh 复制到运行时 WebUI 目录并执行。
#
# 请求：/cgi-bin/api.cgi?action=status|start|stop|restart[&t=<token>]
#
# 安全模型（旧版是 Access-Control-Allow-Origin: * + 零鉴权，等于把「关掉全机去广告」
# 的开关开放给任意网页与本机任意 App）：
#   1. 不再输出任何 CORS 头。同源页面（本控制台）不需要它；输出星号只会让任意
#      https 页面跨源读到模块状态与日志。
#   2. start/stop/restart 必须携带令牌 t，令牌由 control.sh 启动控制台时随机生成，
#      写入 /data/adb/agh/run/api.token（chmod 600），非 root 进程无法读取。
#   3. status 免令牌即可探活；日志内容需令牌（通过 AGHFREE_LOG=1 传给 control.sh）。
set -u

MODDIR="${MODDIR:-}"
if [ -z "$MODDIR" ] || [ ! -f "$MODDIR/scripts/control.sh" ]; then
    # CGI 环境未注入 MODDIR 时按模块 id 兜底（三家管理器目录一致）
    for d in /data/adb/modules/adguardhomefree /data/adb/modules_update/adguardhomefree; do
        if [ -f "$d/scripts/control.sh" ]; then
            MODDIR="$d"
            break
        fi
    done
fi

if [ -z "$MODDIR" ] || [ ! -f "$MODDIR/scripts/control.sh" ]; then
    echo "Status: 500 Internal Server Error"
    echo "Content-Type: application/json; charset=utf-8"
    echo "Cache-Control: no-store"
    echo ""
    echo '{"ok":false,"error":"module-not-found"}'
    exit 0
fi

. "$MODDIR/scripts/common.sh"

# ---------- 响应头 ----------
emit_headers() {
    # $1 = 可选状态行（如 "403 Forbidden"）
    [ -n "${1:-}" ] && echo "Status: $1"
    echo "Content-Type: application/json; charset=utf-8"
    echo "Cache-Control: no-store"
    echo "X-Content-Type-Options: nosniff"
    echo "Referrer-Policy: no-referrer"
    echo ""
}

# ---------- 参数解析（QUERY_STRING 由 httpd 注入） ----------
QS="${QUERY_STRING:-}"

# 逐参数解析：QUERY_STRING 不带前导 '?'，所以 '[?&]t=' 这种正则匹配不到
# 「令牌放在第一个参数」的形式（?t=abc&action=stop → QUERY_STRING=t=abc&action=stop），
# 会让完全合法的请求被误判成 403。这里先按 '&' 拆成多行，再按行首精确匹配。
qs_get() {
    printf '%s' "$QS" | $BUSYBOX tr '&' '\n' | $BUSYBOX sed -n "s/^$1=//p" | $BUSYBOX head -n1
}

ACTION="$(qs_get action)"
[ -n "$ACTION" ] || ACTION="status"

PROVIDED="$(qs_get t)"
[ -n "$PROVIDED" ] || PROVIDED="${HTTP_X_AUTH_TOKEN:-}"

TOKEN_FILE="$PID_DIR/api.token"
EXPECTED=""
if [ -r "$TOKEN_FILE" ]; then
    EXPECTED="$($BUSYBOX tr -d ' \r\n\t' < "$TOKEN_FILE" 2>/dev/null)"
fi

authorized() {
    [ -n "$EXPECTED" ] && [ "$PROVIDED" = "$EXPECTED" ]
}

# ---------- 分发 ----------
case "$ACTION" in
    status)
        emit_headers ""
        if authorized; then
            AGHFREE_LOG=1 sh "$MODDIR/scripts/control.sh" status
        else
            sh "$MODDIR/scripts/control.sh" status
        fi
        ;;
    start|stop|restart)
        if ! authorized; then
            emit_headers "403 Forbidden"
            echo '{"ok":false,"error":"unauthorized","hint":"缺少或错误的访问令牌 t（见 /data/adb/agh/run/api.token）"}'
            exit 0
        fi
        emit_headers ""
        sh "$MODDIR/scripts/control.sh" "$ACTION"
        ;;
    *)
        emit_headers "400 Bad Request"
        echo '{"ok":false,"error":"bad-action"}'
        ;;
esac
