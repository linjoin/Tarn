#!/system/bin/sh

detect_bb() {
  for cand in \
    /data/adb/ksu/bin/busybox \
    /data/adb/ap/bin/busybox \
    /data/adb/magisk/busybox \
    /system/bin/busybox \
    /system/xbin/busybox; do
    [ -x "$cand" ] && { echo "$cand"; return 0; }
  done
  command -v busybox 2>/dev/null && return 0
  echo ""
  return 1
}

BB=$(detect_bb)
bb_wrap() {
  cmd=$1
  shift
  if [ -n "$BB" ]; then
    "$BB" "$cmd" "$@"
  else
    "$cmd" "$@"
  fi
}

DATADIR=/data/adb/tarn
PIDFILE="$DATADIR/run/tarn.pid"

if [ -f "$PIDFILE" ]; then
  DAEMON_PID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$DAEMON_PID" ] && [ "$DAEMON_PID" -gt 0 ] 2>/dev/null; then
    if kill -0 "$DAEMON_PID" 2>/dev/null; then
      OLD_CMDLINE=""
      if [ -r "/proc/$DAEMON_PID/cmdline" ]; then
        OLD_CMDLINE=$(tr '\0' ' ' < "/proc/$DAEMON_PID/cmdline" 2>/dev/null)
      fi
      case "$OLD_CMDLINE" in
        *tarn*)
          kill -TERM "$DAEMON_PID" 2>/dev/null
          i=0
          while [ $i -lt 10 ]; do
            kill -0 "$DAEMON_PID" 2>/dev/null || break
            sleep 1
            i=$((i + 1))
          done
          kill -0 "$DAEMON_PID" 2>/dev/null && kill -KILL "$DAEMON_PID" 2>/dev/null
          ;;
      esac
    fi
  fi
fi

if [ -n "$BB" ]; then
  "$BB" ps 2>/dev/null | bb_wrap grep -E '[t]arn daemon' | while read -r p c; do
    kill -KILL "$p" 2>/dev/null
  done
else
  ps -A -o pid,cmd 2>/dev/null | bb_wrap grep -E '[t]arn daemon' | while read -r p c; do
    kill -KILL "$p" 2>/dev/null
  done
fi

if [ -d "$DATADIR" ]; then
  rm -rf "$DATADIR" 2>/dev/null
  [ -d "$DATADIR" ] && rm -rf "$DATADIR" 2>/dev/null
fi

command -v pm >/dev/null 2>&1 && pm uninstall me.weishu.kernelsu.webui >/dev/null 2>&1

exit 0
