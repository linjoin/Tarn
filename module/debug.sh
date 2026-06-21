#!/system/bin/sh
# Tarn 诊断快照脚本 v5
#
# v5 改进 (相对 v4):
#   - diagnostic.txt 不再转储用户清理规则的内容: 社区规则包可达数千行,
#     转储进诊断文本会撑爆体积且与 configs/rules/ 重复。第 4 章改为只列
#     清单 (文件名 / 行数 / 字节), 足以判断规则加载状态。
#   - 压缩包 configs/rules/ 仍保留规则文件原样副本 (取证需要, 每个 .toml
#     附 .meta sidecar 记录源路径/权限/大小/md5)。需要看规则原文解压包取。
#   - 移除 dump_file_smart 函数 (仅规则转储用, 诊断文本不再转储规则内容, 已无用)。
#
# v4 改进 (相对 v3):
#   - 输出从单一 .txt 改为 tar.gz 压缩包, 一个档案装全部:
#     * diagnostic.txt   — 完整诊断文本 (v3 全部 17 章检测项, 自包含可读)
#     * configs/         — 用户配置原样副本 (settings/blacklist/whitelist/rules/*.toml)
#                          每个文件附 .meta 记录源路径/权限/大小/md5, 便于取证比对
#     * logs/            — 日志副本 (boot.log 智能截断, tarn.log 尾部 3000 行, debug-sh.err)
#     * state/           — state.json 全量 + run/ 目录元信息 + pidfile + boot_failures
#     * system/          — 系统快照独立成文: dmesg 尾部 / mount 全量 / getprop 全量 /
#                          SELinux avc denial (dmesg+logcat 各一份), 便于单独分析
#     * meta/            — 模块脚本 (module.prop/service.sh/uninstall.sh) + 环境元信息
#     * MANIFEST.txt     — 包内全文件清单 + 大小, 一目了然
#   - busybox 检测增强: 覆盖 KSU/APatch/Magisk 三大 root 框架全部常见路径
#     优先级: ksu > ap > magisk > system > xbin > vendor > PATH
#     新增 ksu/bin/busybox_static / apd/bin/busybox / magisk/.busybox 等非主流路径
#   - tar.gz 创建优先用 root 管理器的 busybox tar (带 -z gzip, 最可靠):
#     busybox tar (有 tar applet 时) > toybox/system tar -z > tar+gzip 分步管道
#     三级降级保证任何环境都能打包 (前提: 至少有 tar 或 busybox)
#   - 打包成功后自动删除暂存目录; 失败则保留暂存目录 + 写 .FAILED 标记供排查
#   - 旧版 debug-*.txt 残留清理保留 (兼容 v3 及更早), 新增 debug-*.tar.gz 7 天清理
#   - crash throttle: 最多保留 20 份 tar.gz, 超出删最旧
#   - 最终结果 (路径/大小/包结构) 打印到 stdout, 供 WebUI/终端直接显示
#
# v3 改进 (相对 v2):
#   - 修复 arch 匹配误报 FAIL: Android toybox readelf 输出 "arm64" 而非 "aarch64"
#     改用 od 读 ELF e_machine 字节 (offset 18, aarch64=183), 不依赖文本格式
#   - 修复日志错误关键词误报 WARN: "panic hook 已安装" 等 INFO 日志被 naive 子串匹配误判
#     改为匹配 [ERROR]/[WARN]/[FATAL]/[PANIC] 日志级别前缀, 并排除正面描述
#   - 修复 KernelSU 版本读不到: 加 getprop ro.kernelsu.version + ksud --version 兜底
#   - 修复 nc -U 假阴性: 空输入导致 HTTP 服务关闭连接误判不可达, 改发合法 HTTP GET
#   - 修复 state.json 字段名不匹配: 9 个字段只命中 2 个, 更新为实际 schema 字段名
#   - 修复 cmdline null 字节污染: /proc/PID/cmdline 的 \0 分隔符导致文件被识别为 binary
#   - 修复摘要不准: arch FAIL / nc WARN 未计入 add_summary, 摘要与全文不一致
#   - 新增 load average 高负载告警 (load > 核心数×4 时 WARN)
#   - 新增 dump_file_smart: 规则包等大文件超过阈值只取头尾, 避免快照膨胀
#
# v2 改进 (相对 v1):
#   - 新增 SELinux avc denial 审计 (dmesg + logcat), Android root 故障头号元凶
#   - 新增 fd 上限 / oom_score_adj / inode 使用 检测
#   - 新增 WebUI TCP 端口监听检测 (读 /proc/$PID/net/tcp)
#   - 新增二进制可执行性深度检测 (arch 匹配 + 动态库依赖)
#   - 新增启动链路检测 (模块 disable/remove/update 标志)
#   - 新增 socket 连通性测试 (实际 connect, 非仅 ls)
#   - 新增 Root 框架明确识别 (KSU/APatch/Magisk 给结论)
#   - state.json 瘦身 (只取关键字段 + tail, 不再全文 dump 1776 行)
#   - mount 输出降噪 (只取关键挂载点)
#   - 新增诊断摘要 (末尾汇总各子系统状态)
#   - 每项检测标注 [OK]/[WARN]/[FAIL], 一目了然

MODDIR=${0%/*}
DATADIR=/data/adb/tarn
BIN="$MODDIR/tarn"
LOGDIR="$DATADIR/logs"
TS=$(date '+%Y%m%d_%H%M%S' 2>/dev/null)

# 输出为 tar.gz 压缩包, 内含诊断文本 + 原样配置/日志/状态/系统快照
# 暂存目录用隐藏名 (.debug-staging-*) 避免污染 LOGDIR 的清理扫描
ARCHIVE="$LOGDIR/debug-${TS}.tar.gz"
STAGE_NAME="tarn-debug-${TS}"
STAGE_ROOT="$LOGDIR/.debug-staging-${TS}"
STAGE="$STAGE_ROOT/$STAGE_NAME"
OUT="$STAGE/diagnostic.txt"

# ============================================================
# 工具函数
# ============================================================

# busybox 检测: 优先 root 管理器 (ksu/ap/magisk), 覆盖全部常见路径
# 优先级: KSU > APatch > Magisk > system > xbin > vendor > PATH
# root 管理器的 busybox 通常版本更新、applet 更全 (含 tar/gzip/md5sum 等)
detect_bb() {
  for cand in \
    /data/adb/ksu/bin/busybox \
    /data/adb/ksu/bin/busybox_static \
    /data/adb/ap/bin/busybox \
    /data/adb/apd/bin/busybox \
    /data/adb/magisk/busybox \
    /data/adb/magisk/.busybox/busybox \
    /system/bin/busybox \
    /system/xbin/busybox \
    /vendor/bin/busybox; do
    [ -x "$cand" ] && { echo "$cand"; return 0; }
  done
  # PATH 兜底 (部分设备把 busybox 软链到 /system/bin)
  command -v busybox 2>/dev/null && return 0
  echo ""
  return 1
}

BB=$(detect_bb)

# 检查 busybox 是否提供某 applet (用 --list 列表精确匹配)
bb_has() {
  [ -n "$BB" ] || return 1
  "$BB" --list 2>/dev/null | grep -qx "$1" 2>/dev/null
}

bb_wrap() {
  cmd=$1
  shift
  if [ -n "$BB" ]; then
    "$BB" "$cmd" "$@"
  else
    "$cmd" "$@"
  fi
}

# tar.gz 创建 (v4 核心): 三级降级保证可打包
#   1) root 管理器 busybox tar (有 tar applet 时, 带 -z 最可靠)
#   2) toybox/system tar -z (Android toybox tar 支持 -z)
#   3) tar + gzip 分步管道 (最兜底)
# $1=archive $2=-C cwd $3=entry
create_targz() {
  _arc=$1; _cwd=$2; _entry=$3
  # 方案 1: busybox tar (root 管理器优先, applet 全)
  if bb_has tar; then
    "$BB" tar -czf "$_arc" -C "$_cwd" "$_entry" 2>/dev/null && return 0
  fi
  # 方案 2: 系统/toybox tar -z
  if command -v tar >/dev/null 2>&1; then
    tar -czf "$_arc" -C "$_cwd" "$_entry" 2>/dev/null && return 0
  fi
  # 方案 3: tar + gzip 分步 (tar 不支持 -z 时的兜底)
  if command -v tar >/dev/null 2>&1; then
    if bb_has gzip || command -v gzip >/dev/null 2>&1; then
      _tmp="$_arc.tmp"
      tar -cf "$_tmp" -C "$_cwd" "$_entry" 2>/dev/null || { rm -f "$_tmp" 2>/dev/null; unset _arc _cwd _entry _tmp; return 1; }
      if bb_has gzip; then
        "$BB" gzip -c "$_tmp" > "$_arc" 2>/dev/null
      else
        gzip -c "$_tmp" > "$_arc" 2>/dev/null
      fi
      _rc=$?
      rm -f "$_tmp" 2>/dev/null
      [ "$_rc" = "0" ] && { unset _arc _cwd _entry _tmp; return 0; }
    fi
  fi
  unset _arc _cwd _entry _tmp
  return 1
}

# 收集原文件到暂存区 (原样副本, 不修改源文件)
# 用 cat 复制内容 (跨设备最兼容, 不依赖 cp 标志差异), 附 .meta 记录取证信息
# $1=源文件 $2=目标路径
collect_file() {
  _src=$1; _dest=$2
  mkdir -p "$(dirname "$_dest")" 2>/dev/null
  if [ -f "$_src" ]; then
    cat "$_src" > "$_dest" 2>/dev/null
    # 元信息 sidecar: 源路径 + ls -la + 字节数 + md5 (便于比对是否被篡改)
    {
      echo "source: $_src"
      ls -la "$_src" 2>/dev/null
      echo "size_bytes: $(wc -c < "$_src" 2>/dev/null | tr -d '[:space:]')"
      if bb_has md5sum; then
        echo "md5: $("$BB" md5sum "$_src" 2>/dev/null | awk '{print $1}')"
      elif command -v md5sum >/dev/null 2>&1; then
        echo "md5: $(md5sum "$_src" 2>/dev/null | awk '{print $1}')"
      fi
    } > "${_dest}.meta" 2>/dev/null
  else
    echo "(文件不存在: $_src)" > "$_dest"
    echo "source: $_src (missing)" > "${_dest}.meta"
  fi
  unset _src _dest
}

mkdir -p "$LOGDIR" 2>/dev/null
# 建暂存子目录 (configs/rules/logs/state/system/meta)
mkdir -p "$STAGE/configs/rules" "$STAGE/logs" "$STAGE/state" "$STAGE/system" "$STAGE/meta" 2>/dev/null

# 状态标注: $1=OK|WARN|FAIL|INFO, $2=消息
mark() {
  echo "[$1] $2" >> "$OUT" 2>/dev/null
}

section() {
  echo "" >> "$OUT" 2>/dev/null
  echo "========================================================" >> "$OUT" 2>/dev/null
  echo "  $1" >> "$OUT" 2>/dev/null
  echo "========================================================" >> "$OUT" 2>/dev/null
}

run_cmd() {
  echo "$ $*" >> "$OUT" 2>/dev/null
  "$@" >> "$OUT" 2>&1
  echo "" >> "$OUT" 2>/dev/null
}

run_sh() {
  echo "$ $1" >> "$OUT" 2>/dev/null
  sh -c "$1" >> "$OUT" 2>&1
  echo "" >> "$OUT" 2>/dev/null
}

dump_file() {
  _f=$1
  _label=${2:-$_f}
  echo "--- $_label ---" >> "$OUT" 2>/dev/null
  if [ -f "$_f" ]; then
    # /proc/PID/cmdline 等内核接口用 null 分隔参数, 直接 cat 会把 null 字节
    # 写进诊断文件, 导致 file(1) 识别为 binary、部分 grep/编辑器异常。
    # 用 tr 把 null 转成空格, 保证输出始终是纯文本。
    case "$_f" in
      /proc/*cmdline|*/cmdline)
        cat "$_f" 2>/dev/null | tr '\000' ' ' >> "$OUT" 2>/dev/null
        echo "" >> "$OUT" 2>/dev/null
        ;;
      *)
        cat "$_f" >> "$OUT" 2>/dev/null
        ;;
    esac
  else
    echo "(文件不存在: $_f)" >> "$OUT" 2>/dev/null
  fi
  echo "" >> "$OUT" 2>/dev/null
  unset _f _label
}

dump_file_tail() {
  _f=$1
  _n=${2:-200}
  _label=${3:-$_f}
  echo "--- $_label (tail $_n) ---" >> "$OUT" 2>/dev/null
  if [ -f "$_f" ]; then
    bb_wrap tail -n "$_n" "$_f" >> "$OUT" 2>/dev/null
  else
    echo "(文件不存在: $_f)" >> "$OUT" 2>/dev/null
  fi
  echo "" >> "$OUT" 2>/dev/null
  unset _f _n _label
}

# (v5 移除 dump_file_smart: 规则不再转储内容, 该函数无用已删)

# 从 settings.toml 提取字段值 (简单 grep, 不依赖 toml 解析器)
# $1=字段名 $2=默认值
get_setting() {
  _key=$1
  _def=$2
  if [ -f "$DATADIR/config/settings.toml" ]; then
    _v=$(bb_wrap grep -E "^[[:space:]]*${_key}[[:space:]]*=" "$DATADIR/config/settings.toml" 2>/dev/null | head -n 1 | bb_wrap sed -E "s/.*=[[:space:]]*\"?([^\"#[:space:]]+).*/\1/" | tr -d '[:space:]')
    [ -n "$_v" ] && { echo "$_v"; unset _key _def _v; return; }
  fi
  echo "$_def"
  unset _key _def _v
}

# 诊断摘要收集 (末尾输出)
SUMMARY=""
add_summary() {
  SUMMARY="${SUMMARY}$1"$'\n'
}

# ============================================================
# 头部
# ============================================================
{
  echo "========================================================"
  echo "  Tarn 诊断快照 v5 (tar.gz 打包)"
  echo "  生成时间: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  echo "  模块目录: $MODDIR"
  echo "  数据目录: $DATADIR"
  echo "  busybox:  ${BB:-(未找到, 部分检测将降级)}"
  echo "  输出包:   $ARCHIVE"
  echo "========================================================"
} > "$OUT" 2>/dev/null

# ============================================================
# 1. 版本与模块信息
# ============================================================
section "1. 版本与模块信息"
if [ -x "$BIN" ]; then
  run_cmd "$BIN" version
  add_summary "[OK] 二进制可执行, version 命令正常"
else
  mark FAIL "二进制不可执行: $BIN (arch 不匹配? 权限? 缺依赖?)"
  add_summary "[FAIL] 二进制不可执行: $BIN"
fi
dump_file "$MODDIR/module.prop" "module.prop"

# 模块状态标志检测 (Magisk/KSU 框架级)
echo "--- 模块状态标志 ---" >> "$OUT" 2>/dev/null
for flag in disable remove skip_mount; do
  if [ -f "$MODDIR/$flag" ]; then
    mark WARN "检测到 $flag 标志 (模块被框架标记: $flag)"
    add_summary "[WARN] 模块带 $flag 标志"
  fi
done
# 待更新检测
if [ -d "/data/adb/modules_update/tarn" ]; then
  mark WARN "检测到 /data/adb/modules_update/tarn (模块待更新, 下次重启替换)"
  add_summary "[WARN] 模块有待更新版本"
fi
if [ ! -f "$MODDIR/disable" ] && [ ! -f "$MODDIR/remove" ]; then
  mark OK "无 disable/remove 标志, 模块处于启用状态"
fi
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 2. 进程信息
# ============================================================
section "2. 进程信息"
PIDFILE="$DATADIR/run/tarn.pid"
DPID=""
if [ -f "$PIDFILE" ]; then
  DPID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')
  echo "pidfile 内容: $DPID" >> "$OUT" 2>/dev/null
  if [ -n "$DPID" ] && [ "$DPID" -gt 0 ] 2>/dev/null; then
    if kill -0 "$DPID" 2>/dev/null; then
      mark OK "daemon 进程存活 (pid=$DPID)"
      add_summary "[OK] daemon 运行中 (pid=$DPID)"
      dump_file "/proc/$DPID/status" "/proc/$DPID/status"
      dump_file "/proc/$DPID/cmdline" "/proc/$DPID/cmdline"
      run_sh "ls -la /proc/$DPID/fd/ 2>/dev/null"

      # 进程级资源约束 (v2 新增)
      echo "--- 进程资源约束 ---" >> "$OUT" 2>/dev/null
      echo "$ cat /proc/$DPID/limits" >> "$OUT" 2>/dev/null
      if [ -r "/proc/$DPID/limits" ]; then
        bb_wrap grep -E 'Max open files|Max processes|Max file size' "/proc/$DPID/limits" >> "$OUT" 2>/dev/null
      else
        echo "(不可读: /proc/$DPID/limits)" >> "$OUT" 2>/dev/null
      fi
      echo "" >> "$OUT" 2>/dev/null

      # oom_score_adj (Android lmkd 杀后台进程是高频问题)
      echo "$ cat /proc/$DPID/oom_score_adj" >> "$OUT" 2>/dev/null
      OOM_ADJ=""
      if [ -r "/proc/$DPID/oom_score_adj" ]; then
        OOM_ADJ=$(cat "/proc/$DPID/oom_score_adj" 2>/dev/null | tr -d '[:space:]')
        echo "$OOM_ADJ" >> "$OUT" 2>/dev/null
        if [ -n "$OOM_ADJ" ]; then
          if [ "$OOM_ADJ" -ge 900 ] 2>/dev/null; then
            mark WARN "oom_score_adj=$OOM_ADJ (>=900, 易被 lmkd 在低内存时杀死)"
            add_summary "[WARN] oom_score_adj=$OOM_ADJ 偏高, 易被 lmkd 杀"
          else
            mark OK "oom_score_adj=$OOM_ADJ"
          fi
        fi
      else
        echo "(不可读)" >> "$OUT" 2>/dev/null
      fi
      echo "" >> "$OUT" 2>/dev/null

      # 实际加载的动态库 (从 /proc/maps 提取, 不依赖 ldd)
      echo "--- 已加载动态库 (去重, 从 /proc/$DPID/maps) ---" >> "$OUT" 2>/dev/null
      if [ -r "/proc/$DPID/maps" ]; then
        bb_wrap grep -oE '/system/[^ ]+\.so|/apex/[^ ]+\.so|/data/[^ ]+\.so' "/proc/$DPID/maps" 2>/dev/null | sort -u >> "$OUT" 2>/dev/null
        SO_COUNT=$(bb_wrap grep -coE '\.so' "/proc/$DPID/maps" 2>/dev/null | tr -d '[:space:]')
        mark INFO "已加载 .so 数量(粗略): ${SO_COUNT:-0}"
      else
        mark WARN "/proc/$DPID/maps 不可读"
      fi
      echo "" >> "$OUT" 2>/dev/null
    else
      mark FAIL "pidfile 指向的进程 $DPID 已不存活 (孤儿 pidfile, daemon 可能已崩溃)"
      add_summary "[FAIL] daemon 进程已死 (孤儿 pidfile pid=$DPID)"
    fi
  else
    mark FAIL "pidfile 内容无效: '$DPID'"
    add_summary "[FAIL] pidfile 内容无效"
  fi
else
  mark WARN "pidfile 不存在 (daemon 未运行或未正确初始化)"
  add_summary "[WARN] daemon 未运行 (无 pidfile)"
fi

echo "" >> "$OUT" 2>/dev/null
echo "--- ps (tarn 相关) ---" >> "$OUT" 2>/dev/null
if [ -n "$BB" ]; then
  "$BB" ps 2>/dev/null | bb_wrap grep -E '[t]arn' >> "$OUT" 2>/dev/null
else
  ps -A -o pid,ppid,cmd 2>/dev/null | bb_wrap grep -E '[t]arn' >> "$OUT" 2>/dev/null
fi
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 3. 日志文件
# ============================================================
section "3. 日志文件"
dump_file "$DATADIR/logs/boot.log" "boot.log (完整)"
dump_file_tail "$DATADIR/logs/tarn.log" 300 "tarn.log (tail 300)"

# 日志错误高亮 (v2 新增)
echo "--- 日志中的错误/警告关键词 (tarn.log 最近 500 行) ---" >> "$OUT" 2>/dev/null
if [ -f "$DATADIR/logs/tarn.log" ]; then
  # 优先匹配日志级别前缀 [ERROR]/[WARN]/[FATAL]/[PANIC], 避免误报
  # 同时排除正面描述: "panic hook 已安装"/"error handler"/"fail_count" 等把错误词
  # 用在功能名里的 INFO 日志 (历史误报案例: "panic hook 已安装" 被当成 panic 错误)
  ERR_CNT=$(bb_wrap tail -n 500 "$DATADIR/logs/tarn.log" 2>/dev/null \
    | bb_wrap grep -E '\[(ERROR|FATAL|PANIC)\]' 2>/dev/null \
    | bb_wrap grep -vE 'hook 已安装|handler 已|安装.*hook|已设为|已安装' 2>/dev/null \
    | bb_wrap grep -c '' 2>/dev/null | tr -d '[:space:]')
  WARN_CNT_LOG=$(bb_wrap tail -n 500 "$DATADIR/logs/tarn.log" 2>/dev/null \
    | bb_wrap grep -E '\[WARN\]' 2>/dev/null \
    | bb_wrap grep -c '' 2>/dev/null | tr -d '[:space:]')
  ERR_CNT=${ERR_CNT:-0}
  WARN_CNT_LOG=${WARN_CNT_LOG:-0}
  if [ "$ERR_CNT" -gt 0 ] 2>/dev/null; then
    mark FAIL "tarn.log 最近 500 行含 ${ERR_CNT} 条 [ERROR]/[FATAL]/[PANIC] 级别日志"
    bb_wrap tail -n 500 "$DATADIR/logs/tarn.log" 2>/dev/null \
      | bb_wrap grep -E '\[(ERROR|FATAL|PANIC)\]' 2>/dev/null \
      | bb_wrap grep -vE 'hook 已安装|handler 已|安装.*hook|已设为|已安装' 2>/dev/null \
      | bb_wrap tail -n 20 >> "$OUT" 2>/dev/null
    add_summary "[FAIL] 日志含 ${ERR_CNT} 条 ERROR 级别记录"
  elif [ "$WARN_CNT_LOG" -gt 0 ] 2>/dev/null; then
    mark WARN "tarn.log 最近 500 行含 ${WARN_CNT_LOG} 条 [WARN] 级别日志"
    bb_wrap tail -n 500 "$DATADIR/logs/tarn.log" 2>/dev/null \
      | bb_wrap grep -E '\[WARN\]' 2>/dev/null \
      | bb_wrap tail -n 20 >> "$OUT" 2>/dev/null
    add_summary "[WARN] 日志含 ${WARN_CNT_LOG} 条 WARN 级别记录"
  else
    mark OK "tarn.log 最近 500 行无 ERROR/WARN 级别日志 (已排除 panic hook 等正面描述)"
  fi
else
  mark WARN "tarn.log 不存在"
fi
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 4. 配置文件
# ============================================================
section "4. 配置文件"
dump_file "$DATADIR/config/settings.toml" "settings.toml"
dump_file "$DATADIR/config/blacklist.toml" "blacklist.toml"
dump_file "$DATADIR/config/whitelist.toml" "whitelist.toml"

# toml 语法初校验 (v2 新增, 只查明显的括号/引号不匹配)
echo "--- 配置语法初校验 ---" >> "$OUT" 2>/dev/null
for cfg in settings blacklist whitelist; do
  CFGF="$DATADIR/config/${cfg}.toml"
  if [ -f "$CFGF" ]; then
    SECTIONS=$(bb_wrap grep -cE '^\[' "$CFGF" 2>/dev/null | tr -d '[:space:]')
    mark INFO "${cfg}.toml: ${SECTIONS:-0} 个 [section]"
  fi
done
echo "" >> "$OUT" 2>/dev/null

echo "--- rules/ 目录列表 ---" >> "$OUT" 2>/dev/null
if [ -d "$DATADIR/rules" ]; then
  ls -la "$DATADIR/rules/" >> "$OUT" 2>/dev/null
  RULE_CNT=0
  echo "--- 规则文件清单 (文件名 / 行数 / 字节, 不转储内容) ---" >> "$OUT" 2>/dev/null
  for rf in "$DATADIR/rules"/*.toml "$DATADIR/rules"/*.txt; do
    [ -f "$rf" ] || continue
    RULE_CNT=$((RULE_CNT + 1))
    # 规则包可能很大 (社区包数千行), 不转储内容避免撑爆诊断文本与压缩包
    _rl=$(wc -l < "$rf" 2>/dev/null | tr -d '[:space:]')
    _rb=$(wc -c < "$rf" 2>/dev/null | tr -d '[:space:]')
    case "$_rl" in ''|*[!0-9]*) _rl=0 ;; esac
    case "$_rb" in ''|*[!0-9]*) _rb=0 ;; esac
    printf '  %-40s %8s 行 %10s 字节\n' "$(basename "$rf")" "$_rl" "$_rb" >> "$OUT" 2>/dev/null
    unset _rl _rb
  done
  mark INFO "规则文件数: $RULE_CNT (诊断文本只列清单, 原文副本在包内 configs/rules/)"
  add_summary "[INFO] 加载 $RULE_CNT 个规则文件"
else
  mark WARN "rules/ 目录不存在 (无清理规则, daemon 空跑)"
  add_summary "[WARN] 无 rules 目录"
fi

# ============================================================
# 5. 状态与运行时 (state.json 瘦身)
# ============================================================
section "5. 状态与运行时 (state.json 关键字段)"
STATE="$DATADIR/state.json"
if [ -f "$STATE" ]; then
  STATE_LINES=$(wc -l < "$STATE" 2>/dev/null | tr -d '[:space:]')
  STATE_BYTES=$(wc -c < "$STATE" 2>/dev/null | tr -d '[:space:]')
  mark INFO "state.json: ${STATE_LINES} 行 / ${STATE_BYTES} 字节 (完整原文件见包内 state/)"

  echo "--- 关键字段提取 ---" >> "$OUT" 2>/dev/null
  # 提取关键字段 (避免全文 dump 淹没诊断)
  # 字段名必须与 crates/core/src/state.rs 的 State/Totals/LastRun 结构对齐:
  #   顶层: schema_version / last_updated / totals / last_run / rules / history / rotation_history
  #   totals: total_runs / total_freed_bytes / total_files_deleted / total_dirs_removed
  #   last_run: run_id / ts_start / ts_end / trigger / freed_bytes / files_deleted / status / exit_code / dry_run
  # 注: pid 在 pidfile (不在 state.json); boot_failures 在 run/boot_failures 文件 (第14章检测);
  #     schedule 在 settings.toml (第4章已转储); 这些都不在 state.json 里。
  for key in '"schema_version"' '"last_updated"' '"total_runs"' '"total_freed_bytes"' '"total_files_deleted"' '"total_dirs_removed"'; do
    bb_wrap grep -E "^[[:space:]]*${key}[[:space:]]*:" "$STATE" 2>/dev/null | head -n 1 >> "$OUT" 2>/dev/null
  done
  echo "--- last_run (最近一次运行) ---" >> "$OUT" 2>/dev/null
  for key in '"run_id"' '"ts_start"' '"ts_end"' '"trigger"' '"freed_bytes"' '"files_deleted"' '"status"' '"exit_code"' '"dry_run"'; do
    bb_wrap grep -E "^[[:space:]]*${key}[[:space:]]*:" "$STATE" 2>/dev/null | head -n 1 >> "$OUT" 2>/dev/null
  done
  echo "" >> "$OUT" 2>/dev/null

  # rotation_history 只看数量, 不 dump 内容
  ROT_CNT=$(bb_wrap grep -cE '"rotation_history"' "$STATE" 2>/dev/null | tr -d '[:space:]')
  if [ "${ROT_CNT:-0}" -gt 0 ]; then
    mark INFO "rotation_history 存在 (累计统计已轮转过)"
  fi

  # 尾部 50 行兜底 (防关键字段名变化)
  dump_file_tail "$STATE" 50 "state.json (tail 50, 兜底)"
else
  mark WARN "state.json 不存在 (daemon 未初始化或首次运行)"
fi

echo "" >> "$OUT" 2>/dev/null
echo "--- run/ 目录列表 ---" >> "$OUT" 2>/dev/null
ls -la "$DATADIR/run/" >> "$OUT" 2>/dev/null
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 6. 数据目录结构
# ============================================================
section "6. 数据目录结构"
run_sh "ls -laR $DATADIR/ 2>/dev/null | head -200"

# ============================================================
# 7. 系统信息
# ============================================================
section "7. 系统信息"
run_cmd uname -a
run_sh "uptime 2>/dev/null"
run_sh "cat /proc/loadavg 2>/dev/null"

# load average 高负载告警 (v3 新增)
# 解析 /proc/loadavg 第一个字段 (1分钟平均负载), 与 CPU 核心数比较
LOAD1=$(bb_wrap head -n 1 /proc/loadavg 2>/dev/null | bb_wrap awk '{print $1}' 2>/dev/null)
CPU_N=$(bb_wrap grep -cE '^processor' /proc/cpuinfo 2>/dev/null | tr -d '[:space:]')
case "$CPU_N" in ''|*[!0-9]*) CPU_N=8 ;; esac
# 用 awk 做浮点比较 (sh 不支持浮点运算)
if [ -n "$LOAD1" ]; then
  LOAD_HIGH=$(bb_wrap awk -v l="$LOAD1" -v c="$CPU_N" 'BEGIN{ print (l > c*4) ? 1 : 0 }' 2>/dev/null)
  if [ "$LOAD_HIGH" = "1" ]; then
    mark WARN "load average ${LOAD1} 超高 (CPU 核心数 ${CPU_N} 的 4 倍 = $((CPU_N*4)), 系统严重过载, tarn 清理可能被拖慢)"
    add_summary "[WARN] 系统负载过高 (load1=${LOAD1}, ${CPU_N} 核)"
  else
    mark OK "load average ${LOAD1} 正常 (CPU 核心数 ${CPU_N})"
  fi
fi

echo "--- /proc/meminfo ---" >> "$OUT" 2>/dev/null
bb_wrap head -n 15 /proc/meminfo >> "$OUT" 2>/dev/null
echo "" >> "$OUT" 2>/dev/null
echo "--- /proc/cpuinfo (前 30 行) ---" >> "$OUT" 2>/dev/null
bb_wrap head -n 30 /proc/cpuinfo >> "$OUT" 2>/dev/null
echo "" >> "$OUT" 2>/dev/null

# shell 资源限制 (v2 新增)
echo "--- shell 资源限制 (ulimit) ---" >> "$OUT" 2>/dev/null
echo "$ ulimit -n (open files)" >> "$OUT" 2>/dev/null
ulimit -n 2>/dev/null >> "$OUT" 2>/dev/null
echo "$ ulimit -u (max user processes)" >> "$OUT" 2>/dev/null
ulimit -u 2>/dev/null >> "$OUT" 2>/dev/null
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 8. Android 属性
# ============================================================
section "8. Android 属性"
for prop in \
  ro.build.version.release \
  ro.build.version.sdk \
  ro.build.version.incremental \
  ro.product.model \
  ro.product.brand \
  ro.product.manufacturer \
  ro.product.cpu.abi \
  ro.product.cpu.abilist \
  ro.hardware \
  ro.boot.slot_suffix \
  ro.boot.verifiedbootstate \
  ro.boot.flash.locked \
  ro.boot.vbmeta.device_state; do
  run_sh "getprop $prop 2>/dev/null"
done

# ============================================================
# 9. Root 管理器检测 (明确识别, v2 增强)
# ============================================================
section "9. Root 管理器检测 (框架识别)"
ROOT_MGR="未知"
ROOT_VER=""

if [ -d /data/adb/ksu ] || [ -f /data/adb/ksu/.allowlist ] || [ -f /data/adb/ksu_version ]; then
  ROOT_MGR="KernelSU"
  # KSU 版本散落在多处, 逐一兜底:
  #   /data/adb/ksu_version     (老版 KSU)
  #   /data/adb/ksu/version     (部分 KSU Next)
  #   getprop ro.kernelsu.version (系统属性, KSU 集成进内核时常见)
  #   /data/adb/ksu/bin/ksud --version (新版 KSU Next 守护进程)
  ROOT_VER=$(cat /data/adb/ksu_version 2>/dev/null | tr -d '[:space:]')
  [ -z "$ROOT_VER" ] && ROOT_VER=$(cat /data/adb/ksu/version 2>/dev/null | tr -d '[:space:]')
  [ -z "$ROOT_VER" ] && ROOT_VER=$(getprop ro.kernelsu.version 2>/dev/null | tr -d '[:space:]')
  if [ -z "$ROOT_VER" ] && [ -x /data/adb/ksu/bin/ksud ]; then
    ROOT_VER=$(/data/adb/ksu/bin/ksud --version 2>/dev/null | head -n 1 | tr -d '[:space:]')
  fi
elif [ -d /data/adb/ap ] || [ -f /data/adb/apd/version ]; then
  ROOT_MGR="APatch"
  # APatch 版本: /data/adb/apd/version 或 getprop ro.apatch.version
  ROOT_VER=$(cat /data/adb/apd/version 2>/dev/null | tr -d '[:space:]')
  [ -z "$ROOT_VER" ] && ROOT_VER=$(getprop ro.apatch.version 2>/dev/null | tr -d '[:space:]')
elif [ -d /data/adb/magisk ] || [ -n "$(getprop ro.magisk.version 2>/dev/null)" ]; then
  ROOT_MGR="Magisk"
  ROOT_VER=$(getprop ro.magisk.version 2>/dev/null | tr -d '[:space:]')
  [ -z "$ROOT_VER" ] && ROOT_VER=$(cat /data/adb/magisk/version 2>/dev/null | tr -d '[:space:]')
fi

if [ "$ROOT_MGR" = "未知" ]; then
  mark WARN "未识别到 Root 管理器 (KSU/APatch/Magisk 均未检测到)"
  add_summary "[WARN] 未识别到 Root 框架"
else
  mark OK "Root 管理器: ${ROOT_MGR} ${ROOT_VER}"
  add_summary "[OK] Root 框架: ${ROOT_MGR} ${ROOT_VER}"
fi

echo "" >> "$OUT" 2>/dev/null
echo "--- 各框架目录探测 (详细) ---" >> "$OUT" 2>/dev/null
run_sh "ls -la /data/adb/ksu/ 2>/dev/null | head -10"
run_sh "ls -la /data/adb/ap/ 2>/dev/null | head -10"
run_sh "ls -la /data/adb/magisk/ 2>/dev/null | head -10"
run_sh "getprop ro.magisk.version 2>/dev/null"
run_sh "getprop ro.kernelsu.version 2>/dev/null"
run_sh "getprop ro.apatch.version 2>/dev/null"
run_sh "cat /data/adb/ksu_version 2>/dev/null"
run_sh "cat /data/adb/ksu/version 2>/dev/null"
run_sh "/data/adb/ksu/bin/ksud --version 2>/dev/null | head -1"
run_sh "cat /data/adb/apd/version 2>/dev/null"

# v4: busybox 探测详情 (三大框架 busybox 路径全覆盖)
echo "--- busybox 探测详情 (v4) ---" >> "$OUT" 2>/dev/null
echo "已选 busybox: ${BB:-(未找到)}" >> "$OUT" 2>/dev/null
echo "" >> "$OUT" 2>/dev/null
echo "逐路径探测 (用于排查 busybox 缺失):" >> "$OUT" 2>/dev/null
for cand in \
  /data/adb/ksu/bin/busybox \
  /data/adb/ksu/bin/busybox_static \
  /data/adb/ap/bin/busybox \
  /data/adb/apd/bin/busybox \
  /data/adb/magisk/busybox \
  /data/adb/magisk/.busybox/busybox \
  /system/bin/busybox \
  /system/xbin/busybox \
  /vendor/bin/busybox; do
  if [ -x "$cand" ]; then
    mark OK "找到: $cand"
  fi
done
if [ -n "$BB" ]; then
  echo "" >> "$OUT" 2>/dev/null
  echo "busybox 版本: $("$BB" 2>/dev/null | head -1)" >> "$OUT" 2>/dev/null
  BB_APPLETS=$("$BB" --list 2>/dev/null | wc -l | tr -d '[:space:]')
  mark INFO "busybox applet 数: ${BB_APPLETS:-0}"
  # 关键 applet 检查 (打包/取证依赖)
  for applet in tar gzip md5sum find xargs awk sed grep sort; do
    if bb_has "$applet"; then
      mark OK "busybox 有 applet: $applet"
    else
      mark WARN "busybox 缺 applet: $applet (将降级到系统命令)"
    fi
  done
fi
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 10. SELinux 与权限 (v2: 新增 avc denial 审计)
# ============================================================
section "10. SELinux 与权限 (含 avc denial 审计)"
SEL_MODE=$(getenforce 2>/dev/null | tr -d '[:space:]')
echo "getenforce: $SEL_MODE" >> "$OUT" 2>/dev/null
if [ "$SEL_MODE" = "Enforcing" ]; then
  mark INFO "SELinux: Enforcing (tarn 需 ksu/magisk 域权限, 出问题先查 avc denial)"
elif [ "$SEL_MODE" = "Permissive" ]; then
  mark WARN "SELinux: Permissive (仅记录不拦截, 生产环境应收紧)"
else
  mark WARN "SELinux: $SEL_MODE (异常状态)"
fi
echo "" >> "$OUT" 2>/dev/null

run_sh "id 2>/dev/null"
run_sh "ls -la /sys/power/wake_lock 2>/dev/null"
run_sh "ls -la /sys/power/wake_unlock 2>/dev/null"

# avc denial 审计 —— Android root 模块故障头号元凶 (v2 核心)
echo "--- SELinux avc denial 审计 (tarn 相关) ---" >> "$OUT" 2>/dev/null
echo "$ dmesg | grep -i 'avc.*denied' | grep -i tarn (尾部 30)" >> "$OUT" 2>/dev/null
AVC_DMESG=""
if command -v dmesg >/dev/null 2>&1 || [ -n "$BB" ]; then
  AVC_DMESG=$(bb_wrap dmesg 2>/dev/null | bb_wrap grep -iE 'avc.*denied' 2>/dev/null | bb_wrap grep -iE 'tarn|u:r:ksu|u:r:magisk' 2>/dev/null | bb_wrap tail -n 30)
fi
if [ -n "$AVC_DMESG" ]; then
  echo "$AVC_DMESG" >> "$OUT" 2>/dev/null
  AVC_CNT=$(echo "$AVC_DMESG" | bb_wrap grep -c '' 2>/dev/null | tr -d '[:space:]')
  mark FAIL "dmesg 发现 ${AVC_CNT} 条 tarn 相关 avc denial (SELinux 拦截了 tarn 的操作!)"
  add_summary "[FAIL] SELinux avc denial: ${AVC_CNT} 条 (dmesg)"
else
  mark OK "dmesg 无 tarn 相关 avc denial"
fi
echo "" >> "$OUT" 2>/dev/null

# logcat 的 avc denial (auditd)
echo "$ logcat -d -b all 2>/dev/null | grep 'avc.*denied' | grep tarn (尾部 30)" >> "$OUT" 2>/dev/null
AVC_LOGCAT=""
if command -v logcat >/dev/null 2>&1; then
  AVC_LOGCAT=$(logcat -d -b all 2>/dev/null | bb_wrap grep -iE 'avc.*denied' 2>/dev/null | bb_wrap grep -iE 'tarn' 2>/dev/null | bb_wrap tail -n 30)
fi
if [ -n "$AVC_LOGCAT" ]; then
  echo "$AVC_LOGCAT" >> "$OUT" 2>/dev/null
  AVC_LC_CNT=$(echo "$AVC_LOGCAT" | bb_wrap grep -c '' 2>/dev/null | tr -d '[:space:]')
  mark WARN "logcat 发现 ${AVC_LC_CNT} 条 tarn 相关 avc denial"
  add_summary "[WARN] SELinux avc denial: ${AVC_LC_CNT} 条 (logcat)"
else
  mark OK "logcat 无 tarn 相关 avc denial (或 logcat 不可用)"
fi
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 11. 存储与挂载 (v2: 新增 inode + 降噪)
# ============================================================
section "11. 存储与挂载 (含 inode)"
echo "--- /data 磁盘空间 ---" >> "$OUT" 2>/dev/null
run_sh "df -h /data 2>/dev/null"
echo "--- /data inode 使用 ---" >> "$OUT" 2>/dev/null
echo "$ df -i /data" >> "$OUT" 2>/dev/null
df -i /data 2>/dev/null >> "$OUT" 2>&1 || mark WARN "df -i 不可用 (busybox 不支持时降级)"
echo "" >> "$OUT" 2>/dev/null

# tarn 数据目录所在分区空间
echo "--- tarn 数据目录空间 ---" >> "$OUT" 2>/dev/null
run_sh "df -h $DATADIR 2>/dev/null"

# mount 降噪: 只取关键挂载点 (v2 改进, 原版 grep 'tarn|/data ' 噪音极大)
# v4: 完整 mount 输出另存于 system/mount.txt
echo "--- mount (关键挂载点: /data /sdcard /storage /system, 完整见 system/mount.txt) ---" >> "$OUT" 2>/dev/null
bb_wrap mount 2>/dev/null | bb_wrap grep -E ' on /(data|storage|sdcard|system) ' >> "$OUT" 2>/dev/null
echo "" >> "$OUT" 2>/dev/null

# /data 只读检测
if bb_wrap mount 2>/dev/null | bb_wrap grep -E ' on /data ' | bb_wrap grep -q 'ro,'; then
  mark FAIL "/data 挂载为只读 (无法写日志/状态/socket!)"
  add_summary "[FAIL] /data 只读"
else
  mark OK "/data 可读写"
fi

# ============================================================
# 12. 二进制与环境能力检测 (v2 新增)
# ============================================================
section "12. 二进制与环境能力检测"

# 二进制存在性 + 权限
if [ -f "$BIN" ]; then
  mark OK "二进制存在: $BIN"
  ls -la "$BIN" >> "$OUT" 2>/dev/null
else
  mark FAIL "二进制不存在: $BIN"
  add_summary "[FAIL] 二进制缺失"
fi

# 架构匹配检测
echo "--- 架构匹配 ---" >> "$OUT" 2>/dev/null
DEV_ABI=$(getprop ro.product.cpu.abi 2>/dev/null | tr -d '[:space:]')
echo "设备 ABI: $DEV_ABI" >> "$OUT" 2>/dev/null
ARCH_CHECKED=0
if [ -n "$DEV_ABI" ] && [ -x "$BIN" ]; then
  # 方案 A: 读 ELF header 的 e_machine 字段 (offset 18, 2 字节小端)
  # aarch64=0xB7(183), arm=0x28(40), x86_64=0x3E(62), x86=0x03(3)
  # 这是最可靠的方法, 不依赖 readelf 文本输出格式差异
  if command -v od >/dev/null 2>&1 || [ -n "$BB" ]; then
    # od -An -j18 -N2 (跳过18字节读2字节), tu1 输出十进制
    # od 输出形如 "183   0" (两个字节, 空格分隔), awk 取第一个即 e_machine
    ELF_MACHINE_DEC=$(bb_wrap od -An -j18 -N2 -tu1 "$BIN" 2>/dev/null | bb_wrap awk '{print $1}' 2>/dev/null | tr -d '[:space:]')
    if [ -n "$ELF_MACHINE_DEC" ]; then
      ARCH_CHECKED=1
      case "$ELF_MACHINE_DEC" in
        183) ELF_ARCH="aarch64" ;;
         40) ELF_ARCH="arm" ;;
         62) ELF_ARCH="x86_64" ;;
          3) ELF_ARCH="x86" ;;
          *) ELF_ARCH="unknown($ELF_MACHINE_DEC)" ;;
      esac
      echo "二进制 e_machine: $ELF_MACHINE_DEC ($ELF_ARCH)" >> "$OUT" 2>/dev/null
      case "$DEV_ABI" in
        arm64-v8a)
          if [ "$ELF_MACHINE_DEC" = "183" ]; then
            mark OK "arch 匹配 (设备 arm64-v8a, 二进制 aarch64)"
          else
            mark FAIL "arch 不匹配 (设备 arm64-v8a, 二进制 $ELF_ARCH)"
            add_summary "[FAIL] 二进制 arch 不匹配 ($ELF_ARCH vs arm64-v8a)"
          fi
          ;;
        armeabi*)
          if [ "$ELF_MACHINE_DEC" = "40" ]; then
            mark OK "arch 匹配 (设备 $DEV_ABI, 二进制 arm)"
          else
            mark FAIL "arch 不匹配 (设备 $DEV_ABI, 二进制 $ELF_ARCH)"
            add_summary "[FAIL] 二进制 arch 不匹配 ($ELF_ARCH vs $DEV_ABI)"
          fi
          ;;
        *)
          mark INFO "未识别的设备 ABI: $DEV_ABI (二进制 $ELF_ARCH)"
          ;;
      esac
    fi
  fi

  # 方案 B: readelf 文本解析兜底 (od 不可用时)
  # 注意: Android toybox readelf 输出 "arm64", GNU readelf 输出 "AArch64",
  # 必须同时匹配 aarch64 和 arm64, 否则误报 FAIL
  if [ "$ARCH_CHECKED" = "0" ] && command -v readelf >/dev/null 2>&1; then
    ELF_MACHINE=$(readelf -h "$BIN" 2>/dev/null | bb_wrap grep -iE 'Machine' | bb_wrap sed -E 's/.*:[[:space:]]*//')
    echo "二进制 Machine: $ELF_MACHINE" >> "$OUT" 2>/dev/null
    case "$DEV_ABI" in
      arm64-v8a)
        if echo "$ELF_MACHINE" | bb_wrap grep -qiE 'aarch64|arm64'; then
          mark OK "arch 匹配 (arm64, via readelf)"
        else
          mark FAIL "arch 不匹配 (设备 arm64, 二进制 $ELF_MACHINE)"
          add_summary "[FAIL] 二进制 arch 不匹配 ($ELF_MACHINE vs arm64)"
        fi
        ;;
      armeabi*)
        if echo "$ELF_MACHINE" | bb_wrap grep -qi 'ARM'; then
          mark OK "arch 匹配 (arm, via readelf)"
        else
          mark FAIL "arch 不匹配 (设备 arm, 二进制 $ELF_MACHINE)"
          add_summary "[FAIL] 二进制 arch 不匹配 ($ELF_MACHINE vs arm)"
        fi
        ;;
    esac
  fi

  if [ "$ARCH_CHECKED" = "0" ] && ! command -v readelf >/dev/null 2>&1; then
    mark INFO "readelf/od 均不可用, 跳过 arch 严格校验 (依赖 doctor 间接验证)"
  fi
fi
echo "" >> "$OUT" 2>/dev/null

# 动态库依赖 (readelf -d, 进程未运行时用)
echo "--- 动态库依赖 (readelf -d NEEDED) ---" >> "$OUT" 2>/dev/null
if command -v readelf >/dev/null 2>&1 && [ -f "$BIN" ]; then
  echo "$ readelf -d $BIN | grep NEEDED" >> "$OUT" 2>/dev/null
  readelf -d "$BIN" 2>/dev/null | bb_wrap grep -i 'NEEDED' >> "$OUT" 2>/dev/null
  echo "" >> "$OUT" 2>/dev/null
  # 检查依赖的 so 是否存在
  echo "--- 依赖 so 存在性检查 ---" >> "$OUT" 2>/dev/null
  for so in $(readelf -d "$BIN" 2>/dev/null | bb_wrap grep -i 'NEEDED' | bb_wrap sed -E "s/.*\[//; s/\].*//" 2>/dev/null); do
    FOUND=0
    for libdir in /system/lib64 /system/lib /apex/com.android.runtime/lib64 /vendor/lib64 /vendor/lib; do
      if [ -f "$libdir/$so" ]; then
        FOUND=1
        break
      fi
    done
    if [ "$FOUND" = "1" ]; then
      mark OK "依赖 $so: 已找到"
    else
      mark FAIL "依赖 $so: 未找到 (二进制将无法启动!)"
      add_summary "[FAIL] 缺失动态库: $so"
    fi
  done
else
  mark INFO "readelf 不可用, 跳过动态库依赖检查 (进程在跑时见第2章 /proc/maps)"
fi
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 13. WebUI 与通信端点 (v2: 新增端口监听 + socket 连通性)
# ============================================================
section "13. WebUI 与通信端点 (含端口监听 + socket 连通性)"

# 读取 WebUI 配置
WEBUI_ENABLED=$(get_setting "enabled" "true")
WEBUI_BIND=$(get_setting "bind" "127.0.0.1")
WEBUI_PORT=$(get_setting "port" "8080")
echo "WebUI 配置: enabled=$WEBUI_ENABLED bind=$WEBUI_BIND port=$WEBUI_PORT" >> "$OUT" 2>/dev/null

# Unix socket 存在性
SOCK="$DATADIR/run/tarn.sock"
echo "--- Unix socket ---" >> "$OUT" 2>/dev/null
run_sh "ls -la $SOCK 2>/dev/null"

# socket 连通性测试 (v2 核心: 不只 ls, 实际 connect)
echo "--- socket 连通性测试 ---" >> "$OUT" 2>/dev/null
if [ -S "$SOCK" ]; then
  if [ -n "$DPID" ] && kill -0 "$DPID" 2>/dev/null; then
    # 进程存活 + socket 存在 = 大概率可用
    mark OK "socket 存在且 daemon 存活 (pid=$DPID)"
  else
    mark WARN "socket 存在但 daemon 未运行 (可能是孤儿 socket, 需清理)"
    add_summary "[WARN] 孤儿 socket (daemon 未运行但 socket 残留)"
  fi
  # 尝试用 nc 实际连接 (toybox/busybox nc)
  # 注意: 不能只 echo "" | nc -U, 因为 WebUI 是 HTTP 服务, 空输入不是合法请求,
  # daemon 会直接关闭连接, nc 返回非0 — 这是假阴性 (socket 其实可达)。
  # 正确做法: 发一个合法的 HTTP/1.0 GET 请求, 看是否有 HTTP 响应。
  if command -v nc >/dev/null 2>&1 || { [ -n "$BB" ] && "$BB" --list 2>/dev/null | bb_wrap grep -q '^nc$'; }; then
    echo "$ printf 'GET / HTTP/1.0\\r\\nHost: localhost\\r\\n\\r\\n' | nc -U $SOCK -w 3 (HTTP 连通性测试)" >> "$OUT" 2>/dev/null
    HTTP_RESP=$(printf 'GET / HTTP/1.0\r\nHost: localhost\r\n\r\n' 2>/dev/null | bb_wrap nc -U "$SOCK" -w 3 2>/dev/null | bb_wrap head -n 3)
    if echo "$HTTP_RESP" | bb_wrap grep -qiE '^HTTP/[0-9]'; then
      mark OK "nc -U HTTP 响应正常 (socket 可达, daemon 响应 HTTP)"
      echo "$HTTP_RESP" >> "$OUT" 2>/dev/null
    elif [ -n "$HTTP_RESP" ]; then
      mark WARN "nc -U 有响应但非 HTTP 格式 (socket 可达但响应异常)"
      echo "$HTTP_RESP" >> "$OUT" 2>/dev/null
      add_summary "[WARN] WebUI socket 响应异常"
    else
      # 响应为空 — 但 daemon 存活 + socket 存在, 可能是 nc 版本不支持 -U 或超时太短
      mark WARN "nc -U 无响应 (socket 文件在但无 HTTP 响应; 可能 nc 不支持 -U 或 daemon 不在 Unix socket 上服务 HTTP)"
      add_summary "[WARN] WebUI socket 无 HTTP 响应 (但 daemon 存活, 优先看 TCP 端口检测)"
    fi
  else
    mark INFO "nc 不可用, 跳过实际连接测试 (看下方 TCP 端口检测)"
  fi
else
  if [ "$WEBUI_ENABLED" = "true" ]; then
    mark WARN "socket 不存在 (WebUI enabled 但未创建 socket)"
    add_summary "[WARN] WebUI socket 未创建"
  fi
fi
echo "" >> "$OUT" 2>/dev/null

# token 文件
TOKEN="$DATADIR/run/token"
if [ -f "$TOKEN" ]; then
  TOK_SZ=$(wc -c < "$TOKEN" 2>/dev/null | tr -d '[:space:]')
  mark OK "token 文件存在 (${TOK_SZ} 字节, 内容已脱敏, 不打包进包)"
else
  mark WARN "token 文件不存在 (WebUI 鉴权将失败)"
  add_summary "[WARN] token 文件缺失"
fi
echo "" >> "$OUT" 2>/dev/null

# TCP 端口监听检测 (v2 核心: 读 /proc/$PID/net/tcp)
echo "--- WebUI TCP 端口监听检测 ---" >> "$OUT" 2>/dev/null
if [ "$WEBUI_ENABLED" = "true" ]; then
  # 端口转 hex (8080 -> 1F90)
  PORT_HEX=$(printf '%04X' "$WEBUI_PORT" 2>/dev/null)
  echo "检测端口: $WEBUI_PORT (0x$PORT_HEX) LISTEN 状态=0A" >> "$OUT" 2>/dev/null

  TCP_FOUND=0
  # 优先从 daemon 进程的 /proc/$PID/net/tcp 查
  if [ -n "$DPID" ] && [ -r "/proc/$DPID/net/tcp" ]; then
    echo "$ cat /proc/$DPID/net/tcp | grep ':$PORT_HEX 00000000:0000 0A'" >> "$OUT" 2>/dev/null
    TCP_LINE=$(bb_wrap grep -E ":${PORT_HEX} 00000000:0000 0A" "/proc/$DPID/net/tcp" 2>/dev/null)
    if [ -n "$TCP_LINE" ]; then
      TCP_FOUND=1
      echo "$TCP_LINE" >> "$OUT" 2>/dev/null
    fi
  fi
  # 兜底: 全局 /proc/net/tcp
  if [ "$TCP_FOUND" = "0" ] && [ -r /proc/net/tcp ]; then
    echo "$ cat /proc/net/tcp | grep ':$PORT_HEX 00000000:0000 0A' (全局兜底)" >> "$OUT" 2>/dev/null
    TCP_LINE=$(bb_wrap grep -E ":${PORT_HEX} 00000000:0000 0A" /proc/net/tcp 2>/dev/null)
    if [ -n "$TCP_LINE" ]; then
      TCP_FOUND=1
      echo "$TCP_LINE" >> "$OUT" 2>/dev/null
    fi
  fi

  if [ "$TCP_FOUND" = "1" ]; then
    mark OK "WebUI 端口 $WEBUI_PORT 正在监听 (LISTEN)"
    add_summary "[OK] WebUI 端口 $WEBUI_PORT 监听中"
  else
    mark FAIL "WebUI 端口 $WEBUI_PORT 未监听 (enabled=true 但无 LISTEN, WebUI 无法访问!)"
    add_summary "[FAIL] WebUI 端口 $WEBUI_PORT 未监听"
  fi
else
  mark INFO "WebUI 未启用 (enabled=false), 跳过端口检测"
fi
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 14. 启动链路检测 (v2 新增)
# ============================================================
section "14. 启动链路检测"

# Magisk/KSU 模块通过 service.sh 在 late_start 阶段拉起
# 检测框架是否正确配置了 tarn 的启动
echo "--- 模块目录完整性 ---" >> "$OUT" 2>/dev/null
for f in module.prop service.sh; do
  if [ -f "$MODDIR/$f" ]; then
    mark OK "$MODDIR/$f 存在"
  else
    mark FAIL "$MODDIR/$f 缺失 (启动链路不完整!)"
    add_summary "[FAIL] 启动链路: $f 缺失"
  fi
done

# service.d 软链检测 (部分用户自定义启动顺序)
echo "--- service.d / post-fs-data.d ---" >> "$OUT" 2>/dev/null
run_sh "ls -la /data/adb/service.d/ 2>/dev/null | grep -i tarn"
run_sh "ls -la /data/adb/post-fs-data.d/ 2>/dev/null | grep -i tarn"

# boot_failures 计数
BOOT_FAIL="$DATADIR/run/boot_failures"
if [ -f "$BOOT_FAIL" ]; then
  BFC=$(cat "$BOOT_FAIL" 2>/dev/null | tr -d '[:space:]')
  case "$BFC" in
    *[!0-9]*|"") BFC=0 ;;
  esac
  if [ "$BFC" -ge 3 ] 2>/dev/null; then
    mark WARN "boot_failures=$BFC (>=3, service.sh 已进入安全模式跳过自启!)"
    add_summary "[WARN] 安全模式: 连续 $BFC 次启动失败"
  elif [ "$BFC" -gt 0 ] 2>/dev/null; then
    mark WARN "boot_failures=$BFC (有启动失败记录, 未达安全模式阈值)"
  else
    mark OK "boot_failures=0 (无启动失败记录)"
  fi
else
  mark OK "无 boot_failures 记录 (首次运行或已清零)"
fi
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 15. doctor 自检
# ============================================================
section "15. doctor 自检"
if [ -x "$BIN" ]; then
  run_cmd "$BIN" doctor
  # doctor 输出含 [OK] 则认为通过
  if "$BIN" doctor 2>/dev/null | bb_wrap grep -q '\[OK\]'; then
    add_summary "[OK] doctor 自检通过"
  else
    add_summary "[WARN] doctor 自检可能有异常"
  fi
else
  mark FAIL "二进制不可执行, 无法运行 doctor"
  add_summary "[FAIL] doctor 无法运行"
fi

# ============================================================
# 16. 内核日志 (dmesg, 尾部)
# ============================================================
section "16. 内核日志 (dmesg, 尾部)"
run_sh "dmesg 2>/dev/null | tail -50"

# ============================================================
# 17. 诊断摘要 (v2 新增)
# ============================================================
section "17. 诊断摘要"
echo "$SUMMARY" >> "$OUT" 2>/dev/null

# 统计问题数
FAIL_CNT=$(echo "$SUMMARY" | bb_wrap grep -c '\[FAIL\]' 2>/dev/null | tr -d '[:space:]')
WARN_CNT=$(echo "$SUMMARY" | bb_wrap grep -c '\[WARN\]' 2>/dev/null | tr -d '[:space:]')
OK_CNT=$(echo "$SUMMARY" | bb_wrap grep -c '\[OK\]' 2>/dev/null | tr -d '[:space:]')
echo "----------------------------------------" >> "$OUT" 2>/dev/null
echo "  OK: ${OK_CNT:-0}  WARN: ${WARN_CNT:-0}  FAIL: ${FAIL_CNT:-0}" >> "$OUT" 2>/dev/null
echo "----------------------------------------" >> "$OUT" 2>/dev/null
if [ "${FAIL_CNT:-0}" -gt 0 ]; then
  echo "  >> 存在 $FAIL_CNT 项严重问题, 请优先排查 [FAIL] 项" >> "$OUT" 2>/dev/null
elif [ "${WARN_CNT:-0}" -gt 0 ]; then
  echo "  >> 存在 $WARN_CNT 项警告, 建议关注 [WARN] 项" >> "$OUT" 2>/dev/null
else
  echo "  >> 各项检测正常" >> "$OUT" 2>/dev/null
fi
echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 18. 原文件收集 (v4 新增: 原样副本打包, 便于取证)
# ============================================================
section "18. 原文件收集 (打包到 configs/ logs/ state/ system/)"

# --- 用户配置 ---
echo "--- 收集用户配置 ---" >> "$OUT" 2>/dev/null
collect_file "$DATADIR/config/settings.toml" "$STAGE/configs/settings.toml"
collect_file "$DATADIR/config/blacklist.toml" "$STAGE/configs/blacklist.toml"
collect_file "$DATADIR/config/whitelist.toml" "$STAGE/configs/whitelist.toml"
mark OK "settings/blacklist/whitelist.toml 已收集到 configs/"

# 规则文件: 打包原样副本到 configs/rules/ (取证需要), 但 diagnostic.txt 不转储内容
# 诊断文本第 4 章只列规则清单 (文件名/行数/字节), 内容完整副本在 configs/rules/
if [ -d "$DATADIR/rules" ]; then
  RULE_COLLECT=0
  for rf in "$DATADIR/rules"/*.toml "$DATADIR/rules"/*.txt; do
    [ -f "$rf" ] || continue
    RULE_COLLECT=$((RULE_COLLECT + 1))
    collect_file "$rf" "$STAGE/configs/rules/$(basename "$rf")"
  done
  if [ "$RULE_COLLECT" -gt 0 ]; then
    mark OK "收集 $RULE_COLLECT 个规则文件到 configs/rules/ (原样副本, 诊断文本不转储内容)"
  else
    mark WARN "rules/ 目录存在但无 .toml / .txt 文件"
  fi
else
  mark WARN "rules/ 目录不存在, 跳过规则收集"
fi

# --- 日志 ---
echo "--- 收集日志 ---" >> "$OUT" 2>/dev/null
# boot.log: 超 512KB 只取尾部 (避免撑爆压缩包)
if [ -f "$DATADIR/logs/boot.log" ]; then
  BOOT_SZ=$(wc -c < "$DATADIR/logs/boot.log" 2>/dev/null | tr -d '[:space:]')
  case "$BOOT_SZ" in ''|*[!0-9]*) BOOT_SZ=0 ;; esac
  if [ "$BOOT_SZ" -gt 512000 ]; then
    bb_wrap tail -c 512000 "$DATADIR/logs/boot.log" > "$STAGE/logs/boot.log" 2>/dev/null
    {
      echo "source: $DATADIR/logs/boot.log"
      echo "note: 原文件 ${BOOT_SZ} 字节, 超过 512000 阈值, 已截取尾部 512000 字节"
      ls -la "$DATADIR/logs/boot.log" 2>/dev/null
    } > "$STAGE/logs/boot.log.meta" 2>/dev/null
    mark INFO "boot.log 原始 ${BOOT_SZ} 字节, 截取尾部 512KB 到 logs/boot.log"
  else
    collect_file "$DATADIR/logs/boot.log" "$STAGE/logs/boot.log"
    mark OK "boot.log 全量收集 (${BOOT_SZ} 字节)"
  fi
else
  echo "(boot.log 不存在)" > "$STAGE/logs/boot.log.missing"
  mark WARN "boot.log 不存在"
fi

# tarn.log: 超 3000 行只取尾部 (运行日志通常很大)
if [ -f "$DATADIR/logs/tarn.log" ]; then
  TARN_LN=$(wc -l < "$DATADIR/logs/tarn.log" 2>/dev/null | tr -d '[:space:]')
  TARN_SZ=$(wc -c < "$DATADIR/logs/tarn.log" 2>/dev/null | tr -d '[:space:]')
  case "$TARN_LN" in ''|*[!0-9]*) TARN_LN=0 ;; esac
  case "$TARN_SZ" in ''|*[!0-9]*) TARN_SZ=0 ;; esac
  if [ "$TARN_LN" -gt 3000 ]; then
    bb_wrap tail -n 3000 "$DATADIR/logs/tarn.log" > "$STAGE/logs/tarn.log" 2>/dev/null
    {
      echo "source: $DATADIR/logs/tarn.log"
      echo "note: 原文件 ${TARN_LN} 行 ${TARN_SZ} 字节, 超过 3000 行阈值, 已截取尾部 3000 行"
      ls -la "$DATADIR/logs/tarn.log" 2>/dev/null
    } > "$STAGE/logs/tarn.log.meta" 2>/dev/null
    mark INFO "tarn.log 原始 ${TARN_LN} 行, 截取尾部 3000 行到 logs/tarn.log"
  else
    collect_file "$DATADIR/logs/tarn.log" "$STAGE/logs/tarn.log"
    mark OK "tarn.log 全量收集 (${TARN_LN} 行)"
  fi
else
  echo "(tarn.log 不存在)" > "$STAGE/logs/tarn.log.missing"
  mark WARN "tarn.log 不存在"
fi

# debug-sh.err (notify.rs 写的 debug.sh 启动 stderr, 排查脚本自身错误的关键)
if [ -f "$DATADIR/logs/debug-sh.err" ]; then
  collect_file "$DATADIR/logs/debug-sh.err" "$STAGE/logs/debug-sh.err"
  mark OK "debug-sh.err 已收集 (debug.sh 上次启动的 stderr)"
fi

# --- 状态文件 ---
echo "--- 收集状态 ---" >> "$OUT" 2>/dev/null
if [ -f "$DATADIR/state.json" ]; then
  collect_file "$DATADIR/state.json" "$STAGE/state/state.json"
  mark OK "state.json 全量收集"
else
  mark WARN "state.json 不存在"
fi

# run/ 目录元信息 (socket/pid/token 是运行时文件, 只记录元信息不复制内容)
if [ -d "$DATADIR/run" ]; then
  ls -laR "$DATADIR/run/" > "$STAGE/state/run-dir-listing.txt" 2>/dev/null
  mark OK "run/ 目录元信息已收集到 state/run-dir-listing.txt"
  # pidfile (只是个数字, 安全复制)
  if [ -f "$DATADIR/run/tarn.pid" ]; then
    cat "$DATADIR/run/tarn.pid" > "$STAGE/state/tarn.pid" 2>/dev/null
  fi
  # boot_failures (计数, 安全)
  if [ -f "$DATADIR/run/boot_failures" ]; then
    cat "$DATADIR/run/boot_failures" > "$STAGE/state/boot_failures" 2>/dev/null
  fi
  # token: 脱敏, 只记录元信息 (鉴权 token 不能泄露)
  if [ -f "$DATADIR/run/token" ]; then
    TOK_SZ2=$(wc -c < "$DATADIR/run/token" 2>/dev/null | tr -d '[:space:]')
    {
      echo "token 文件存在, 大小 ${TOK_SZ2} 字节"
      echo "note: 鉴权 token 已脱敏, 内容不打包 (避免泄露)"
      ls -la "$DATADIR/run/token" 2>/dev/null
    } > "$STAGE/state/token.meta" 2>/dev/null
  fi
else
  mark WARN "run/ 目录不存在"
fi

# --- 模块脚本 (取证: 出问题时可对比设备上的脚本与官方版) ---
echo "--- 收集模块脚本 ---" >> "$OUT" 2>/dev/null
collect_file "$MODDIR/module.prop" "$STAGE/meta/module.prop"
collect_file "$MODDIR/service.sh" "$STAGE/meta/service.sh"
collect_file "$MODDIR/uninstall.sh" "$STAGE/meta/uninstall.sh"
mark OK "模块脚本已收集到 meta/"

echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 19. 系统快照独立成文 (v4 新增: 便于单独分析)
# ============================================================
section "19. 系统快照 (独立成文于 system/)"

# SELinux avc denial — dmesg 全量 (诊断文本里只取 tarn 相关, 这里存全量 avc)
if command -v dmesg >/dev/null 2>&1 || [ -n "$BB" ]; then
  bb_wrap dmesg 2>/dev/null | bb_wrap grep -iE 'avc.*denied' > "$STAGE/system/selinux-avc-dmesg.txt" 2>/dev/null
  AVC_D_LINES=$(wc -l < "$STAGE/system/selinux-avc-dmesg.txt" 2>/dev/null | tr -d '[:space:]')
  case "$AVC_D_LINES" in ''|*[!0-9]*) AVC_D_LINES=0 ;; esac
  if [ "$AVC_D_LINES" -gt 0 ]; then
    mark INFO "dmesg 全部 avc denial: ${AVC_D_LINES} 条 → system/selinux-avc-dmesg.txt"
  else
    rm -f "$STAGE/system/selinux-avc-dmesg.txt" 2>/dev/null
    echo "(dmesg 无 avc denial)" > "$STAGE/system/selinux-avc-dmesg.txt" 2>/dev/null
    mark OK "dmesg 无 avc denial"
  fi
fi

# SELinux avc denial — logcat 全量
if command -v logcat >/dev/null 2>&1; then
  logcat -d -b all 2>/dev/null | bb_wrap grep -iE 'avc.*denied' > "$STAGE/system/selinux-avc-logcat.txt" 2>/dev/null
  AVC_L_LINES=$(wc -l < "$STAGE/system/selinux-avc-logcat.txt" 2>/dev/null | tr -d '[:space:]')
  case "$AVC_L_LINES" in ''|*[!0-9]*) AVC_L_LINES=0 ;; esac
  if [ "$AVC_L_LINES" -gt 0 ]; then
    mark INFO "logcat 全部 avc denial: ${AVC_L_LINES} 条 → system/selinux-avc-logcat.txt"
  else
    rm -f "$STAGE/system/selinux-avc-logcat.txt" 2>/dev/null
    echo "(logcat 无 avc denial 或 logcat 不可用)" > "$STAGE/system/selinux-avc-logcat.txt" 2>/dev/null
    mark OK "logcat 无 avc denial"
  fi
fi

# dmesg 尾部 200 行 (内核日志, 排查崩溃/驱动问题)
if command -v dmesg >/dev/null 2>&1 || [ -n "$BB" ]; then
  bb_wrap dmesg 2>/dev/null | bb_wrap tail -n 200 > "$STAGE/system/dmesg-tail.txt" 2>/dev/null
  mark OK "dmesg 尾部 200 行 → system/dmesg-tail.txt"
fi

# mount 全量 (诊断文本里只取关键挂载点, 这里存全量备份)
bb_wrap mount 2>/dev/null > "$STAGE/system/mount.txt" 2>/dev/null
if [ -s "$STAGE/system/mount.txt" ]; then
  mark OK "mount 全量 → system/mount.txt"
fi

# getprop 全量 (所有系统属性, 排查设备/兼容性问题)
if command -v getprop >/dev/null 2>&1; then
  getprop 2>/dev/null > "$STAGE/system/getprop.txt" 2>/dev/null
  if [ -s "$STAGE/system/getprop.txt" ]; then
    mark OK "getprop 全量 → system/getprop.txt"
  fi
fi

# ps 全量 (进程列表, 排查冲突进程)
if [ -n "$BB" ]; then
  "$BB" ps 2>/dev/null > "$STAGE/system/ps.txt" 2>/dev/null
else
  ps -A 2>/dev/null > "$STAGE/system/ps.txt" 2>/dev/null
fi
if [ -s "$STAGE/system/ps.txt" ]; then
  mark OK "ps 进程列表 → system/ps.txt"
fi

echo "" >> "$OUT" 2>/dev/null

# ============================================================
# 20. 元信息文件 (v4 新增)
# ============================================================
{
  echo "========================================================"
  echo "  Tarn 诊断包元信息"
  echo "========================================================"
  echo "生成时间:   $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  echo "时间戳:     $TS"
  echo "模块目录:   $MODDIR"
  echo "数据目录:   $DATADIR"
  echo "脚本版本:   debug.sh v5"
  echo "busybox:    ${BB:-(未找到, 部分检测已降级)}"
  if [ -n "$BB" ]; then
    echo "busybox 版本: $("$BB" 2>/dev/null | head -1)"
    echo "busybox applet 数: $("$BB" --list 2>/dev/null | wc -l | tr -d '[:space:]')"
  fi
  echo "Root 框架:  ${ROOT_MGR:-未知} ${ROOT_VER}"
  echo "设备型号:   $(getprop ro.product.model 2>/dev/null)"
  echo "设备品牌:   $(getprop ro.product.brand 2>/dev/null)"
  echo "厂商:       $(getprop ro.product.manufacturer 2>/dev/null)"
  echo "Android:    $(getprop ro.build.version.release 2>/dev/null) (SDK $(getprop ro.build.version.sdk 2>/dev/null))"
  echo "设备 ABI:   $(getprop ro.product.cpu.abi 2>/dev/null)"
  echo "硬件:       $(getprop ro.hardware 2>/dev/null)"
  echo "SELinux:    $(getenforce 2>/dev/null)"
  echo "内核:       $(uname -r 2>/dev/null)"
  echo "--------------------------------------------------------"
  echo "包内文件结构:"
  echo "  diagnostic.txt         诊断文本 (17 章检测结果 + 摘要, 不含规则内容)"
  echo "  configs/               用户配置原样副本 (settings/blacklist/whitelist/rules/*.toml)"
  echo "  logs/                  日志副本 (boot.log / tarn.log / debug-sh.err)"
  echo "  state/                 state.json + run/ 元信息 + pidfile + boot_failures"
  echo "  system/                系统快照 (dmesg / mount / getprop / ps / avc denial)"
  echo "  meta/                  模块脚本 (module.prop/service.sh/uninstall.sh) + 本元信息"
  echo "  MANIFEST.txt           全文件清单 + 大小"
  echo "========================================================"
  echo "诊断摘要: OK=${OK_CNT:-0} WARN=${WARN_CNT:-0} FAIL=${FAIL_CNT:-0}"
} > "$STAGE/meta/meta.txt" 2>/dev/null

# ============================================================
# 21. MANIFEST (v4 新增: 包内文件清单)
# ============================================================
{
  echo "Tarn 诊断包 MANIFEST"
  echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  echo "时间戳:   $TS"
  echo "========================================================"
  echo "文件清单 (字节数  路径):"
  echo "========================================================"
  # 逐文件列大小 (用 find + wc -c, 不依赖 du -b)
  TOTAL_BYTES=0
  FILE_COUNT=0
  ( cd "$STAGE" 2>/dev/null && find . -type f 2>/dev/null | sort | while read -r f; do
    sz=$(wc -c < "$f" 2>/dev/null | tr -d '[:space:]')
    case "$sz" in ''|*[!0-9]*) sz=0 ;; esac
    printf '%10s  %s\n' "$sz" "$f"
  done )
  echo "========================================================"
  FILE_COUNT=$(find "$STAGE" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
  case "$FILE_COUNT" in ''|*[!0-9]*) FILE_COUNT=0 ;; esac
  echo "文件数: $FILE_COUNT"
} > "$STAGE/MANIFEST.txt" 2>/dev/null

# ============================================================
# 22. 打包 tar.gz (v4 核心)
# ============================================================
section "22. 打包 tar.gz"

# 诊断文本至此基本完结, 写入打包前状态
echo "正在打包 tar.gz ..." >> "$OUT" 2>/dev/null
echo "暂存目录: $STAGE_ROOT" >> "$OUT" 2>/dev/null
echo "目标包:   $ARCHIVE" >> "$OUT" 2>/dev/null
PRE_FILE_COUNT=$(find "$STAGE" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
case "$PRE_FILE_COUNT" in ''|*[!0-9]*) PRE_FILE_COUNT=0 ;; esac
echo "包内文件数: $PRE_FILE_COUNT" >> "$OUT" 2>/dev/null
echo "" >> "$OUT" 2>/dev/null

PACKED=0
ARC_SZ=0
if create_targz "$ARCHIVE" "$STAGE_ROOT" "$STAGE_NAME"; then
  ARC_SZ=$(wc -c < "$ARCHIVE" 2>/dev/null | tr -d '[:space:]')
  case "$ARC_SZ" in ''|*[!0-9]*) ARC_SZ=0 ;; esac
  if [ "$ARC_SZ" -gt 0 ] 2>/dev/null; then
    mark OK "打包成功: $ARCHIVE (${ARC_SZ} 字节, 含 ${PRE_FILE_COUNT} 个文件)"
    # 注: 不调 add_summary (第17章摘要已落盘, 再加无效); 打包结果经 mark + stdout 传达
    PACKED=1
    # 打包成功, 删除暂存目录 (内容已进压缩包)
    rm -rf "$STAGE_ROOT" 2>/dev/null
  else
    mark FAIL "打包产物为空 (tar 命令异常)"
    PACKED=0
  fi
else
  mark FAIL "打包失败! create_targz 返回非 0"
  mark INFO "可能原因: busybox 无 tar applet 且系统无 tar / 磁盘满 / 权限不足"
  mark INFO "暂存目录保留以供手动查看: $STAGE_ROOT"
  # 写失败标记, 便于后续排查
  echo "PACK_FAILED at $(date 2>/dev/null), stage=$STAGE_ROOT" > "$LOGDIR/.debug-pack-failed-${TS}" 2>/dev/null
  PACKED=0
fi

# ============================================================
# 23. 清理旧档案 (v4)
# ============================================================
section "23. 清理旧档案"
KEEP_DAYS=7

# 旧版 .txt (v3 及更早残留) — 兼容清理
TXT_DEL=$(find "$LOGDIR" -maxdepth 1 -name 'debug-*.txt' -mtime +${KEEP_DAYS} -type f 2>/dev/null | wc -l | tr -d '[:space:]')
[ -n "$TXT_DEL" ] && [ "$TXT_DEL" -gt 0 ] 2>/dev/null && {
  find "$LOGDIR" -maxdepth 1 -name 'debug-*.txt' -mtime +${KEEP_DAYS} -type f -delete 2>/dev/null
  mark INFO "清理 ${KEEP_DAYS} 天前的 debug-*.txt: $TXT_DEL 份"
}

# .tar.gz (v4 产物) — 7 天保留
GZ_DEL=$(find "$LOGDIR" -maxdepth 1 -name 'debug-*.tar.gz' -mtime +${KEEP_DAYS} -type f 2>/dev/null | wc -l | tr -d '[:space:]')
[ -n "$GZ_DEL" ] && [ "$GZ_DEL" -gt 0 ] 2>/dev/null && {
  find "$LOGDIR" -maxdepth 1 -name 'debug-*.tar.gz' -mtime +${KEEP_DAYS} -type f -delete 2>/dev/null
  mark INFO "清理 ${KEEP_DAYS} 天前的 debug-*.tar.gz: $GZ_DEL 份"
}

# crash throttle: 最多保留 20 份 tar.gz, 超出删最旧
ARC_CNT=$(ls -1 "$LOGDIR"/debug-*.tar.gz 2>/dev/null | wc -l | tr -d '[:space:]')
case "$ARC_CNT" in ''|*[!0-9]*) ARC_CNT=0 ;; esac
if [ "$ARC_CNT" -gt 20 ] 2>/dev/null; then
  DEL_N=$((ARC_CNT - 20))
  ls -1t "$LOGDIR"/debug-*.tar.gz 2>/dev/null | bb_wrap tail -n "$DEL_N" | while read -r old; do
    rm -f "$old" 2>/dev/null
  done
  mark INFO "崩溃循环节流: 删除 $DEL_N 份最旧 tar.gz (保留最近 20 份)"
fi

# 同时对 .txt 做节流 (兼容旧版, 最多 20 份)
TXT_CNT=$(ls -1 "$LOGDIR"/debug-*.txt 2>/dev/null | wc -l | tr -d '[:space:]')
case "$TXT_CNT" in ''|*[!0-9]*) TXT_CNT=0 ;; esac
if [ "$TXT_CNT" -gt 20 ] 2>/dev/null; then
  DEL_N2=$((TXT_CNT - 20))
  ls -1t "$LOGDIR"/debug-*.txt 2>/dev/null | bb_wrap tail -n "$DEL_N2" | while read -r old; do
    rm -f "$old" 2>/dev/null
  done
fi

# 当前档案数
NOW_GZ=$(ls -1 "$LOGDIR"/debug-*.tar.gz 2>/dev/null | wc -l | tr -d '[:space:]')
NOW_TXT=$(ls -1 "$LOGDIR"/debug-*.txt 2>/dev/null | wc -l | tr -d '[:space:]')
mark INFO "当前档案: ${NOW_GZ:-0} 个 tar.gz + ${NOW_TXT:-0} 个 txt (保留 ${KEEP_DAYS} 天, 上限 20 份)"

echo "" >> "$OUT" 2>/dev/null
echo "========================================================" >> "$OUT" 2>/dev/null
echo "  诊断完成 (v5 tar.gz 打包)" >> "$OUT" 2>/dev/null
echo "========================================================" >> "$OUT" 2>/dev/null
if [ "$PACKED" = "1" ]; then
  echo "  输出包: $ARCHIVE" >> "$OUT" 2>/dev/null
  echo "  大小:   ${ARC_SZ} 字节" >> "$OUT" 2>/dev/null
  echo "  文件数: ${PRE_FILE_COUNT}" >> "$OUT" 2>/dev/null
  echo "  解压:   tar xzf debug-${TS}.tar.gz" >> "$OUT" 2>/dev/null
else
  echo "  打包失败, 暂存目录: $STAGE_ROOT" >> "$OUT" 2>/dev/null
  echo "  可手动查看: ls -laR $STAGE_ROOT" >> "$OUT" 2>/dev/null
fi
echo "========================================================" >> "$OUT" 2>/dev/null

# ============================================================
# 完成: 结果打印到 stdout (供 WebUI / 终端显示)
# ============================================================
if [ "$PACKED" = "1" ]; then
  echo "=========================================="
  echo "  Tarn 诊断包已生成 (v5)"
  echo "=========================================="
  echo "  路径:   $ARCHIVE"
  echo "  大小:   ${ARC_SZ} 字节"
  echo "  文件数: ${PRE_FILE_COUNT}"
  echo "  时间:   $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
  echo "=========================================="
  echo "  包内结构:"
  echo "    diagnostic.txt    诊断文本 (17 章检测结果 + 摘要, 不含规则内容)"
  echo "    configs/          用户配置原样副本 (settings/blacklist/whitelist/rules/*.toml)"
  echo "    logs/             日志副本 (boot.log / tarn.log / debug-sh.err)"
  echo "    state/            state.json + run/ 元信息"
  echo "    system/           系统快照 (dmesg/mount/getprop/ps/avc denial)"
  echo "    meta/             模块脚本 + 环境元信息"
  echo "    MANIFEST.txt      文件清单"
  echo "=========================================="
  echo "  解压命令: tar xzf debug-${TS}.tar.gz"
  echo "  诊断摘要: OK=${OK_CNT:-0} WARN=${WARN_CNT:-0} FAIL=${FAIL_CNT:-0}"
  echo "=========================================="
else
  echo "=========================================="
  echo "  Tarn 诊断打包失败"
  echo "=========================================="
  echo "  暂存目录: $STAGE_ROOT"
  echo "  可手动查看: ls -laR $STAGE_ROOT"
  echo "  失败标记: $LOGDIR/.debug-pack-failed-${TS}"
  echo "=========================================="
fi

exit 0
