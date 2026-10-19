#!/system/bin/sh
# AdGuardHomeFree common/rootenv.sh (P0-T1)
# Resolves and exports every §1.1/§1.2 path + env var.
# Exit codes per manual §1.4: 10 = environment probe failure.
#
# Sourceable: when AGHF_ROOTENV_LIB=1 is set before sourcing, the standalone
# exit is suppressed and probe failures return non-zero from rootenv_probe
# instead of exiting, so callers (service.sh / aghfctl.sh) can log and degrade.

# ---------- MODDIR resolution (INV-05: no hardcoded root in business code) ----
if [ -n "$MODPATH" ]; then
  MODDIR="$MODPATH"
elif [ -n "${BASH_SOURCE:-}" ]; then
  case "$BASH_SOURCE" in
    */common/*) MODDIR="$(dirname "$(dirname "$BASH_SOURCE")")" ;;
    */bin/*)    MODDIR="$(dirname "$(dirname "$BASH_SOURCE")")" ;;
    *)          MODDIR="$(dirname "$BASH_SOURCE")" ;;
  esac
elif case "${0:-}" in */common/*|*/bin/*) true ;; *) false ;; esac; then
  MODDIR="$(dirname "$(dirname "$0")")"
else
  # Last-resort fallback only (manual §1.1 canonical path).
  MODDIR="/data/adb/modules/AdGuardHomeFree"
fi

rootenv_probe() {
  # §1.1 data paths (fixed by manual; not the module root)
  AGHF_DATA="/data/adb/aghf"
  AGHF_DATA_DATA="$AGHF_DATA/data"
  AGHF_LOGS="$AGHF_DATA/logs"
  AGHF_RUN="$AGHF_DATA/run"
  AGHF_STATE="$AGHF_DATA/state"
  AGH_BIN="$MODDIR/bin/AdGuardHome"
  AGH_DNS_PORT="5353"
  AGH_WEB_PORT="3000"
  BRIDGE_PORT="3001"
  BRIDGE_BIN="$MODDIR/bin/aghbridge"

  # ---------- AGHF_ROOT_IMPL ----------
  # Test hook: a pre-set AGHF_ROOT_IMPL (kernelsu|apatch) is trusted.
  case "${AGHF_ROOT_IMPL:-}" in
    kernelsu|apatch) : ;;
    *)
      AGHF_ROOT_IMPL=""
      if [ -n "$APATCH" ]; then
        AGHF_ROOT_IMPL="apatch"
      elif [ -n "$KSU" ]; then
        AGHF_ROOT_IMPL="kernelsu"
      fi
      ;;
  esac
  if [ -z "$AGHF_ROOT_IMPL" ]; then
    # P0-T1 ON_FAILURE diagnostic: dump busybox candidate paths before exit 10.
    echo "[rootenv] AGHF_ROOT_IMPL unknown; busybox candidates:" >&2
    ls -l /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox \
          "$MODDIR/bin/busybox" /system/bin/toybox 2>/dev/null >&2
    echo "[rootenv] set APATCH=1 (APatch) or KSU=1 (KernelSU) context var" >&2
    AGHF_ROOT_IMPL="unknown"
    return 10
  fi

  # ---------- AGHF_BUSYBOX (optional; user decision m00128: do not require) ----
  # Priority: module-bundled bin/busybox -> manager busybox -> toybox -> none.
  case "$AGHF_ROOT_IMPL" in
    apatch)   _bb_cand="$MODDIR/bin/busybox /data/adb/ap/bin/busybox /system/bin/toybox" ;;
    *)        _bb_cand="$MODDIR/bin/busybox /data/adb/ksu/bin/busybox /system/bin/toybox" ;;
  esac
  AGHF_BUSYBOX=""
  for _b in $_bb_cand; do
    if [ -x "$_b" ]; then AGHF_BUSYBOX="$_b"; break; fi
  done
  if [ -z "$AGHF_BUSYBOX" ]; then
    AGHF_BUSYBOX="none"
    echo "[rootenv] WARN: no busybox/toybox found; degraded DNS verify (P0-T3)" >&2
  fi

  # ---------- AGHF_IPTABLES ----------
  if command -v iptables >/dev/null 2>&1; then
    AGHF_IPTABLES="iptables"
  elif command -v iptables-legacy >/dev/null 2>&1; then
    AGHF_IPTABLES="iptables-legacy"
  else
    echo "[rootenv] ERROR: neither iptables nor iptables-legacy available" >&2
    return 10
  fi
  # P0 does not install IPv6 nat chains (manual §9: IPv6 handling lands in P3).
  # Export the name for P3; empty means "not probed / not used yet".
  AGHF_IP6TABLES="ip6tables"

  # ---------- AGHF_KSU_EXEC ----------
  # Whether the KSU ksu CLI (webview exec channel) is available.
  # Final value is confirmed by the WebView probe (app.js) in P0-T2.
  if [ "$AGHF_ROOT_IMPL" = "kernelsu" ] && command -v ksu >/dev/null 2>&1; then
    AGHF_KSU_EXEC=1
  else
    AGHF_KSU_EXEC=0
  fi

  # ---------- AGHF_BRIDGE_FETCH ----------
  # WebView fetch-channel flag: 0 until app.js proves fetch works.
  AGHF_BRIDGE_FETCH="${AGHF_BRIDGE_FETCH:-0}"

  export MODDIR AGHF_DATA AGHF_DATA_DATA AGHF_LOGS AGHF_RUN AGHF_STATE
  export AGH_BIN AGH_DNS_PORT AGH_WEB_PORT BRIDGE_PORT BRIDGE_BIN
  export AGHF_ROOT_IMPL AGHF_BUSYBOX AGHF_IPTABLES AGHF_IP6TABLES
  export AGHF_KSU_EXEC AGHF_BRIDGE_FETCH
  return 0
}

rootenv_main() {
  . "$(dirname "$0")/logger.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE:-$0}")/logger.sh" 2>/dev/null
  rootenv_probe
  _rc=$?
  if [ $_rc -eq 0 ]; then
    aghf_log INFO P0-T1 "rootenv ok impl=$AGHF_ROOT_IMPL busybox=$AGHF_BUSYBOX iptables=$AGHF_IPTABLES"
  else
    aghf_log ERROR P0-T1 "rootenv probe failed rc=$_rc impl=${AGHF_ROOT_IMPL:-unknown}"
    exit $_rc
  fi
}

if [ "${AGHF_ROOTENV_LIB:-0}" != "1" ]; then
  rootenv_main
fi
