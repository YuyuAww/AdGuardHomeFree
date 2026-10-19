#!/system/bin/sh
# AdGuardHomeFree common/iptables.sh (P0-T3)
# Only AGH-owned nat rules: AGHF_OUTPUT / AGHF_PREROUTING chains.
# Never touches system-owned rules (INV: minimal footprint).
# Requires rootenv.sh vars: AGHF_IPTABLES, AGH_DNS_PORT.

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
  local _rc=0
  for _p in udp tcp; do
    _ipt -t nat -C AGHF_OUTPUT -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT" \
      && _ipt -t nat -D AGHF_OUTPUT -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT"
    _ipt -t nat -C AGHF_PREROUTING -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT" \
      && _ipt -t nat -D AGHF_PREROUTING -p "$_p" --dport 53 -j REDIRECT --to-ports "$AGH_DNS_PORT"
  done
  _ipt -t nat -C OUTPUT -j AGHF_OUTPUT && _ipt -t nat -D OUTPUT -j AGHF_OUTPUT
  _ipt -t nat -C PREROUTING -j AGHF_PREROUTING && _ipt -t nat -D PREROUTING -j AGHF_PREROUTING
  # Chains are ours: flush + delete. System rules untouched.
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
