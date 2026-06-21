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

MODDIR=${0%/*}
DATADIR=/data/adb/tarn
BIN="$MODDIR/tarn"
DEBUG_SH="$MODDIR/debug.sh"
PIDFILE="$DATADIR/run/tarn.pid"
LOGDIR="$DATADIR/logs"
BOOTLOG="$LOGDIR/boot.log"
RUNLOG="$LOGDIR/tarn.log"
SETTINGS_FILE="$DATADIR/config/settings.toml"

LOG_KEEP=3
if [ -f "$SETTINGS_FILE" ]; then
  _v=$(bb_wrap grep -E '^[[:space:]]*keep_files[[:space:]]*=' "$SETTINGS_FILE" 2>/dev/null | head -n 1 | bb_wrap sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' | tr -d '[:space:]')
  [ -n "$_v" ] && LOG_KEEP=$_v
fi
unset _v

rotate_log_file() {
  _p=$1
  [ -n "$_p" ] || return 0
  [ "$LOG_KEEP" -gt 0 ] 2>/dev/null || return 0
  _i=$((LOG_KEEP + 1))
  while [ $_i -ge 1 ]; do
    rm -f "${_p}.${_i}" 2>/dev/null
    _i=$((_i - 1))
  done
  _i=$((LOG_KEEP - 1))
  while [ $_i -ge 1 ]; do
    [ -f "${_p}.${_i}" ] && mv -f "${_p}.${_i}" "${_p}.$((_i + 1))" 2>/dev/null
    _i=$((_i - 1))
  done
  [ -f "$_p" ] && mv -f "$_p" "${_p}.1" 2>/dev/null
}

log_boot() {
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] $1" >> "$BOOTLOG" 2>/dev/null
}

if [ ! -x "$BIN" ]; then
  log_boot "错误: 程序文件不存在或不可执行: $BIN"
  exit 1
fi

mkdir -p "$DATADIR/config" "$DATADIR/logs" "$DATADIR/run" "$DATADIR/rules" "$DATADIR/trash" 2>/dev/null
chmod 700 "$DATADIR" "$DATADIR/config" "$DATADIR/logs" "$DATADIR/run" "$DATADIR/rules" "$DATADIR/trash" 2>/dev/null
chown root:root "$DATADIR" 2>/dev/null

if [ "$LOG_KEEP" -gt 0 ] 2>/dev/null; then
  for _lf in "$BOOTLOG" "$RUNLOG"; do
    [ -f "$_lf" ] || continue
    _sz=$(wc -c < "$_lf" 2>/dev/null | tr -d '[:space:]')
    [ -n "$_sz" ] && [ "$_sz" -gt 0 ] 2>/dev/null || continue
    rotate_log_file "$_lf"
  done
  unset _lf _sz
fi
[ "$LOG_KEEP" -gt 0 ] 2>/dev/null && log_boot "已备份上一轮日志 (保留 ${LOG_KEEP} 份, 下次开机再轮转)"

for stale in "$DATADIR/token" "$DATADIR/tarn.sock"; do
  if [ -e "$stale" ]; then
    rm -f "$stale" 2>/dev/null
    log_boot "清理残留文件: $(basename "$stale")"
  fi
done

log_boot "================================================"
log_boot "Tarn 启动中"
log_boot "模块目录: $MODDIR"
log_boot "数据目录: $DATADIR"
log_boot "================================================"

if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$OLD_PID" ] && [ "$OLD_PID" -gt 0 ] 2>/dev/null; then
    if kill -0 "$OLD_PID" 2>/dev/null; then
      OLD_CMDLINE=""
      if [ -r "/proc/$OLD_PID/cmdline" ]; then
        OLD_CMDLINE=$(tr '\0' ' ' < "/proc/$OLD_PID/cmdline" 2>/dev/null)
      fi
      case "$OLD_CMDLINE" in
        *tarn*)
          log_boot "检测到旧实例 (pid=$OLD_PID), 正在停止..."
          kill -TERM "$OLD_PID" 2>/dev/null
          i=0
          while [ $i -lt 12 ]; do
            if ! kill -0 "$OLD_PID" 2>/dev/null; then
              log_boot "旧实例已退出"
              break
            fi
            sleep 1
            i=$((i + 1))
          done
          if kill -0 "$OLD_PID" 2>/dev/null; then
            log_boot "旧实例未响应, 强制结束"
            kill -KILL "$OLD_PID" 2>/dev/null
            sleep 1
          fi
          ;;
        *)
          log_boot "进程 pid=$OLD_PID 不匹配, 清理记录文件"
          rm -f "$PIDFILE"
          ;;
      esac
    else
      log_boot "旧进程已不存在, 清理记录文件"
      rm -f "$PIDFILE"
    fi
  else
    rm -f "$PIDFILE"
  fi
fi

MODULE_PROP="$MODDIR/module.prop"
STATE_FILE="$DATADIR/state.json"
if [ -f "$STATE_FILE" ] && [ -f "$MODULE_PROP" ]; then
  TOTAL_FREED=$(bb_wrap grep -E '"total_freed_bytes"[[:space:]]*:' "$STATE_FILE" 2>/dev/null | head -n 1 | bb_wrap sed -E 's/.*:[[:space:]]*([0-9]+).*/\1/' | tr -d '[:space:]')
  TOTAL_FILES=$(bb_wrap grep -E '"total_files_deleted"[[:space:]]*:' "$STATE_FILE" 2>/dev/null | head -n 1 | bb_wrap sed -E 's/.*:[[:space:]]*([0-9]+).*/\1/' | tr -d '[:space:]')
  [ -z "$TOTAL_FILES" ] && TOTAL_FILES=0
  if [ -n "$TOTAL_FREED" ]; then
    case "$TOTAL_FREED" in
      *[!0-9]*)
        log_boot "统计数据异常, 跳过恢复"
        ;;
      *)
        CLEANED_STR=""
        GB=$((1024 * 1024 * 1024))
        MB=$((1024 * 1024))
        KB=1024
        if [ "$TOTAL_FREED" -ge "$GB" ] 2>/dev/null; then
          if command -v awk >/dev/null 2>&1; then
            CLEANED_STR=$(awk -v b="$TOTAL_FREED" -v g="$GB" 'BEGIN{printf "%.2f GB", b/g}')
          else
            CLEANED_STR="$((TOTAL_FREED / GB)) GB"
          fi
        elif [ "$TOTAL_FREED" -ge "$MB" ] 2>/dev/null; then
          if command -v awk >/dev/null 2>&1; then
            CLEANED_STR=$(awk -v b="$TOTAL_FREED" -v m="$MB" 'BEGIN{printf "%.2f MB", b/m}')
          else
            CLEANED_STR="$((TOTAL_FREED / MB)) MB"
          fi
        elif [ "$TOTAL_FREED" -ge "$KB" ] 2>/dev/null; then
          if command -v awk >/dev/null 2>&1; then
            CLEANED_STR=$(awk -v b="$TOTAL_FREED" -v k="$KB" 'BEGIN{printf "%.2f KB", b/k}')
          else
            CLEANED_STR="$((TOTAL_FREED / KB)) KB"
          fi
        else
          CLEANED_STR="${TOTAL_FREED} B"
        fi
        bb_wrap sed -i -E "s|^description=.*|description=已停止 \| 删除 ${TOTAL_FILES} 个文件 \| 已清理 ${CLEANED_STR}|" "$MODULE_PROP" 2>/dev/null
        log_boot "已恢复累计统计: 删除 ${TOTAL_FILES} 文件 / 已清理 ${CLEANED_STR}"
        ;;
    esac
  fi
fi

BOOT_FAIL_FILE="$DATADIR/run/boot_failures"
BOOT_FAIL_COUNT=0
if [ -f "$BOOT_FAIL_FILE" ]; then
  BOOT_FAIL_COUNT=$(cat "$BOOT_FAIL_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$BOOT_FAIL_COUNT" in
    *[!0-9]*|"") BOOT_FAIL_COUNT=0 ;;
  esac
fi
if [ "$BOOT_FAIL_COUNT" -ge 3 ] 2>/dev/null; then
  log_boot "================================================"
  log_boot "⚠ 安全模式: daemon 已连续 $BOOT_FAIL_COUNT 次启动失败, 跳过自启"
  log_boot "  可能原因: 配置文件语法错 / 二进制不兼容 / 依赖缺失"
  log_boot "  诊断步骤:"
  log_boot "    1. 手动运行: $BIN doctor"
  log_boot "    2. 手动运行: $BIN daemon  (前台看报错)"
  log_boot "    3. 查看运行日志: $RUNLOG"
  log_boot "    4. 手动诊断: sh $DEBUG_SH"
  log_boot "  修复后恢复正常自启: rm -f $BOOT_FAIL_FILE"
  log_boot "================================================"
  if [ -x "$DEBUG_SH" ] || [ -f "$DEBUG_SH" ]; then
    sh "$DEBUG_SH" >/dev/null 2>&1 &
  fi
  "$BIN" notify-error --force --title "Tarn 安全模式" --msg "daemon 已连续 ${BOOT_FAIL_COUNT} 次启动失败, 已跳过自启, 请查看日志并运行 doctor" >/dev/null 2>&1 &
  exit 0
fi

SETS_PID=""
if command -v setsid >/dev/null 2>&1; then
  SETSID_CMD="setsid"
elif [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -q '^setsid$'; then
  SETSID_CMD="$BB setsid"
else
  SETSID_CMD=""
fi

if [ -n "$SETSID_CMD" ]; then
  log_boot "启动后台服务..."
  $SETSID_CMD nohup "$BIN" daemon </dev/null >>"$RUNLOG" 2>&1 &
else
  log_boot "警告: setsid 不可用, 降级启动"
  nohup "$BIN" daemon </dev/null >>"$RUNLOG" 2>&1 &
fi
DAEMON_BG_PID=$!

DAEMON_READY=0
i=0
while [ $i -lt 5 ]; do
  if [ -f "$PIDFILE" ]; then
    DAEMON_PID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$DAEMON_PID" ] && [ "$DAEMON_PID" -gt 0 ] 2>/dev/null; then
      if kill -0 "$DAEMON_PID" 2>/dev/null; then
        log_boot "✓ 服务已启动 (pid=$DAEMON_PID)"
        log_boot "运行日志: $RUNLOG"
        log_boot "================================================"
        DAEMON_READY=1
        break
      else
        log_boot "警告: 服务启动后立即退出"
        break
      fi
    fi
  fi
  sleep 1
  i=$((i + 1))
done

if [ "$DAEMON_READY" = "1" ]; then
  if [ "$BOOT_FAIL_COUNT" -gt 0 ] 2>/dev/null; then
    echo "0" > "$BOOT_FAIL_FILE" 2>/dev/null
  fi
  exit 0
fi

BOOT_FAIL_NEW=$((BOOT_FAIL_COUNT + 1))
echo "$BOOT_FAIL_NEW" > "$BOOT_FAIL_FILE" 2>/dev/null
log_boot "错误: 服务启动失败 (连续第 $BOOT_FAIL_NEW 次)"
log_boot "请查看运行日志: $RUNLOG"
log_boot "诊断命令: $BIN doctor  或  $BIN daemon (前台运行看报错)"
log_boot "诊断脚本: sh $DEBUG_SH"
if [ "$BOOT_FAIL_NEW" -ge 3 ] 2>/dev/null; then
  log_boot "⚠ 下次开机将进入安全模式跳过自启, 避免阻塞系统启动"
  log_boot "  修复后恢复: rm -f $BOOT_FAIL_FILE"
fi
log_boot "================================================"

if [ -f "$DEBUG_SH" ]; then
  sh "$DEBUG_SH" >/dev/null 2>&1 &
fi
"$BIN" notify-error --force --title "Tarn 启动失败" --msg "daemon 连续第 ${BOOT_FAIL_NEW} 次启动失败, 已收集诊断快照, 请查看 ${RUNLOG} 并运行 doctor" >/dev/null 2>&1 &

exit 1
