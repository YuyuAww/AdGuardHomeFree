#!/system/bin/sh
# AdGuardHomeFree supervise.sh (P0-T1: stub)
# P0 stub only. The setsid supervision main loop (AGH liveness + iptables -C
# rule re-add, pattern from the liuzq2002 reference module) lands in P2-T5.

# This file lives in common/; module root is one level up (INV-05).
if [ -n "$MODPATH" ]; then
  MODDIR="$MODPATH"
else
  MODDIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fi
. "$MODDIR/common/logger.sh"

aghf_log INFO P0-T1 "supervise stub: supervision main loop not yet implemented (P2-T5)"
exit 0
