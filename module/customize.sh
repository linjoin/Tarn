#!/system/bin/sh

SKIPUNZIP=1

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

ui_print() {
  if [ "$BOOTMODE" = "true" ] || [ -z "$OUTFD" ]; then
    echo "$1"
  else
    printf 'ui_print %s\nui_print\n' "$1" >> /proc/self/fd/$OUTFD
  fi
}

abort() {
  ui_print "✗ 安装失败: $1"
  exit 1
}

# 迁移 settings.toml: 检测模块新增配置项 (忽略注释, 逐 key 对比),
# 直接合并 (追加到对应 section 末尾), ui_print 告知用户有哪些新项已合并。
# 用户原有配置原样保留, 仅追加新项; 合并是 section 感知的, 不破坏 toml 结构。
migrate_settings() {
  _ms_user="$DATADIR/config/settings.toml"
  _ms_mod="$MODPATH/config/settings.toml"
  [ -f "$_ms_user" ] || return 0
  [ -f "$_ms_mod" ] || return 0

  _ms_mkk=$(mktemp 2>/dev/null) || _ms_mkk=/tmp/_ms_mkk.$$
  _ms_ukk=$(mktemp 2>/dev/null) || _ms_ukk=/tmp/_ms_ukk.$$
  _ms_nk=$(mktemp 2>/dev/null) || _ms_nk=/tmp/_ms_nk.$$

  # awk 脚本: 提取 toml key (忽略注释/空行/section行), 记录所属 section
  # 输出格式: section|key \t 原始行   (模块)
  #           section|key              (用户, 只 key)
  _ms_awk_full='
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      gsub(/\r/, "", line)
    }
    length(line) == 0 { next }
    substr(line, 1, 1) == "#" { next }
    substr(line, 1, 1) == "[" {
      sec = line
      sub(/^\[/, "", sec)
      sub(/\].*$/, "", sec)
      current = sec
      next
    }
    {
      idx = index(line, "=")
      if (idx == 0) next
      key = substr(line, 1, idx - 1)
      sub(/[[:space:]]+$/, "", key)
      sub(/^[[:space:]]+/, "", key)
      if (length(key) == 0) next
      printf "%s|%s\t%s\n", current, key, $0
    }
  '
  _ms_awk_key='
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      gsub(/\r/, "", line)
    }
    length(line) == 0 { next }
    substr(line, 1, 1) == "#" { next }
    substr(line, 1, 1) == "[" {
      sec = line
      sub(/^\[/, "", sec)
      sub(/\].*$/, "", sec)
      current = sec
      next
    }
    {
      idx = index(line, "=")
      if (idx == 0) next
      key = substr(line, 1, idx - 1)
      sub(/[[:space:]]+$/, "", key)
      sub(/^[[:space:]]+/, "", key)
      if (length(key) == 0) next
      printf "%s|%s\n", current, key
    }
  '
  bb_wrap awk "$_ms_awk_full" "$_ms_mod" > "$_ms_mkk"
  bb_wrap awk "$_ms_awk_key" "$_ms_user" > "$_ms_ukk"

  # 找新增项: 模块有但用户没有的 section|key
  bb_wrap awk -v USERF="$_ms_ukk" '
    BEGIN {
      while ((getline ul < USERF) > 0) have[ul] = 1
      close(USERF)
    }
    {
      tab = index($0, "\t")
      if (tab == 0) next
      sk = substr($0, 1, tab - 1)
      if (!(sk in have)) print $0
    }
  ' "$_ms_mkk" > "$_ms_nk"

  _ms_cnt=0
  if [ -s "$_ms_nk" ]; then
    _ms_cnt=$(wc -l < "$_ms_nk" | tr -d ' ')
  fi

  if [ "$_ms_cnt" -eq 0 ]; then
    ui_print "✓ 配置项无新增, 保留您的 settings.toml"
    rm -f "$_ms_mkk" "$_ms_ukk" "$_ms_nk"
    return 0
  fi

  ui_print ""
  ui_print "检测到 ${_ms_cnt} 个新增配置项, 已自动合并到您的 settings.toml:"
  while IFS= read -r _ms_line; do
    [ -n "$_ms_line" ] || continue
    _ms_sk=$(printf '%s' "$_ms_line" | cut -f1)
    _ms_orig=$(printf '%s' "$_ms_line" | cut -f2-)
    _ms_disp=$(printf '%s' "$_ms_sk" | tr '|' '.')
    _ms_val=$(printf '%s' "$_ms_orig" | sed -E 's/^[^=]+=//; s/^[[:space:]]+//; s/[[:space:]]+#.*$//')
    ui_print "  • ${_ms_disp} = ${_ms_val}"
  done < "$_ms_nk"
  ui_print "(您原有的配置保持不变, 仅追加以上新项)"

  _ms_out=$(mktemp 2>/dev/null) || _ms_out=/tmp/_ms_out.$$
  # awk 重写用户文件: 在对应 section 末尾插入新增项 (section 感知, 不破坏 toml 结构)
  bb_wrap awk -v INSERT="$_ms_nk" '
    BEGIN {
      while ((getline il < INSERT) > 0) {
        tab = index(il, "\t")
        if (tab == 0) continue
        sk = substr(il, 1, tab - 1)
        rest = substr(il, tab + 1)
        pipe = index(sk, "|")
        if (pipe == 0) continue
        sec = substr(sk, 1, pipe - 1)
        ins[sec, ++inscnt[sec]] = rest
        seclist[sec] = 1
      }
      close(INSERT)
      current = ""
    }
    {
      tline = $0
      sub(/^[[:space:]]+/, "", tline)
      gsub(/\r/, "", tline)
      if (substr(tline, 1, 1) == "[") {
        if (current != "" && inscnt[current] > 0) {
          for (i = 1; i <= inscnt[current]; i++) print ins[current, i]
          inscnt[current] = 0
        }
        sec = tline
        sub(/^\[/, "", sec)
        sub(/\].*$/, "", sec)
        current = sec
        print $0
      } else {
        print $0
      }
    }
    END {
      if (current != "" && inscnt[current] > 0) {
        for (i = 1; i <= inscnt[current]; i++) print ins[current, i]
        inscnt[current] = 0
      }
      for (k in seclist) {
        if (inscnt[k] > 0) {
          print ""
          print "[" k "]"
          for (i = 1; i <= inscnt[k]; i++) print ins[k, i]
          inscnt[k] = 0
        }
      }
    }
  ' "$_ms_user" > "$_ms_out"

  if [ -s "$_ms_out" ]; then
    cp -p "$_ms_out" "$_ms_user"
    chmod 600 "$_ms_user"
    ui_print "✓ 已合并 ${_ms_cnt} 个新增配置项"
  else
    ui_print "! 合并失败, 保留原配置"
  fi

  rm -f "$_ms_mkk" "$_ms_ukk" "$_ms_nk" "$_ms_out"
}

MODVER="$(sed -n 's/^version=//p' "$MODPATH/module.prop" 2>/dev/null)"
[ -z "$MODVER" ] && MODVER="$(sed -n 's/^version=//p' "${0%/*}/module.prop" 2>/dev/null)"
[ -z "$MODVER" ] && MODVER="unknown"
[ -z "$ARCH" ] && ARCH=$(uname -m 2>/dev/null || bb_wrap uname -m 2>/dev/null)

ui_print "Tarn ${MODVER}"
ui_print "${ARCH} / API ${API}"
ui_print ""

DATADIR=/data/adb/tarn
PIDFILE="$DATADIR/run/tarn.pid"
SOCKET_FILE="$DATADIR/run/tarn.sock"

stop_process() {
  _pid=$1
  [ -n "$_pid" ] || return 1
  _cmdline=""
  if [ -r "/proc/$_pid/cmdline" ]; then
    _cmdline=$(tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null)
  fi
  case "$_cmdline" in
    *tarn*)
      kill -TERM "$_pid" 2>/dev/null
      _i=0
      while [ $_i -lt 8 ]; do
        kill -0 "$_pid" 2>/dev/null || break
        sleep 1
        _i=$((_i + 1))
      done
      kill -0 "$_pid" 2>/dev/null && kill -KILL "$_pid" 2>/dev/null
      sleep 1
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

if [ -f "$PIDFILE" ]; then
  OLD_PID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$OLD_PID" ] && [ "$OLD_PID" -gt 0 ] 2>/dev/null; then
    stop_process "$OLD_PID" || true
  fi
  rm -f "$PIDFILE" 2>/dev/null
fi

if [ -d /proc ]; then
  for _proc_dir in /proc/[0-9]*; do
    [ -d "$_proc_dir" ] || continue
    _p=$(basename "$_proc_dir")
    [ -n "$_p" ] || continue
    [ "$_p" = "$$" ] && continue
    _cl_file="$_proc_dir/cmdline"
    [ -r "$_cl_file" ] || continue
    _cl=$(tr '\0' ' ' < "$_cl_file" 2>/dev/null)
    case "$_cl" in
      *tarn\ daemon*)
        stop_process "$_p" || true
        ;;
    esac
  done
fi
unset _pid _cmdline _i _proc_dir _p _cl_file _cl

[ -e "$SOCKET_FILE" ] && rm -f "$SOCKET_FILE" 2>/dev/null

case "$ARCH" in
  arm64|arm64-v8a|aarch64) TARN_BIN="$MODPATH/tarn" ;;
  *) abort "架构不支持: $ARCH (仅 arm64-v8a/aarch64)" ;;
esac

mkdir -p "$MODPATH"
if command -v unzip >/dev/null 2>&1; then
  unzip -o "$ZIPFILE" -x "META-INF/*" -d "$MODPATH" >/dev/null 2>&1 || abort "解压失败"
elif [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -q '^unzip$'; then
  "$BB" unzip -o "$ZIPFILE" -x "META-INF/*" -d "$MODPATH" >/dev/null 2>&1 || abort "解压失败"
else
  abort "找不到 unzip (需安装 busybox 或确保系统自带 unzip)"
fi

[ -f "$TARN_BIN" ] || abort "程序文件缺失"
TARN_MAGIC=$(dd if="$TARN_BIN" bs=1 count=4 2>/dev/null | bb_wrap od -An -tx1 | tr -d ' \n')
[ "$TARN_MAGIC" = "7f454c46" ] || abort "非 ELF 文件"
TARN_MACHINE=$(dd if="$TARN_BIN" bs=1 skip=18 count=2 2>/dev/null | bb_wrap od -An -tx1 | tr -d ' \n')
[ "$TARN_MACHINE" = "b700" ] || abort "程序文件架构非 aarch64"

DATADIR=/data/adb/tarn
mkdir -p "$DATADIR/config" "$DATADIR/logs" "$DATADIR/run" "$DATADIR/rules" "$DATADIR/trash"
chmod 700 "$DATADIR" "$DATADIR/config" "$DATADIR/logs" "$DATADIR/run" "$DATADIR/rules" "$DATADIR/trash"
chown root:root "$DATADIR"

for f in settings blacklist whitelist; do
  src="$MODPATH/config/$f.toml"
  dst="$DATADIR/config/$f.toml"
  if [ ! -f "$dst" ] && [ -f "$src" ]; then
    cp -p "$src" "$dst" && chmod 600 "$dst"
  fi
done

# 配置迁移: 检测模块新增配置项, 音量键交互询问是否合并
migrate_settings
# 规则不随模块包分发: 用户从 GitHub rules/ 目录自行下载导入
# $DATADIR/rules 目录已创建 (供用户放置自有规则), 不再从 $MODPATH/rules 拷贝
SETTINGS_FILE="$DATADIR/config/settings.toml"
if [ -f "$SETTINGS_FILE" ]; then
  OLD_SOCKET=$(bb_wrap grep -E '^[[:space:]]*socket_file[[:space:]]*=' "$SETTINGS_FILE" 2>/dev/null | head -n 1 | bb_wrap sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' | tr -d '[:space:]')
  case "$OLD_SOCKET" in
    "/data/adb/tarn/tarn.sock"|"$DATADIR/tarn.sock")
      bb_wrap sed -i -E 's|^[[:space:]]*socket_file[[:space:]]*=.*|socket_file = "run/tarn.sock"|' "$SETTINGS_FILE" 2>/dev/null
      ui_print "✓ 升级迁移: 通信端点路径已更新"
      ;;
  esac
fi

for stale in "$DATADIR/token" "$DATADIR/tarn.sock"; do
  if [ -e "$stale" ]; then
    rm -f "$stale" 2>/dev/null
    ui_print "✓ 清理残留文件: $(basename "$stale")"
  fi
done

STATE_FILE="$DATADIR/state.json"
MODULE_PROP="$MODPATH/module.prop"
if [ -f "$STATE_FILE" ] && [ -f "$MODULE_PROP" ]; then
  TOTAL_FREED=$(bb_wrap grep -E '"total_freed_bytes"[[:space:]]*:' "$STATE_FILE" 2>/dev/null | head -n 1 | bb_wrap sed -E 's/.*:[[:space:]]*([0-9]+).*/\1/' | tr -d '[:space:]')
  TOTAL_FILES=$(bb_wrap grep -E '"total_files_deleted"[[:space:]]*:' "$STATE_FILE" 2>/dev/null | head -n 1 | bb_wrap sed -E 's/.*:[[:space:]]*([0-9]+).*/\1/' | tr -d '[:space:]')
  [ -z "$TOTAL_FILES" ] && TOTAL_FILES=0
  if [ -n "$TOTAL_FREED" ]; then
    case "$TOTAL_FREED" in
      *[!0-9]*)
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
        ui_print "✓ 已恢复累计统计: 删除 ${TOTAL_FILES} 文件 / 已清理 ${CLEANED_STR}"
        ;;
    esac
  fi
fi

WEBROOT_DIR="$MODPATH/webroot"
mkdir -p "$WEBROOT_DIR"
WEBUI_BIND="127.0.0.1"
WEBUI_PORT="8080"
if [ -f "$SETTINGS_FILE" ]; then
  TMP_BIND=$(bb_wrap grep -E '^[[:space:]]*bind[[:space:]]*=' "$SETTINGS_FILE" 2>/dev/null | head -n 1 | bb_wrap sed -E 's/.*=[[:space:]]*"([^"]*)".*/\1/' | tr -d '[:space:]')
  TMP_PORT=$(bb_wrap grep -E '^[[:space:]]*port[[:space:]]*=' "$SETTINGS_FILE" 2>/dev/null | head -n 1 | bb_wrap sed -E 's/.*=[[:space:]]*([0-9]+).*/\1/' | tr -d '[:space:]')
  [ -n "$TMP_BIND" ] && WEBUI_BIND="$TMP_BIND"
  [ -n "$TMP_PORT" ] && WEBUI_PORT="$TMP_PORT"
fi
[ "$WEBUI_BIND" = "0.0.0.0" ] && WEBUI_BIND="127.0.0.1"
cat > "$WEBROOT_DIR/index.html" <<HTMLEOF
<!DOCTYPE html><script>document.location='http://${WEBUI_BIND}:${WEBUI_PORT}/'</script>
HTMLEOF
chmod 644 "$WEBROOT_DIR/index.html"

ui_print "✓ 配置已部署"

APK_SRC="$MODPATH/apk/KsuWebUI-1.0-34-release.apk"
ROOT_MANAGER="unknown"

if [ -n "$KSU" ] || [ -d /data/adb/ksu ]; then
  ROOT_MANAGER="kernelsu"
elif [ -n "$APATCH" ] || [ -d /data/adb/ap ] || [ -d /data/adb/apd ]; then
  ROOT_MANAGER="apatch"
elif [ -n "$MAGISK_VER" ] || [ -n "$MAGISK_VER_CODE" ] || [ -d /data/adb/magisk ]; then
  ROOT_MANAGER="magisk"
fi

ui_print "✓ Root 管理器: $ROOT_MANAGER"

if [ -f "$APK_SRC" ]; then
  APK_OK=0
  case "$ROOT_MANAGER" in
    kernelsu|apatch)
      :
      ;;
    magisk|*)
      if command -v pm >/dev/null 2>&1; then
        APK_SIZE=$(wc -c < "$APK_SRC" 2>/dev/null | tr -d ' ')
        if pm install -r -S "$APK_SIZE" "$APK_SRC" >/dev/null 2>&1; then
          APK_OK=1
        elif pm install -r "$APK_SRC" >/dev/null 2>&1; then
          APK_OK=1
        fi
      fi
      ;;
  esac
  rm -f "$APK_SRC" 2>/dev/null
  rmdir "$MODPATH/apk" 2>/dev/null
  case "$ROOT_MANAGER" in
    kernelsu|apatch)
      :
      ;;
    magisk|*)
      if [ "$APK_OK" = "1" ]; then
        ui_print "✓ WebUI 桌面入口已安装"
      else
        ui_print "! WebUI 桌面入口安装失败"
      fi
      ;;
  esac
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$TARN_BIN" 0 0 0755
for s in service.sh uninstall.sh verify.sh debug.sh; do
  [ -f "$MODPATH/$s" ] && set_perm "$MODPATH/$s" 0 0 0755
done
[ -f "$MODPATH/webroot/index.html" ] && set_perm "$MODPATH/webroot/index.html" 0 0 0644

ui_print "✓ 安装完成"
ui_print ""
ui_print "WebUI: http://${WEBUI_BIND}:${WEBUI_PORT}"
ui_print "访问令牌: /data/adb/tarn/run/token"
case "$ROOT_MANAGER" in
  kernelsu|apatch)
    ui_print "在管理器内点击本模块即可打开 WebUI"
    ;;
  *)
    ui_print "通过桌面图标打开 WebUI"
    ;;
esac

rm -f "$MODPATH/customize.sh" 2>/dev/null

exit 0
