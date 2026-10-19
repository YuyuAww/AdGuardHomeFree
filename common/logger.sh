#!/system/bin/sh
# AdGuardHomeFree common/logger.sh (P0-T1)
# Log format per manual §1.3: [ISO8601] [LEVEL] [AGHF] [TASK_ID] msg
# Destination: $AGHF_LOGS/aghf.log, roll to aghf.log.1 above 1MiB.
# This file must be sourceable before rootenv succeeds, so it falls back to
# the fixed §1.1 data path when AGHF_LOGS is not yet exported.

AGHF_LOGS="${AGHF_LOGS:-/data/adb/aghf/logs}"

aghf_log() {
  # aghf_log LEVEL TASK_ID MESSAGE...
  _lvl="$1"; _task="$2"; shift 2
  _msg="$*"
  _ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _line="$_ts [$_lvl] [AGHF] [$_task] $_msg"
  mkdir -p "$AGHF_LOGS" 2>/dev/null
  echo "$_line" >> "$AGHF_LOGS/aghf.log"
  echo "$_line" >&2
  # 1MiB rotation
  _size=$(stat -c %s "$AGHF_LOGS/aghf.log" 2>/dev/null || echo 0)
  if [ "${_size:-0}" -gt 1048576 ]; then
    mv -f "$AGHF_LOGS/aghf.log" "$AGHF_LOGS/aghf.log.1" 2>/dev/null
  fi
}
