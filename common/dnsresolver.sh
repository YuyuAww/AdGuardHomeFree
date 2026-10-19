#!/system/bin/sh
# AdGuardHomeFree common/dnsresolver.sh (P0-T3)
# Per-network DNS resolver takeover via netd. INV-09: always snapshot before
# modifying; every function is idempotent.

# NOTE: netd command surface (getnetdns / resolver setnetdns) is device-facing
# and still unverified on a real device; see P0-T4 report fields.

getnetdns() {
  # print the currently configured DNS servers for network $1
  cmd netd getnetdns "$1" 2>/dev/null
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
  _f="$AGHF_STATE/dns_snapshot_${1}.json"
  [ -f "$_f" ] || return 1
  grep -oE '"[0-9a-fA-F:.]+"' "$_f" | tr -d '"' | tr '\n' ' '
}

dnsresolver_set() {
  # $1 = netid, $2 = server (P0: always 127.0.0.1)
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
    # empty snapshot: clear our override, fall back to system-resolved DNS
    cmd netd resolver setnetdns "$_n" ""
  fi
}
