#!/system/bin/sh
# AdGuardHomeFree service.sh (P0-T1)
# Root service started by the KSU/APatch manager at boot.
# P0 scope: wait for boot, start AGH + aghbridge (setsid), run supervise stub.
# P0 scope does NOT auto-install iptables / change DNSResolver (P0-T3 is
# operator-driven via aghfctl.sh); that automation lands in P2.

MODDIR="${MODPATH:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}"
. "$MODDIR/common/logger.sh"
AGHF_ROOTENV_LIB=1 . "$MODDIR/common/rootenv.sh"
rootenv_probe
_rc=$?
if [ "$_rc" -ne 0 ]; then
  aghf_log ERROR P0-T1 "service.sh abort: rootenv rc=$_rc (no reboot loop)"
  exit 0
fi

# ---- wait for boot_completed (bounded 120s) ----
i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $i -lt 60 ]; do
  sleep 2
  i=$((i + 1))
done

# AGH needs the system CA store to fetch https filters (pattern adopted from
# the liuzq2002 reference module).
export SSL_CERT_DIR="/system/etc/security/cacerts/"

mkdir -p "$AGHF_DATA_DATA" "$AGHF_LOGS" "$AGHF_RUN" 2>/dev/null

# ---- start AdGuardHome (guard against double start) ----
if [ -f "$AGHF_RUN/agh.pid" ] && kill -0 "$(cat "$AGHF_RUN/agh.pid")" 2>/dev/null; then
  aghf_log INFO P0-T1 "AGH already running pid=$(cat "$AGHF_RUN/agh.pid")"
else
  setsid "$AGH_BIN" --config "$AGHF_DATA_DATA/AdGuardHome.yaml" \
       --work-dir "$AGHF_DATA_DATA" -v >> "$AGHF_LOGS/agh.log" 2>&1 &
  echo $! > "$AGHF_RUN/agh.pid"
  aghf_log INFO P0-T1 "AGH started pid=$(cat "$AGHF_RUN/agh.pid")"
fi

# ---- start aghbridge ----
if [ -f "$AGHF_RUN/bridge.pid" ] && kill -0 "$(cat "$AGHF_RUN/bridge.pid")" 2>/dev/null; then
  aghf_log INFO P0-T1 "bridge already running pid=$(cat "$AGHF_RUN/bridge.pid")"
else
  setsid "$BRIDGE_BIN" --listen "127.0.0.1:$BRIDGE_PORT" \
       -impl "$AGHF_ROOT_IMPL" >> "$AGHF_LOGS/bridge.log" 2>&1 &
  echo $! > "$AGHF_RUN/bridge.pid"
  aghf_log INFO P0-T1 "bridge started pid=$(cat "$AGHF_RUN/bridge.pid")"
fi

# ---- P0 stub of the supervision loop (main loop lands in P2-T5) ----
sh "$MODDIR/supervise.sh" >/dev/null 2>&1

aghf_log INFO P0-T1 "service.sh done impl=$AGHF_ROOT_IMPL"
