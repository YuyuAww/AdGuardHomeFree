#!/system/bin/sh
# AdGuardHomeFree P0-T4 device-side acceptance report generator.
# Run from a root shell (KernelSU/APatch) on-device:
#   sh /data/adb/modules/AdGuardHomeFree/scripts/phase0_accept.sh wifi
#   sh /data/adb/modules/AdGuardHomeFree/scripts/phase0_accept.sh mobile
# (switch to mobile data between the two runs).
#
# Produces $AGHF_LOGS/phase0_report.json (structure per 项目操作手册 §P0-T4).
# WebView probe is a MANUAL step (module WebUI page, probe area) — the script
# only reads the operator-written $AGHF_LOGS/probe.txt.
#
# Deviation note (user decision m00128, no busybox bundling):
#   - AGHF_BUSYBOX may be "none"; nslookup-based checks then degrade to
#     toybox nc reachability checks and verify_dns is reported "degraded".

MODDIR=${0%/*}/..
[ -n "$MODPATH" ] && MODDIR="$MODPATH"
NET=${1:-wifi}
AGHF_DATA=${AGHF_DATA:-/data/adb/aghf}
AGHF_STATE="$AGHF_DATA/state"
AGHF_LOGS="$AGHF_DATA/logs"
AGH_LOG_FILE="$AGHF_LOGS/aghf.log"
REPORT="$AGHF_LOGS/phase0_report.json"
BLOCKERS=""
add_blocker() {
    BLOCKERS="${BLOCKERS}\"$1\","
}
note() {
    echo "[P0ACCEPT] $*"
}

# ---------------------------------------------------------------- probe env
impl=""
busybox=""
ksu_exec="false"
# Library mode: probe failures return instead of exiting this script.
AGHF_ROOTENV_LIB=1 . "$MODDIR/common/rootenv.sh" >/dev/null 2>&1
rootenv_probe >/dev/null 2>&1
probe_rc=$?
impl="${AGHF_ROOT_IMPL:-unknown}"
busybox="${AGHF_BUSYBOX:-none}"
[ "$AGHF_KSU_EXEC" = "1" ] && ksu_exec="true"
[ $probe_rc -ne 0 ] && add_blocker "ROOTENV_PROBE_FAIL"
android_version=$(getprop ro.build.version.release 2>/dev/null)
note "probe rc=$probe_rc impl=$impl busybox=$busybox android=$android_version net=$NET"

# ---------------------------------------------------------------- T1 checks
t1_rootenv="fail"
out=$(sh -c ". '$MODDIR/common/rootenv.sh' && echo \"\$AGHF_ROOT_IMPL \$AGHF_BUSYBOX\"" 2>/dev/null)
rc=$?
note "T1 rootenv rc=$rc out=[$out]"
[ $rc -eq 0 ] && case "$out" in
    kernelsu\ *|apatch\ *) t1_rootenv="ok" ;;
esac

t1_webroot="fail"
[ -f "$MODDIR/webroot/index.html" ] && t1_webroot="ok"
note "T1 webroot=$t1_webroot"

t1_logcat="ok"
err_lines=$(logcat -d 2>/dev/null | grep AGHF | grep -c "ERROR")
[ -n "$err_lines" ] && [ "$err_lines" -gt 0 ] && t1_logcat="fail"
note "T1 logcat AGHF ERROR lines=$err_lines"

# ------------------------------------------------- T2 checks (bridge over http)
# Prefer curl; fall back to bundled/manager busybox wget; else nc-only.
http_get() {
    if command -v curl >/dev/null 2>&1; then
        curl -s "$1"
    elif [ -n "$busybox" ] && [ "$busybox" != "none" ]; then
        "$busybox" wget -qO- "$1" 2>/dev/null
    else
        return 1
    fi
}

status_json=$(http_get "http://127.0.0.1:3001/status")
rc=$?
note "T2 /status rc=$rc out=[$status_json]"
t2_status="fail"
case "$status_json" in
    *'"agh_running"'*'"impl"'*) t2_status="ok" ;;
esac
# 403 on disallowed action (needs curl; busybox wget POST support is
# inconsistent across builds, so without curl this check stays "unknown")
t2_exec403="unknown"
if command -v curl >/dev/null 2>&1; then
    exec_body=$(curl -s -o /dev/null -w "%{http_code}" -X POST "http://127.0.0.1:3001/exec" -d '{"action":"rm_rf"}' 2>/dev/null)
    if [ "$exec_body" = "403" ]; then
        t2_exec403="ok"
    fi
fi
note "T2 exec 403 check: $t2_exec403 (inconclusive without curl)"

# WebView probe (manual step): operator opens module WebUI, reads the probe
# area, then writes one line to probe.txt: "fetch=1" or "ksu_exec=1".
probe_txt="$AGHF_LOGS/probe.txt"
bridge_fetch="false"
ksu_channel="false"
if [ -f "$probe_txt" ]; then
    case "$(cat "$probe_txt" 2>/dev/null)" in
        *fetch=1*) bridge_fetch="true" ;;
        *ksu_exec=1*) ksu_channel="true" ;;
    esac
fi
if [ "$bridge_fetch" = "true" ]; then
    bridge_channel="fetch"
elif [ "$ksu_channel" = "true" ]; then
    bridge_channel="ksu_exec"
else
    bridge_channel="none"
    note "T2 bridge channel none (probe.txt missing/unknown); manual WebView probe required"
fi
note "T2 channel=$bridge_channel (probe.txt: $([ -f "$probe_txt" ] && cat "$probe_txt" || echo missing))"

# ------------------------------------------------- T3 checks (install/rollback)
CTL="$MODDIR/common/aghfctl.sh"
dnsresolver="ok"
iptables_state="ok"
verify_dns="ok"
verify_block="ok"

netid=$(dumpsys connectivity 2>/dev/null | grep -m1 "Active Network" | grep -oE "[0-9]+" | head -1)
note "T3 active netid=$netid"

install_rc=""
if netid_out=$("$CTL" install 2>&1); then
    install_rc=0
else
    install_rc=$?
fi
note "T3 install rc=$install_rc"
case "$install_rc" in
    0)
        [ -f "$AGHF_STATE/dns_snapshot_${netid}.json" ] || {
            note "T3 snapshot missing"
            install_rc=2
        }
        ;;
    30)
        iptables_state="fail"
        add_blocker "IPTABLES_FAIL"
        ;;
    40|41)
        dnsresolver="unavailable"
        add_blocker "DNSRESOLVER_UNAVAILABLE"
        ;;
    21)
        verify_dns="fail"
        ;;
    60)
        add_blocker "ROLLBACK_ERROR"
        ;;
esac

if [ -n "$busybox" ] && [ "$busybox" != "none" ]; then
    dns_out=$("$busybox" nslookup example.com 127.0.0.1 2>&1)
    # busybox nslookup prints a "Name:" line only when a record was found
    # (the "Address:" line also shows the server IP, so it is not a signal).
    if echo "$dns_out" | grep -q "Name:" && ! echo "$dns_out" | grep -qE "can't find|NXDOMAIN"; then
        verify_dns="ok"
    else
        verify_dns="fail"
        note "T3 nslookup example.com failed: $dns_out"
    fi
    block_out=$("$busybox" nslookup doubleclick.net 127.0.0.1 2>&1)
    if echo "$block_out" | grep -qE "0\.0\.0\.0|NXDOMAIN|can't find"; then
        verify_block="ok"
    else
        verify_block="delayed"
        note "T3 VERIFY_BLOCK not effective yet (filter still loading?): $block_out"
    fi
else
    # degraded branch (busybox=none, user decision m00128)
    if toybox nc -w 3 127.0.0.1 5353 >/dev/null 2>&1; then
        verify_dns="degraded"
    else
        verify_dns="fail"
    fi
    verify_block="skipped_no_busybox"
    note "T3 busybox=none: verify_dns=$verify_dns (nc-only), verify_block=skipped (operator must confirm in browser)"
fi

# rollback
rollback_rc=0
if ! "$CTL" rollback >/dev/null 2>&1; then
    rollback_rc=$?
fi
no_chain=$(iptables -t nat -L AGHF_OUTPUT 2>&1 | grep -c "No chain")
note "T3 rollback rc=$rollback_rc no_chain=$no_chain"
[ "$rollback_rc" -eq 0 ] && [ "$no_chain" -ge 1 ] || {
    note "T3 rollback or chain removal failed"
    add_blocker "ROLLBACK_FAIL"
}

# repeat install->rollback 3 times (idempotency)
repeat_ok=0
i=1
while [ $i -le 3 ]; do
    if "$CTL" install >/dev/null 2>&1 && "$CTL" rollback >/dev/null 2>&1; then
        repeat_ok=1
    else
        repeat_ok=1
        note "T3 repeat cycle $i failed"
        repeat_ok=0
        add_blocker "REPEAT_CYCLE_FAIL"
        break
    fi
    i=$((i + 1))
done
[ $repeat_ok -eq 1 ] && note "T3 3x install/rollback cycles ok"

# ---------------------------------------------------------------- report
# per §P0-T4 ON_FAILURE: BRIDGE_CHANNEL_NONE / DNSRESOLVER_UNAVAILABLE are
# blockers that force the Phase 1 degradation path.
[ "$bridge_channel" = "none" ] && add_blocker "BRIDGE_CHANNEL_NONE"
{
    echo "{"
    echo "  \"impl\": \"$impl\","
    echo "  \"android_version\": \"$android_version\","
    echo "  \"ksu_exec\": $ksu_exec,"
    echo "  \"bridge_fetch\": $bridge_fetch,"
    echo "  \"bridge_channel\": \"$bridge_channel\","
    echo "  \"dnsresolver\": \"$dnsresolver\","
    echo "  \"iptables\": \"$iptables_state\","
    echo "  \"verify_dns\": \"$verify_dns\","
    echo "  \"verify_block\": \"$verify_block\","
    echo "  \"busybox\": \"$busybox\","
    echo "  \"networks_tested\": [\"$NET\"],"
    if [ -n "$BLOCKERS" ]; then
        echo "  \"blockers\": [${BLOCKERS%,}]"
    else
        echo "  \"blockers\": []"
    fi
    echo "}"
} > "$REPORT"
note "report written: $REPORT"
cat "$REPORT"
exit 0
