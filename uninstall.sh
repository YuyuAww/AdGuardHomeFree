#!/system/bin/sh
# AdGuardHomeFree uninstall.sh (P0-T1)
# INV-08: stopping AGH must clean up iptables + restore the DNSResolver.
# Delegate to the aghfctl.sh rollback transaction; only remove module-owned
# processes/state. $AGHF_DATA user config is kept (operator may keep it).

MODDIR="${MODPATH:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
. "$MODDIR/common/logger.sh"
AGHF_ROOTENV_LIB=1 . "$MODDIR/common/rootenv.sh"
rootenv_probe
_rc=$?

if [ "$_rc" -eq 0 ]; then
  # CLI mode (not AGHFCTL_LIB): main dispatches "rollback".
  sh "$MODDIR/common/aghfctl.sh" rollback
  aghf_log INFO P0-T1 "uninstall: rollback rc=$?"
fi

# stop processes we started
for _f in agh bridge; do
  if [ -n "${AGHF_RUN:-}" ] && [ -f "$AGHF_RUN/$_f.pid" ]; then
    kill "$(cat "$AGHF_RUN/$_f.pid")" 2>/dev/null
    rm -f "$AGHF_RUN/$_f.pid"
  fi
done

aghf_log INFO P0-T1 "uninstall done (data dir /data/adb/aghf preserved)"
exit 0
