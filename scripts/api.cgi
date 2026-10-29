#!/system/bin/sh
# api.cgi - WebUI 控制台 API（busybox httpd CGI）
# 由 scripts/control.sh 复制到运行时 WebUI 目录并执行。
# 请求：/cgi-bin/api.cgi?action=status|start|stop|restart
# 职责：输出 CORS 头 + 委托给 scripts/control.sh 的动作模式，透传其 JSON。
# 说明：busybox httpd 会以 root 运行本脚本；所有动作均由 control.sh 通过
#       common.sh 的模块辅助函数执行。

set -u

if [ -z "${MODDIR:-}" ]; then
    echo "Content-Type: text/plain"
    echo ""
    echo '{"ok":false,"error":"MODDIR not set"}'
    exit 1
fi
. "$MODDIR/scripts/common.sh"

# 解析 action 参数（QUERY_STRING 由 httpd 注入）
ACTION=""
if [ -n "${QUERY_STRING:-}" ]; then
    ACTION="$($BUSYBOX printf '%s' "$QUERY_STRING" | $BUSYBOX sed -n 's/.*action=\([^&]*\).*/\1/p')"
fi
[ -n "$ACTION" ] || ACTION="status"

# 输出响应头（含 CORS，支持跨源页面调用）
echo "Content-Type: application/json; charset=utf-8"
echo "Access-Control-Allow-Origin: *"
echo "Access-Control-Allow-Methods: GET, POST, OPTIONS"
echo "Access-Control-Allow-Headers: Content-Type"
echo "Cache-Control: no-store"
echo ""

# 委托给控制脚本动作模式，透传 JSON 输出
sh "$MODDIR/scripts/control.sh" "$ACTION"
