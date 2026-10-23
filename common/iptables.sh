#!/system/bin/sh
# AdGuardHomeFree common/iptables.sh (P0-T3)
# Only AGH-owned nat rules: AGHF_OUTPUT / AGHF_PREROUTING chains.
# Never touches system-owned rules (INV: minimal footprint).
# Requires rootenv.sh vars: AGHF_IPTABLES, AGH_DNS_PORT.
#
# ipt_install is idempotent (-C probe, -A only when absent).
# ipt_remove is its exact inverse: absent rules are a no-op, a deletion that
# was present but FAILED sets the rc (aghfctl rollback surfaces it, exit 60 /
# manual §1.4).

_ipt() {
  "$AGHF_IPTABLES" -w 2 "$@"
}

ipt_install() {
  # Create chains (idempotent)
  _ipt -t nat -N AGHF_OUTPUT 2>/dev/null
  _ipt -t nat -N AGHF_PREROUTING 2>/dev/null

  # Insert jumps once
  _ipt -t nat -C OUTPUT -j AGHF_OUTPUT || _ipt -t nat -A OUTPUT -j AGHF_OUTPUT
  _ipt -t nat -C PREROUTING -j AGHF_PREROUTING || _ipt -t nat -A PREROUTING -j AGHF_PREROUTING

  # Redirect DNS (53/udp+tcp) to AGH local port
  for _p in udp tcp; do
    _ipt -t nat -C AGHF_OUTPUT -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT" \
      || _ipt -t nat -A AGHF_OUTPUT -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT"
    _ipt -t nat -C AGHF_PREROUTING -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT" \
      || _ipt -t nat -A AGHF_PREROUTING -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT"
  done
  return $?
}

ipt_remove() {
  # rc contract: _rc=0 unless a rule that WAS present failed to delete.
  # Absent rules (clean device / already rolled back) stay rc=0.
  local _rc=0
  for _p in udp tcp; do
    _ipt -t nat -C AGHF_OUTPUT -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT" 2>/dev/null \
      && { _ipt -t nat -D AGHF_OUTPUT -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT" || _rc=1; }
    _ipt -t nat -C AGHF_PREROUTING -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT" 2>/dev/null \
      && { _ipt -t nat -D AGHF_PREROUTING -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT" || _rc=1; }
  done
  _ipt -t nat -C OUTPUT -j AGHF_OUTPUT 2>/dev/null \
    && { _ipt -t nat -D OUTPUT -j AGHF_OUTPUT || _rc=1; }
  _ipt -t nat -C PREROUTING -j AGHF_PREROUTING 2>/dev/null \
    && { _ipt -t nat -D PREROUTING -j AGHF_PREROUTING || _rc=1; }
  # Chains are ours: flush + delete. Already-gone chains are a soft no-op.
  _ipt -t nat -F AGHF_OUTPUT 2>/dev/null
  _ipt -t nat -F AGHF_PREROUTING 2>/dev/null
  _ipt -t nat -X AGHF_OUTPUT 2>/dev/null
  _ipt -t nat -X AGHF_PREROUTING 2>/dev/null
  return $_rc
}

ipt_verify() {
  _ipt -t nat -C AGHF_OUTPUT -p udp --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT" \
    && _ipt -t nat -C AGHF_PREROUTING -p tcp --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT"
}
