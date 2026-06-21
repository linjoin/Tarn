#!/system/bin/sh

MODDIR=${0%/*}
DATADIR=/data/adb/tarn
BIN="$MODDIR/tarn"
PIDFILE="$DATADIR/run/tarn.pid"

QUIET=0
JSON=0
for arg in "$@"; do
  case "$arg" in
    --quiet|-q) QUIET=1 ;;
    --json|-j) JSON=1; QUIET=1 ;;
    --help|-h)
      echo "Usage: $0 [--quiet|-q] [--json|-j] [--help|-h]"
      exit 0
      ;;
  esac
done

PASS=0
FAIL=0
ERRORS=""

ok() {
  PASS=$((PASS + 1))
  if [ "$QUIET" -eq 0 ]; then
    echo "  [✓] $1"
  fi
}

fail() {
  FAIL=$((FAIL + 1))
  ERRORS="$ERRORS$1\n"
  if [ "$QUIET" -eq 0 ]; then
    echo "  [✗] $1"
  fi
}

json_escape() {
  echo "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

if [ "$QUIET" -eq 0 ]; then
  echo "================================================"
  echo "  Tarn 完整性校验"
  echo "  模块目录: $MODDIR"
  echo "  数据目录: $DATADIR"
  echo "================================================"
  echo ""
fi

if [ "$QUIET" -eq 0 ]; then echo "[1/6] 程序文件校验"; fi

if [ -f "$BIN" ]; then
  ok "程序文件存在: $BIN"
else
  fail "程序文件不存在: $BIN"
fi

if [ -x "$BIN" ]; then
  ok "程序文件可执行"
else
  fail "程序文件不可执行 (chmod +x $BIN)"
fi

if [ -f "$BIN" ]; then
  MAGIC=$(dd if="$BIN" bs=1 count=4 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$MAGIC" = "7f454c46" ]; then
    ok "ELF magic 校验通过"
  else
    fail "ELF magic 异常: $MAGIC (期望 7f454c46)"
  fi

  MACHINE=$(dd if="$BIN" bs=1 skip=18 count=2 2>/dev/null | od -An -tx1 | tr -d ' \n')
  if [ "$MACHINE" = "b700" ]; then
    ok "架构校验通过: aarch64 (EM_AARCH64)"
  else
    fail "架构异常: e_machine=$MACHINE (期望 b700=EM_AARCH64)"
  fi

  SIZE=$(wc -c < "$BIN" 2>/dev/null | tr -d ' ')
  if [ "$SIZE" -gt 1000000 ] 2>/dev/null; then
    ok "文件大小合理: $SIZE bytes"
  else
    fail "文件大小异常: $SIZE bytes (< 1MB, 可能损坏)"
  fi

  VERSION=$("$BIN" version 2>/dev/null | head -1)
  if [ -n "$VERSION" ]; then
    ok "版本: $VERSION"
  else
    fail "无法获取版本 (程序可能无法在此环境运行)"
  fi
fi

if [ "$QUIET" -eq 0 ]; then echo ""; fi

if [ "$QUIET" -eq 0 ]; then echo "[2/6] 配置文件校验"; fi

for cfg in settings.toml blacklist.toml whitelist.toml; do
  CFG_PATH="$DATADIR/config/$cfg"
  if [ -f "$CFG_PATH" ]; then
    ok "配置存在: $cfg"
    PERM=$(stat -c '%a' "$CFG_PATH" 2>/dev/null || stat -f '%Lp' "$CFG_PATH" 2>/dev/null)
    if [ "$PERM" = "600" ]; then
      ok "  权限: 0600 ✓"
    else
      fail "  权限异常: $cfg = $PERM (期望 0600)"
    fi
    SIZE=$(wc -c < "$CFG_PATH" 2>/dev/null | tr -d ' ')
    if [ "$SIZE" -gt 0 ] 2>/dev/null; then
      ok "  非空: $SIZE bytes"
    else
      fail "  配置为空: $cfg"
    fi
  else
    fail "配置缺失: $CFG_PATH"
  fi
done

if [ "$QUIET" -eq 0 ]; then echo ""; fi

if [ "$QUIET" -eq 0 ]; then echo "[3/6] 目录结构校验"; fi

for subdir in config logs run rules trash; do
  DIR_PATH="$DATADIR/$subdir"
  if [ -d "$DIR_PATH" ]; then
    ok "目录存在: $subdir/"
    PERM=$(stat -c '%a' "$DIR_PATH" 2>/dev/null || stat -f '%Lp' "$DIR_PATH" 2>/dev/null)
    if [ "$PERM" = "700" ]; then
      ok "  权限: 0700 ✓"
    else
      fail "  权限异常: $subdir/ = $PERM (期望 0700)"
    fi
  else
    fail "目录缺失: $DIR_PATH"
  fi
done

if [ -d "$DATADIR" ]; then
  PERM=$(stat -c '%a' "$DATADIR" 2>/dev/null || stat -f '%Lp' "$DATADIR" 2>/dev/null)
  if [ "$PERM" = "700" ]; then
    ok "数据目录权限: 0700 ✓"
  else
    fail "数据目录权限异常: $PERM (期望 0700)"
  fi
fi

if [ "$QUIET" -eq 0 ]; then echo ""; fi

if [ "$QUIET" -eq 0 ]; then echo "[4/6] 脚本文件校验"; fi

for script in service.sh uninstall.sh debug.sh verify.sh; do
  SCRIPT_PATH="$MODDIR/$script"
  if [ -f "$SCRIPT_PATH" ]; then
    ok "脚本存在: $script"
    if [ -x "$SCRIPT_PATH" ]; then
      ok "  可执行 ✓"
    else
      fail "  不可执行: $script (chmod +x)"
    fi
  else
    fail "脚本缺失: $SCRIPT_PATH"
  fi
done

CUSTOMIZE_PATH="$MODDIR/customize.sh"
if [ -f "$CUSTOMIZE_PATH" ]; then
  ok "customize.sh 存在 (安装后通常被清理, 保留亦正常)"
  if [ -x "$CUSTOMIZE_PATH" ]; then
    ok "  可执行 ✓"
  else
    fail "  不可执行: customize.sh (chmod +x)"
  fi
else
  ok "customize.sh 已清理 (安装后自动删除, 属正常)"
fi

if [ -f "$MODDIR/module.prop" ]; then
  ok "module.prop 存在"
  if grep -q '^id=tarn$' "$MODDIR/module.prop" 2>/dev/null; then
    ok "  id=tarn ✓"
  else
    fail "  module.prop 缺少 id=tarn"
  fi
  if grep -q '^versionCode=' "$MODDIR/module.prop" 2>/dev/null; then
    ok "  versionCode 存在 ✓"
  else
    fail "  module.prop 缺少 versionCode"
  fi
else
  fail "module.prop 缺失"
fi

if [ "$QUIET" -eq 0 ]; then echo ""; fi

if [ "$QUIET" -eq 0 ]; then echo "[5/6] 后台服务校验"; fi

if [ -f "$PIDFILE" ]; then
  DAEMON_PID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$DAEMON_PID" ] && [ "$DAEMON_PID" -gt 0 ] 2>/dev/null; then
    if kill -0 "$DAEMON_PID" 2>/dev/null; then
      CMDLINE=""
      if [ -r "/proc/$DAEMON_PID/cmdline" ]; then
        CMDLINE=$(tr '\0' ' ' < "/proc/$DAEMON_PID/cmdline" 2>/dev/null)
      fi
      case "$CMDLINE" in
        *tarn*)
          ok "服务运行中 (pid=$DAEMON_PID)"
          ok "  命令行: $CMDLINE"
          if [ -r "/proc/$DAEMON_PID/status" ]; then
            RSS=$(grep '^VmRSS:' "/proc/$DAEMON_PID/status" 2>/dev/null | awk '{print $2}')
            if [ -n "$RSS" ]; then
              ok "  内存 RSS: ${RSS} kB"
            fi
          fi
          ;;
        *)
          fail "进程 pid=$DAEMON_PID 不匹配 (可能已被复用)"
          ;;
      esac
    else
      fail "进程 pid=$DAEMON_PID 已不存活"
    fi
  else
    fail "记录文件内容非法: $DAEMON_PID"
  fi
else
  fail "记录文件不存在 (服务未运行或首次启动)"
fi

if [ "$QUIET" -eq 0 ]; then echo ""; fi

if [ "$QUIET" -eq 0 ]; then echo "[6/6] 自检"; fi

if [ -x "$BIN" ]; then
  DOCTOR_OUT=$("$BIN" doctor 2>&1)
  if [ $? -eq 0 ]; then
    ok "自检通过"
    if [ "$QUIET" -eq 0 ]; then
      echo "$DOCTOR_OUT" | sed 's/^/    /'
    fi
  else
    fail "自检失败"
    if [ "$QUIET" -eq 0 ]; then
      echo "$DOCTOR_OUT" | sed 's/^/    /'
    fi
  fi
fi

if [ "$JSON" -eq 1 ]; then
  ERRORS_ESCAPED=$(json_escape "$(printf '%b' "$ERRORS" | sed '/^$/d')")
  cat <<EOF
{
  "pass": $PASS,
  "fail": $FAIL,
  "result": "$([ $FAIL -eq 0 ] && echo 'OK' || echo 'FAIL')",
  "errors": "$(printf '%b' "$ERRORS" | sed '/^$/d' | sed ':a;N;$!ba;s/\n/\\n/g')"
}
EOF
else
  echo ""
  echo "================================================"
  if [ "$FAIL" -eq 0 ]; then
    echo "  ✓ 全部通过 ($PASS 项)"
  else
    echo "  ✗ $FAIL 项失败, $PASS 项通过"
    echo ""
    echo "  失败项:"
    printf '%b' "$ERRORS" | sed '/^$/d' | sed 's/^/    /'
  fi
  echo "================================================"
fi

exit $([ $FAIL -eq 0 ] && echo 0 || echo 1)
