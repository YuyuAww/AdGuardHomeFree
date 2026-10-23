#!/system/bin/sh
# AdGuardHomeFree aghfctl.sh (P0-T3)
# Minimal DNS takeover transaction:
#   install   = snapshot -> iptables install -> setnetdns 127.0.0.1 -> verify
#               (on A10+ the setnetdns step is EXPECTED to fail - the netd
#               "resolver" NDC command family was removed in Android 10 -
#               the transaction degrades to iptables-only mode: marker
#               $AGHF_STATE/dnsresolver_mode is written, install still
#               exits 0 and continues to VERIFY)
#   rollback  = restore resolver (skipped in degraded mode) ->
#               remove iptables -> drop snapshot
#   status    = print ctl state + live probes
# Exit codes (manual §1.4): 21 verify-dns, 30 ipt install, 40 dnsresolver
# snapshot, 41 netid unavailable, 60 rollback step error.
# NOTE: dnsresolver set failure is NOT an error exit on A10+ (degraded mode);
# exit 40 covers snapshot failure only.
#
# Sourceable: AGHFCTL_LIB=1 skips the CLI main below.
# This file lives in common/; module root is one level up (INV-05).
if [ -n "$MODPATH" ]; then
  _moddir="$MODPATH"
else
  _moddir="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
fi
. "$_moddir/common/logger.sh"
AGHF_ROOTENV_LIB=1 . "$_moddir/common/rootenv.sh"
. "$_moddir/common/iptables.sh"
. "$_moddir/common/dnsresolver.sh"
rootenv_probe
_rc=$?
if [ "$_rc" -ne 0 ]; then
  aghf_log ERROR P0-T3 "aghfctl: rootenv probe failed rc=$_rc"
  exit 10
fi

CTL_STATE="$AGHF_STATE/ctl.json"
SNAPFILE=""

_ctl_write() {
  # $1 = state, $2 = netid
  printf '{"state":"%s","netid":%s,"ts":"%s"}\n' "$1" "${2:-0}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$CTL_STATE"
}

_snapshot_file() {
  # $1 = netid
  echo "$AGHF_STATE/dns_snapshot_${1}.json"
}

_rollback_steps() {
  # inverse order: restore resolver -> remove iptables -> drop snapshot
  # (degraded install: resolver was never overridden, skip restore)
  _rrc=0
  if [ -n "${1:-}" ]; then
    if [ -f "$AGHF_STATE/dnsresolver_mode" ]; then
      aghf_log INFO P0-T3 "rollback: dnsresolver degraded; skip resolver restore"
    else
      dnsresolver_restore "$1" || _rrc=1
    fi
  fi
  rm -f "$AGHF_STATE/dnsresolver_mode"
  ipt_remove || _rrc=1
  if [ -n "$SNAPFILE" ] && [ -f "$SNAPFILE" ]; then
    rm -f "$SNAPFILE" || _rrc=1
  fi
  return $_rrc
}

_agh_alive() {
  for _p in /proc/[0-9]*/comm; do
    [ -r "$_p" ] && [ "$(cat "$_p" 2>/dev/null)" = "AdGuardHome" ] && return 0
  done
  return 1
}

_ghfctl_install() {
  aghf_log INFO P0-T3 "install: begin"

  # 1. active network
  NETID="$(active_netid)"
  if [ -z "$NETID" ]; then
    aghf_log ERROR P0-T3 "install: no active network (netid empty)"
    _ctl_write WAIT_NET
    exit 41
  fi

  # 2. DNSResolver snapshot (INV-09)
  SNAPFILE="$(_snapshot_file "$NETID")"
  if ! dnsresolver_snapshot "$NETID"; then
    aghf_log ERROR P0-T3 "install: dnsresolver_snapshot failed for netid $NETID"
    exit 40
  fi

  # 3. iptables install
  if ! ipt_install; then
    aghf_log ERROR P0-T3 "install: ipt_install failed"
    _rollback_steps "$NETID"
    exit 30
  fi

  # 4. point the network at local AGH (netd resolver override)
  # P0 rescope (2026-10): on Android 10+ the netd NDC "resolver" command
  # family no longer exists (AOSP Q+ NdcDispatcher does not register it;
  # the resolver moved to a separate "dnsresolver" binder service that
  # shell `cmd` cannot reach), so setnetdns is expected to fail on all
  # realistic KSU/APatch targets. Do NOT abort the transaction: fall back
  # to degraded iptables-only mode (the AGH sinkhole still works via nat
  # REDIRECT :53 -> 5353, and the yaml's DoH upstreams prevent the
  # self-redirect loop), mark it, and continue to VERIFY. Per-netId
  # resolver takeover is P1-T1 (binder helper). See manual P0-T3 / section 9.
  if _setraw="$(dnsresolver_set "$NETID" "127.0.0.1" 2>&1)"; then
    _DNSRESOLVER="ok"
  else
    _DNSRESOLVER="degraded"
    echo "degraded" > "$AGHF_STATE/dnsresolver_mode"
    aghf_log WARN P0-T3 "install: setnetdns failed (degraded iptables-only mode); raw: $(printf '%s' "$_setraw" | cut -c1-300)"
  fi

  # 5. VERIFY_DNS
  if [ "$AGHF_BUSYBOX" != "none" ] && [ -x "$AGHF_BUSYBOX" ]; then
    _out="$("$AGHF_BUSYBOX" nslookup example.com 127.0.0.1 2>/dev/null)"
    if ! echo "$_out" | grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}'; then
      aghf_log ERROR P0-T3 "verify-dns failed: no A record via 127.0.0.1"
      _rollback_steps "$NETID"
      exit 21
    fi
    _VBRANCH="busybox_nslookup"
  else
    # degraded path (no busybox on device): check AGH DNS port reachable + AGH
    # alive. BOUNDARY NOTE: this branch still needs TOYBOX for "toybox nc".
    # A device with neither busybox nor toybox cannot run P0-T3 VERIFY_DNS by
    # design (manual P0-T3 STEP 7 contract: no-busybox verify = toybox nc +
    # liveness check) - it reports verify_dns degraded/fail in P0-T4 and must
    # be accepted as a documented boundary, not "fixed" here.
    if ! toybox nc -z 127.0.0.1 "$AGH_DNS_PORT" 2>/dev/null || ! _agh_alive; then
      aghf_log ERROR P0-T3 "verify-dns failed (degraded, no busybox)"
      _rollback_steps "$NETID"
      exit 21
    fi
    _VBRANCH="degraded_nc"
  fi

  # 6. VERIFY_BLOCK (non-blocking)
  if [ "$AGHF_BUSYBOX" != "none" ] && [ -x "$AGHF_BUSYBOX" ]; then
    _bout="$("$AGHF_BUSYBOX" nslookup doubleclick.net 127.0.0.1 2>/dev/null)"
    if echo "$_bout" | grep -qE '0\.0\.0\.0|NXDOMAIN'; then
      echo "OK" > "$AGHF_STATE/verify_block.txt"
    else
      aghf_log WARN P0-T3 "verify-block: doubleclick.net not blocked yet (filter not synced)"
      echo "DELAYED" > "$AGHF_STATE/verify_block.txt"
    fi
    _BRESULT="checked"
  else
    aghf_log WARN P0-T3 "verify-block skipped: no busybox available"
    echo "skipped_no_busybox" > "$AGHF_STATE/verify_block.txt"
    _BRESULT="skipped"
  fi

  _ctl_write RUNNING "$NETID"
  echo "$_VBRANCH" >> "$AGHF_STATE/verify_block.txt"
  aghf_log INFO P0-T3 "install: done netid=$NETID dnsresolver=${_DNSRESOLVER:-ok} verify=$_VBRANCH block=$_BRESULT"
  exit 0
}

_ghfctl_rollback() {
  aghf_log INFO P0-T3 "rollback: begin"
  _NETID=""
  [ -f "$CTL_STATE" ] && _NETID="$(grep -oE '"netid":[0-9]+' "$CTL_STATE" | grep -oE '[0-9]+')"
  if [ -z "$_NETID" ]; then
    _NETID="$(active_netid)"
  fi
  if [ -n "$_NETID" ]; then
    SNAPFILE="$(_snapshot_file "$_NETID")"
  fi
  if ! _rollback_steps "${_NETID:-}"; then
    aghf_log ERROR P0-T3 "rollback: step error"
    _ctl_write ROLLBACK "${_NETID:-0}"
    exit 60
  fi
  _ctl_write IDLE
  aghf_log INFO P0-T3 "rollback: done"
  exit 0
}

_ghfctl_status() {
  echo "ctl.json: $(cat "$CTL_STATE" 2>/dev/null || echo none)"
  if _agh_alive; then echo "AGH: running"; else echo "AGH: not running"; fi
  ipt_verify && echo "iptables: AGHF chains present" || echo "iptables: AGHF chains absent"
  [ -f "$AGHF_STATE/verify_block.txt" ] && echo "verify_block: $(cat "$AGHF_STATE/verify_block.txt")"
  exit 0
}

if [ "${AGHFCTL_LIB:-0}" != "1" ]; then
  case "$1" in
    install)  _ghfctl_install ;;
    rollback) _ghfctl_rollback ;;
    status)   _ghfctl_status ;;
    *)
      echo "usage: aghfctl.sh install|rollback|status" >&2
      exit 1
      ;;
  esac
fi
