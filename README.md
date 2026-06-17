# Tarn - 系统级文件治理引擎

> 系统级、高并发、低功耗、防雪崩的 Android 文件清理框架  
> Rust 内核 + Magisk 模块壳 + timerfd Doze 穿透 + Rayon 并行扫描

## 功能介绍

Tarn 是一个面向 Android root 用户的系统级文件治理引擎, 核心特性:

### 引擎能力
- **Rust 内核**: 编译为单二进制 (~2.6MB stripped), aarch64-linux-android 目标
- **双引擎**: Rayon (CPU 并行遍历) + Tokio (异步 IO)
- **timerfd + CLOCK_BOOTTIME_ALARM**: 内核级定时, 穿透 Doze 模式, 无需 root 服务常驻
- **低功耗调优**: nice / ionice / cpu_affinity 绑小核 / oom_score_adj=-900
- **getdents64 + unlinkat**: 直接 syscall, 比 `std::fs` 快 3-5 倍

### 安全机制
- **硬编码保护**: 永远不删 `/data/adb` `/system` `/vendor` `/product` `/proc` `/sys`
- **6 种白名单**: path×3 (prefix/glob/exact) + package + ext + mtime
- **风险分级**: low / medium / high / dangerous, 默认拒绝 high+ (需 `--force`)
- **两阶段执行**: 先标记 (dry-run) 后删除, 可中断
- **防雪崩**: 事前校验 + dry-run + force_protect + adaptive_rate_limit

### 配置体系
- **三文件配置**: `settings.toml` / `blacklist.toml` / `whitelist.toml` (TOML 格式)
- **社区规则包**: `rules/*.toml` 可订阅更新
- **热重载**: `tarn reload` 或 SIGHUP 信号, 不打断当前任务

### WebUI
- **axum 0.7** 后端 + **Vue3 单文件**前端 (无构建工具, CDN 加载)
- **Token 鉴权**: Bearer header 或 URL `?token=` 兜底 (兼容 EventSource)
- **SSE 实时日志**: Server-Sent Events 推送运行日志
- **5 大功能页**: Dashboard / Rules / Clean / Logs / Config

---

## 安装方法

### 前置要求
- Android 9+ (API 28+), 推荐 Android 11+
- arm64-v8a 架构 (其他架构需自行编译)
- Magisk 24+ (或 KernelSU / APatch 兼容层)

### 安装步骤
1. 下载 `tarn-vX.Y.Z.zip` 到设备
2. 打开 Magisk app → 模块 → 从本地安装 → 选择 zip
3. 等待 `customize.sh` 执行完成
4. 重启设备
5. 重启后 `service.sh` 自动启动 daemon (late_start service 模式)

### 验证安装
```sh
# 完整性校验
$MODDIR/verify.sh

# doctor 自检
$MODDIR/tarn doctor

# 查看版本
$MODDIR/tarn version
```

> `$MODDIR` 通常是 `/data/adb/modules/tarn`

---

## 配置说明

### 目录结构
```
/data/adb/tarn/
├── config/              # 配置目录 (0700)
│   ├── settings.toml    # 引擎全局设置
│   ├── blacklist.toml   # 清理规则 (规则包)
│   └── whitelist.toml   # 保护规则 (6 种白名单)
├── rules/               # 社区规则包 (订阅式)
│   └── default.toml     # 内置默认规则包
├── logs/                # 日志目录
│   ├── tarn.log         # daemon 运行日志 (JSON 格式, 轮转)
│   └── boot.log         # 启动脚本日志
├── run/                 # 运行时目录
│   └── tarn.pid         # daemon pidfile (防多开)
├── trash/               # 回收站 (若启用)
├── state.json           # 累计统计 + 最近运行记录 (原子写)
├── token                # WebUI 鉴权 token (自动生成)
└── tarn.sock            # Unix socket (Phase 4)
```

### 三文件配置 schema

完整 schema 见 [docs/CONFIG-SPEC.md](https://github.com/tarn/tarn/blob/main/docs/CONFIG-SPEC.md)。

#### `settings.toml` 关键字段
```toml
[engine]
parallel_workers = 0              # 0=自动(CPU核数)
cpu_affinity = [0, 1, 2, 3]       # 绑小核 (big.LITTLE)
use_getdents = true
use_ionice = true
use_nice = true

[schedule]
boot_delay_sec = 60               # 开机后延迟执行 (避免 IO 争用)
boot_enabled = true
min_interval_min = 360            # 同一规则最小间隔 (防频繁触发)

[run]
default_risk = "low"              # 默认仅跑 low 风险
default_dry_run = false
force_protect = true              # 强制启用硬编码保护
avoid_foreground_app = true       # 跳过前台 App 数据

[webui]
enabled = true
bind = "127.0.0.1"                # 仅本机访问
port = 8080

[trash]
enabled = false                   # 默认直接删, 不入回收站
ttl_days = 7
```

#### `blacklist.toml` 规则结构
```toml
[[rule]]
id = "wechat-cache"               # 唯一 ID
name = "微信缓存清理"
desc = "清理微信 cache 目录, 不动聊天数据"
enabled = true
priority = 50                     # 数字越大优先级越高
risk = "low"                      # low / medium / high / dangerous
category = "social"
tags = ["wechat"]

[rule.trigger]
on = ["manual", "boot"]           # manual / boot / cron:<expr> / event
min_interval_min = 60             # 最小间隔

[[rule.targets]]
path = "/data/data/com.tencent.mm/cache"
glob = "**/*"
action = "delete"                 # delete / move_to_trash
older_than_days = 3
exclude = ["**/voice2/**"]        # 排除项
```

#### `whitelist.toml` 保护结构
```toml
# 1. 路径保护
[[protect]]
match_type = "prefix"             # prefix / glob / exact
path = "/data/data/com.tencent.mm/MicroMsg"

# 2. 包名保护
[[protect_package]]
package = "com.bank.app"
reason = "银行类 App 不清"

# 3. 扩展名保护
[[protect_ext]]
extensions = ["db", "db-journal", "db-wal"]
scope = "global"                  # global / 具体路径

# 4. 修改时间保护
[[protect_mtime]]
within_days = 7
scope = "global"
reason = "保护 7 天内修改的文件"
```

---

## 命令列表

```sh
# 基础
tarn version              # 版本
tarn doctor               # 自检 (root / timerfd / wakelock / 配置)
tarn list                 # 列出所有规则
tarn list --enabled-only  # 仅启用的
tarn show <rule_id>       # 规则详情
tarn stats                # 累计统计 + 最近运行

# 执行
tarn run                              # 默认 manual 触发
tarn run --dry-run --json             # 试运行 + JSON 输出
tarn run --rule wechat-cache          # 仅跑指定规则
tarn run --trigger boot               # 模拟 boot 触发
tarn run --force                      # 允许 high/dangerous 规则

# 启停
tarn daemon              # 启动 daemon (前台, 由 service.sh setsid detach)
tarn reload              # 热重载配置 (向 daemon 发 SIGHUP)
tarn webui               # 启动 WebUI 服务
tarn webui --port 9090   # 指定端口

# 配置
tarn config list         # 列出所有设置
tarn config get <key>    # 读取某项
tarn config set <key> <value>  # 写入

# 日志
tarn log --tail 50       # 查看最近 50 行日志
```

---

## 安全机制

### 永远不会删除的路径 (硬编码, 不可关闭)
- `/data/adb` - Magisk / Tarn 自身数据
- `/system` `/vendor` `/product` `/apex` - 系统分区
- `/proc` `/sys` `/dev` - 内核伪文件系统
- `/data/data/<pkg>/databases` - 所有 App 数据库 (除非规则显式排除)
- `/sdcard/Android/data/<pkg>` - App 外部数据 (谨慎)

### 6 种白名单 (whitelist.toml)
1. `protect` (prefix) - 路径前缀匹配
2. `protect` (glob) - glob 模式匹配
3. `protect` (exact) - 精确路径匹配
4. `protect_package` - 按 App 包名保护整个数据目录
5. `protect_ext` - 按扩展名保护 (全局或作用域)
6. `protect_mtime` - 按修改时间保护 (近期文件不动)

### 防雪崩设计
- **事前校验**: 配置加载时即检查规则合法性
- **dry-run**: 默认建议先 `tarn run --dry-run --json` 查看将删什么
- **force_protect**: 即使规则说删, 白名单永远赢
- **adaptive_rate_limit**: 自动限速避免 IO 风暴

---

## FAQ

### Q1: daemon 不启动?
1. 检查 `/data/adb/tarn/logs/boot.log` 中 service.sh 的输出
2. 检查 `/data/adb/tarn/logs/tarn.log` 中 daemon 的输出
3. 运行 `$MODDIR/verify.sh` 完整性校验
4. 运行 `$MODDIR/tarn doctor` 自检
5. 常见原因:
   - 二进制架构不匹配 (仅支持 arm64-v8a)
   - 配置文件 TOML 语法错误
   - 权限问题 (检查 0700/0600)

### Q2: 多个 daemon 实例同时运行?
不可能。pidfile + flock 双重防多开:
- 启动时 `sysutil::lock_pidfile()` flock 加锁, 失败立即退出
- service.sh 检测到旧 pidfile 会先 `kill -TERM` + 等 12s + 必要时 `kill -KILL`

### Q3: 重启后 daemon 会延迟启动?
是的, `service.sh` 在 `late_start service` 阶段执行 (zygote 已起, 系统基本就绪)。
然后 daemon 内部还有 `boot_delay_sec=60` 的 boot 触发延迟, 避免 IO 争用。

### Q4: 误删了重要文件怎么办?
1. 立即停止 daemon: `kill $(cat /data/adb/tarn/run/tarn.pid)`
2. 检查 `state.json` 中的 `recent_runs` 审计轨迹
3. 检查 `logs/tarn.log` 中的删除记录
4. 如启用了 `trash` (回收站), 文件在 `/data/adb/tarn/trash/`
5. **建议**: 永远先用 `tarn run --dry-run --json` 查看将删什么

### Q5: 如何禁用某条规则?
```sh
# 方法 1: 编辑 blacklist.toml, 设置 enabled = false
# 方法 2: 命令行
$MODDIR/tarn disable <rule_id>

# 方法 3: WebUI 中点击规则行的开关
```

### Q6: 如何添加自定义规则?
1. 编辑 `/data/adb/tarn/config/blacklist.toml`, 添加 `[[rule]]` 段
2. 或创建 `/data/adb/tarn/rules/my-rules.toml` (社区规则包格式)
3. 重载: `$MODDIR/tarn reload` (无需重启 daemon)

### Q7: WebUI token 在哪?
首次启动 daemon 时自动生成到 `/data/adb/tarn/token` (0600 权限)。
```sh
cat /data/adb/tarn/token
```

### Q8: 如何完全卸载?
1. Magisk app 中移除 Tarn 模块 (调用 `uninstall.sh` 杀 daemon)
2. 重启设备
3. (可选) 彻底清理数据: `su -c 'rm -rf /data/adb/tarn'`

### Q9: 支持 KernelSU / APatch 吗?
理论上兼容, 因为脚本只用 POSIX sh + Magisk 标准变量。但未做完整测试, 推荐 Magisk 24+。

### Q10: 可以同时安装其他清理工具吗?
可以, 但建议:
- 不要让其他工具清理 `/data/adb/tarn/` (会丢失配置和 state)
- 在其他工具的排除列表中加入 Tarn 监控的路径, 避免重复清理

---

## 技术细节

### daemon 启动流程 (service.sh)
```
1. 读取 $MODDIR (脚本所在目录)
2. 检查 pidfile:
   - 存在 → 读 OLD_PID
   - kill -0 校验存活
   - /proc/$OLD_PID/cmdline 校验是 tarn (防 PID 复用)
   - SIGTERM + 等 12s (daemon 优雅退出)
   - 仍存活 → SIGKILL
3. setsid nohup "$BIN" daemon </dev/null >>log 2>&1 &
   - setsid: 新建会话, 脱离控制终端
   - nohup: 忽略 SIGHUP (双保险)
   - </dev/null: 防 stdin 阻塞
4. 轮询等待 pidfile 出现 (最多 5s)
5. 写入 boot.log, 退出 (daemon 已 detach 后台运行)
```

### daemon 主循环 (Rust 内核)
```
1. flock pidfile (防多开)
2. apply_low_power: nice + ionice + cpu_affinity
3. set_oom_score_adj(-900) (防 OOM kill)
4. install_signal_handlers: SIGHUP(reload) / SIGTERM(优雅退出) / SIGINT(立即退出)
5. boot 延迟 (timerfd 可被打断)
6. boot 触发清理 (acquire wakelock 5min 兜底)
7. 主循环:
   a. 计算 cron 下次触发
   b. timerfd arm
   c. poll(timerfd, signal_fd)
   d. 到点 → wakelock → 执行 → save state → release wakelock
   e. SIGHUP → reload config (不打断)
   f. SIGTERM → drain → save → remove pidfile → exit
```

### 文件权限
| 路径 | 权限 | 说明 |
|------|------|------|
| `/data/adb/tarn/` | 0700 | 数据根目录, 仅 root |
| `/data/adb/tarn/config/*.toml` | 0600 | 配置文件, 仅 root 读写 |
| `/data/adb/tarn/run/tarn.pid` | 0600 | pidfile, 仅 root |
| `/data/adb/tarn/token` | 0600 | WebUI token, 仅 root |
| `/data/adb/modules/tarn/tarn` | 0755 | 二进制, root 拥有, 全可执行 |
| `/data/adb/modules/tarn/*.sh` | 0755 | 脚本, root 拥有, 全可执行 |

---

