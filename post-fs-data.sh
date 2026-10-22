#!/system/bin/sh
# AdGuardHomeFree post-fs-data.sh (P0-T1)
# Early-boot probe stage. INV-06: this stage must NOT start AGH and must NOT
# install iptables — probe only.
# IMP-03 clarification: the only write performed here is probe_kv.txt under
# $AGHF_STATE (our own state dir, created by customize.sh). That is bookkeeping,
# not a system modification, and is explicitly allowed by INV-06, which
# forbids starting AGH / touching iptables at post-fs-data time.

MODDIR="${MODPATH:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
. "$MODDIR/common/logger.sh"
AGHF_ROOTENV_LIB=1 . "$MODDIR/common/rootenv.sh"
rootenv_probe
_rc=$?

if [ "$_rc" -eq 0 ]; then
  aghf_log INFO P0-T1 "post-fs-data probe ok impl=$AGHF_ROOT_IMPL busybox=$AGHF_BUSYBOX iptables=$AGHF_IPTABLES"
  # Probe state consumed by P0-T4 acceptance report.
  {
    echo "AGHF_ROOT_IMPL=$AGHF_ROOT_IMPL"
    echo "AGHF_BUSYBOX=$AGHF_BUSYBOX"
    echo "AGHF_IPTABLES=$AGHF_IPTABLES"
    echo "AGHF_KSU_EXEC=$AGHF_KSU_EXEC"
    echo "AGHF_BRIDGE_FETCH=$AGHF_BRIDGE_FETCH"
    echo "BOOT_COMPLETED=$(getprop sys.boot_completed 2>/dev/null)"
  } > "$AGHF_STATE/probe_kv.txt" 2>/dev/null
else
  aghf_log WARN P0-T1 "post-fs-data probe failed rc=$_rc (see aghf.log)"
  echo "AGHF_ROOT_IMPL=${AGHF_ROOT_IMPL:-unknown}" > "$AGHF_STATE/probe_kv.txt" 2>/dev/null
fi
exit 0
