#!/system/bin/sh
# AdGuardHomeFree common/dnsresolver.sh (P0-T3)
# Per-network DNS resolver takeover via netd. INV-09: always snapshot before
# modifying; every function is idempotent.

# netd command surface status (verified 2026-10 against AOSP O/P
# CommandListener.cpp, AOSP Q+/A11/A12/A14 NdcDispatcher.cpp, and community
# reports - see manual P0-T3 / P0-T4):
#   - `cmd netd resolver setnetdns <netid> <domains> <dns...>` is the O/P-era
#     form (domains slot required, may be the empty string); `clearnetdns
#     <netid>` clears the resolver.
#   - On Android 10+ the netd NDC "resolver" command family was REMOVED
#     (resolver moved to a separate "dnsresolver" binder service that shell
#     `cmd`/`ndc` cannot reach); every resolver command then answers
#     "Command not recognized".
#   - "getnetdns" never existed as an NDC command in any AOSP version;
#     read-back is the DnsAddresses line of `dumpsys connectivity`
#     (best effort, format drift allowed).
# Consequence on realistic KSU/APatch targets (A11+): dnsresolver_set fails,
# aghfctl.sh therefore runs degraded iptables-only mode (writes the
# $AGHF_STATE/dnsresolver_mode marker, P0-T3 rescope); per-netId binder
# takeover is P1-T1.

getnetdns() {
  # print the currently configured DNS servers for network $1
  # Best-effort read-back via dumpsys connectivity: the netd NDC command
  # "getnetdns" does not exist in any AOSP version. Prints the DnsAddresses
  # line of the [netid] block when present; empty on format drift (blind
  # snapshot; dnsresolver_restore then no-ops honestly).
  dumpsys connectivity 2>/dev/null | awk -v n="$1" '
    $0 ~ ("^[ \t]*\\[" n "\\]") && ($0 ~ /type:/ || $0 ~ /Active Network/) { inblk = 1 }
    inblk && $0 ~ /DnsAddresses/ { print; exit }
  ' 2>/dev/null
}

active_netid() {
  # active network id from dumpsys connectivity
  dumpsys connectivity 2>/dev/null | grep -m1 'Active Network' | grep -oE '[0-9]+' | head -n1
}

_dns_servers_list() {
  # extract IPv4/IPv6 literals, dedup
  getnetdns "$1" | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{1,4}:){1,7}[0-9a-fA-F]{1,4}' | sort -u
}

dnsresolver_snapshot() {
  # $1 = netid; write $AGHF_STATE/dns_snapshot_<netid>.json
  _n="$1"
  _f="$AGHF_STATE/dns_snapshot_${_n}.json"
  _servers=""
  for _s in $(_dns_servers_list "$_n"); do
    [ -n "$_servers" ] && _servers="${_servers}, "
    _servers="${_servers}\"${_s}\""
  done
  _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"netid":%s,"servers":[%s],"captured":"%s"}\n' "$_n" "$_servers" "$_ts" > "$_f"
  return 0
}

_dns_servers_from_snapshot() {
  # $1 = netid; echo whitespace-separated server list (may be empty)
  # Scan ONLY the "servers" array, not the whole file: a whole-file grep of
  # quoted hex-like tokens also picks up separator tokens such as ":" (the
  # quoted colon between key and value, e.g. "captured":"...") and would
  # poison dnsresolver_restore with a bogus server entry.
  _f="$AGHF_STATE/dns_snapshot_${1}.json"
  [ -f "$_f" ] || return 1
  sed -n 's/.*"servers":\[\([^]]*\)\].*/\1/p' "$_f" | grep -oE '"[^"]+"' | tr -d '"'
}

dnsresolver_set() {
  # $1 = netid, $2 = server (P0: always 127.0.0.1); $2 may be repeated
  # O/P-era netd surface (see file header); expected to fail on A10+.
  cmd netd resolver setnetdns "$1" "" "$2"
}

dnsresolver_restore() {
  # $1 = netid; restore from snapshot; empty snapshot = clear to system default
  _n="$1"
  _servers="$(_dns_servers_from_snapshot "$_n")" || {
    aghf_log WARN P0-T3 "restore: no snapshot for netid $_n, leaving resolver as-is"
    return 1
  }
  if [ -n "$_servers" ]; then
    cmd netd resolver setnetdns "$_n" "" $_servers
  else
    # empty snapshot: nothing was captured (read-back surface unavailable or
    # no servers configured). If our override could still be in effect
    # (O/P-era ROM), clearnetdns is the correct primitive; on A10+ it is
    # unrecognized too - soft-fail with WARN instead of a bogus
    # under-arg setnetdns call (argc 4 < 5, which O/P would reject).
    if ! cmd netd resolver clearnetdns "$_n" 2>/dev/null; then
      aghf_log WARN P0-T3 "restore: clearnetdns unavailable for netid $_n, leaving resolver as-is"
      return 0
    fi
  fi
}
