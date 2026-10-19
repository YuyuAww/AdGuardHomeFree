#!/system/bin/sh
# AdGuardHomeFree customize.sh (P0-T1)
# Runs in the manager (KernelSU/APatch) install context as root.
# INV-06: never start AGH / install iptables here.
# INV-05: no hardcoded module root; MODDIR derived from $0.

MODDIR="${0%/*}"
[ -z "$MODDIR" ] && MODDIR="${MODPATH:-/data/adb/modules/AdGuardHomeFree}"

# ui_print is provided by the KSU/APatch install context; fall back to echo.
ui_print() {
  command -v ui_print >/dev/null 2>&1 && ui_print "$*" && return
  echo "$*" >&2
}

AGHF_DATA="/data/adb/aghf"
DATA_DIR="$AGHF_DATA/data"
LOGS_DIR="$AGHF_DATA/logs"
RUN_DIR="$AGHF_DATA/run"
STATE_DIR="$AGHF_DATA/state"

ui_print "- AdGuardHomeFree: preparing data dirs"
mkdir -p "$DATA_DIR" "$LOGS_DIR" "$RUN_DIR" "$STATE_DIR"
chmod 700 "$AGHF_DATA" "$DATA_DIR" "$LOGS_DIR" "$RUN_DIR" "$STATE_DIR" 2>/dev/null
chown root:root "$AGHF_DATA" 2>/dev/null

YAML="$DATA_DIR/AdGuardHome.yaml"
CRED="$STATE_DIR/agh_admin.cred"

if [ -f "$YAML" ]; then
  # Upgrade path: manager replaced the code dir; user data must survive.
  ui_print "- INFO preserved user data"
  echo "INFO preserved user data" >> "$LOGS_DIR/aghf.log"
else
  ui_print "- AdGuardHomeFree: first install, generating config"
  cp -f "$MODDIR/config/AdGuardHome.yaml.template" "$YAML" || {
    ui_print "- AdGuardHomeFree: FATAL: config template copy failed"
    exit 1
  }

  # 32-hex-char random admin password (16 bytes from /dev/urandom)
  PASS="$(head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  HASH="$("$MODDIR/bin/aghbridge" gen-hash "$PASS" 2>/dev/null)"
  case "$HASH" in
    \$2a\$*) : ;;
    *)
      ui_print "- AdGuardHomeFree: FATAL: aghbridge gen-hash failed"
      echo "ERROR gen-hash failed" >> "$LOGS_DIR/aghf.log"
      exit 1
      ;;
  esac
  sed -i "s|__AGHF_ADMIN_HASH__|$HASH|" "$YAML"
  if grep -q "__AGHF_ADMIN_HASH__" "$YAML"; then
    ui_print "- AdGuardHomeFree: FATAL: hash substitution failed"
    exit 1
  fi

  # Store admin credential (user:pass) for internal use only. Never echo it.
  printf 'admin:%s\n' "$PASS" > "$CRED"
  chmod 600 "$CRED"

  # Tell the operator where the password lives; do not print it here in logs.
  ui_print "- AdGuardHomeFree: admin password generated (see $CRED, root only)"
fi

chmod 640 "$YAML" 2>/dev/null
ui_print "- AdGuardHomeFree: customize done"
