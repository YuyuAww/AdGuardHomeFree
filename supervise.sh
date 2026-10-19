#!/system/bin/sh
# AdGuardHomeFree supervise.sh (P0-T1: stub)
# P0 stub only. The setsid supervision main loop (AGH liveness + iptables -C
# rule re-add, pattern from the liuzq2002 reference module) lands in P2-T5.

MODDIR="${MODPATH:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
. "$MODDIR/common/logger.sh"

aghf_log INFO P0-T1 "supervise stub: supervision main loop not yet implemented (P2-T5)"
exit 0
