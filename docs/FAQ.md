# 常见问题 (FAQ)

> 找不到答案？请先搜索 [Issues](https://github.com/linjoin/Tarn/issues)，仍无结果可 [提交新 Issue](https://github.com/linjoin/Tarn/issues/new)。

---

## 目录

- [安装与使用](#安装与使用)
- [清理规则](#清理规则)
- [定时任务](#定时任务)
- [WebUI](#webui)
- [性能与功耗](#性能与功耗)
- [安全与隐私](#安全与隐私)
- [许可证相关](#许可证相关)

---

## 安装与使用

### Q: Tarn 支持哪些设备？

- **架构**：仅支持 `arm64-v8a`（不支持 x86 / armeabi-v7a）
- **Android 版本**：Android 9.0 (API 28) 及以上
- **Root 框架**：Magisk 或 KernelSU（APatch 理论兼容，未测试）
- **内核**：5.10+ 可启用 io_uring 加速（低版本自动回退，不影响功能）

### Q: 如何安装 Tarn？

1. 从 [Releases](https://github.com/linjoin/Tarn/releases) 下载 `tarn-vX.Y.Z-versionCode.zip`（例：`tarn-v0.9.0-74.zip`）
2. 打开 Magisk / KernelSU 管理器 → 模块 → 从本地安装 → 选择 zip
3. 重启设备
4. 重启后 daemon 自动启动

详见 [README.md#安装](../README.md#安装)。

### Q: 安装后如何验证？

```bash
su
/data/adb/modules/tarn/tarn doctor
```

`doctor` 会检查二进制完整性、配置、daemon 状态、WebUI 端口、token 等。

### Q: 如何卸载？

在 Magisk / KernelSU 管理器中移除模块，重启即可。或：

```bash
su
/data/adb/modules/tarn/uninstall.sh
reboot
```

卸载会清除 `/data/adb/tarn/` 下的所有数据（配置、日志、状态）。

### Q: 升级会丢失配置吗？

不会。升级只替换 `module/tarn` 二进制和脚本，`/data/adb/tarn/config/` 下的用户配置保留。但建议升级前备份配置：

```bash
cp -r /data/adb/tarn/config /sdcard/tarn-config-backup
```

### Q: Tarn 是开源的吗？

**不是。** Tarn 是闭源专有软件，采用 TPL-2.0 协议，仅以编译后二进制形式分发。详见 [LICENSE_NOTICE.md](./LICENSE_NOTICE.md)。

---

## 清理规则

### Q: 为什么我的规则跑了但没删任何文件？

最常见的原因：

1. **mode 选错了**：`*cache` 配 `delete_files` 模式啥都不删（因为 `*cache` 只匹配目录，目录被跳过）。改成 `clear_dirs` 模式。
2. **通配符写错了**：`*cache` 不匹配 `com.foo/cache`（因为 `*` 不跨 `/`）。改成 `**/cache` 或 `*/cache`。
3. **older_than_days 太大**：所有文件都不到 N 天。调小或设 0。
4. **路径不在白名单**：`path` 必须在 `ALLOWED_ROOTS` 内。

用 `--dry-run` 查看 audit 日志的 `reason` 字段定位原因：

```bash
/data/adb/modules/tarn/tarn run --dry-run --json --rule <rule_id>
```

### Q: "清 App 缓存"应该怎么写？

**正确写法**：
- path 填 App 数据目录（如 `/data/data/com.tencent.mm`）
- mode 选 `clear_dirs`（清空目录内容，保留目录本身）
- glob 填 `*cache`（匹配 cache 目录）

详见 [清理规则要求.md#三种处理模式](./清理规则要求.md#一三种处理模式先看这个)。

### Q: `*` 和 `**` 有什么区别？

- `*` 匹配**任意一段路径名**（不含 `/`）
- `**` 匹配**任意多段路径**（含 0 段，可跨 `/`）

例：
- `*cache` 匹配 `cache`、`mycache`，**不匹配** `com.foo/cache`
- `**/cache` 匹配 `cache`、`com.foo/cache`、`a/b/c/cache`

### Q: 如何防止误删重要文件？

1. **配置白名单**：银行/支付类 App 用 `protect_package` 整个保护
2. **全局数据库保护**：`protect_ext` 保护 .db / .db-wal 等
3. **近期文件保护**：`protect_mtime within_days=7`
4. **规则加 older_than_days**：只删 N 天前的旧文件
5. **先 dry-run**：执行前预览将删除的文件列表

### Q: 如何批量导入社区规则？

1. WebUI：规则页 → 导入 → 选择 .toml 文件（可多选）
2. 命令行：`cat module/rules/community/*.toml >> /data/adb/tarn/config/blacklist.toml`
3. 导入后先 dry-run：`tarn run --dry-run --json`

### Q: 规则文件放在哪里？

- **用户规则**：`/data/adb/tarn/config/blacklist.toml`
- **社区规则包**：`module/rules/`（模块自带，可导入）
- **示例**：见 `examples/blacklist.example.toml`

### Q: 误删了文件怎么办？

Tarn 的删除是物理 unlink，**无法撤销**。立即操作：

1. 停止 daemon：`kill $(cat /data/adb/tarn/run/tarn.pid)`
2. 查看审计轨迹：`cat /data/adb/tarn/state.json`（`recent_runs` 字段）
3. 查看删除记录：`grep "delete" /data/adb/tarn/logs/tarn.log`
4. **下次务必先 dry-run！**

---

## 定时任务

### Q: 定时清理会穿透 Doze 模式吗？

**会。** Tarn 使用内核 `timerfd` + `CLOCK_BOOTTIME_ALARM` 实现定时，不依赖 Android 的 AlarmManager，能穿透 Doze 省电模式，在设定时间准确触发。

### Q: cron 表达式怎么写？

5 字段：`分 时 日 月 周`

| 表达式 | 含义 |
|---|---|
| `0 3 * * *` | 每天 3:00 |
| `*/30 * * * *` | 每 30 分钟 |
| `0 */6 * * *` | 每 6 小时 |
| `0 3 * * 1` | 每周一 3:00 |
| `0 0 1 * *` | 每月 1 日 0:00 |

### Q: 定时任务不触发怎么办？

排查步骤：
1. 检查 `on` 数组是否包含 `"cron"`
2. 检查 `cron_expr` 是否 5 字段
3. 检查 daemon 是否在运行：`ps | grep tarn`
4. 检查 `min_free_mb` 是否限制（空间够就不跑）
5. 检查日志：`tail -50 /data/adb/tarn/logs/tarn.log`

### Q: 可以同时设置多个触发方式吗？

可以。`on` 是数组，可多选：

```toml
[rule.trigger]
on = ["manual", "boot", "cron"]
cron_expr = "0 3 * * *"
```

这条规则可手动触发、开机触发、每天 3:00 定时触发。

---

## WebUI

### Q: WebUI 默认地址是什么？

`http://127.0.0.1:8080`（设备本机浏览器访问）。

### Q: WebUI 的 token 在哪？

```bash
cat /data/adb/tarn/run/token
```

token 文件权限 0600，仅 root 可读。

### Q: 如何远程访问 WebUI？

**不推荐**远程访问，有安全风险。如必须远程：

1. 编辑 `/data/adb/tarn/config/settings.toml`：
   ```toml
   [webui]
   bind = "0.0.0.0"
   port = 8080
   ```
2. 热重载：`/data/adb/modules/tarn/tarn reload`
3. **务必妥善保管 token**，避免在公共网络暴露

### Q: WebUI 改了规则不生效？

WebUI 保存规则时会自动触发 reload。如未生效：
- 命令行手动 reload：`/data/adb/modules/tarn/tarn reload`
- 检查 daemon 日志：`tail -50 /data/adb/tarn/logs/tarn.log`

### Q: WebUI 打不开/拒绝连接？

1. 确认 daemon 在运行：`ps | grep tarn`
2. 确认端口监听：`netstat -tlnp | grep 8080`
3. 确认 token 文件存在：`ls -la /data/adb/tarn/run/token`
4. 重启 daemon：`/data/adb/modules/tarn/tarn daemon --stop && /data/adb/modules/tarn/tarn daemon`

---

## 性能与功耗

### Q: Tarn 会很耗电吗？

不会。Tarn 的低功耗设计：
- **nice 19 + 绑小核**：CPU 占用 <1.5%，不抢前台资源
- **自适应限速**：前台忙才限速，空闲全速
- **IO 批量化**：io_uring / getdents64 / unlinkat 合并调用，减少 syscall 开销
- **清理任务耗时短**：日常清理通常 1-5 秒完成

### Q: 清理时设备会卡顿吗？

不会。Tarn 默认开启低功耗模式，清理任务运行在小核 + nice 19，不干扰前台使用。如仍感觉卡顿，可调小并发：

```toml
[engine]
parallel_workers = 2           # 限制并发数
io_throttle_ops_per_sec = 100  # 每秒最多删 100 个文件
```

### Q: io_uring 是什么？怎么知道是否启用？

io_uring 是 Linux 5.1+ 的异步 IO 接口，Tarn 用它批量 stat 文件（比 lstat 快数倍）。

- 内核 5.10+ 自动启用
- 低版本自动回退到 lstat，不影响功能
- 查看是否启用：`tarn doctor` 会检测

### Q: 二进制有多大？

约 3.6MB（arm64 ELF）。采用 `opt-level=z + LTO + strip` 优化体积。

---

## 安全与隐私

### Q: Tarn 会上传我的数据吗？

**不会。** Tarn 不包含任何网络上传代码，不连接任何服务器，不上传任何数据。所有运行数据在设备本地。

详见 [SECURITY.md#无网络上传](./SECURITY.md#-无网络上传)。

### Q: 如何确认 Tarn 没有偷偷联网？

```bash
# 检查 tarn 进程的网络连接
netstat -tunp | grep tarn

# 抓包分析
tcpdump -i any -w /sdcard/tarn.pcap host not 127.0.0.1
# 用 Wireshark 打开分析
```

### Q: token 泄露了怎么办？

1. 立即停止 daemon：`kill $(cat /data/adb/tarn/run/tarn.pid)`
2. 重置 token：
   ```bash
   rm /data/adb/tarn/run/token
   /data/adb/modules/tarn/tarn daemon   # 重启会生成新 token
   ```
3. 确认 `bind` 不是 `0.0.0.0`（远程访问请改回 `127.0.0.1`）

### Q: 可以信任非官方渠道的 Tarn 副本吗？

**不可以。** 非官方渠道的副本可能被植入恶意代码、后门、挖矿程序。请只从 [官方 Releases](https://github.com/linjoin/Tarn/releases) 下载。

---

## 许可证相关

### Q: Tarn 是开源的吗？

**不是。** Tarn 是闭源专有软件（Proprietary Software），采用 TPL-2.0 协议。详见 [LICENSE.txt](../LICENSE.txt)。

### Q: 为什么不开源？

详见 [LICENSE_NOTICE.md#为什么不开源](./LICENSE_NOTICE.md#为什么不开源)。

### Q: 可以把 Tarn 转发给别人吗？

**不可以。** TPL-2.0 禁止再分发。请引导他人从 [官方 Releases](https://github.com/linjoin/Tarn/releases) 下载。

### Q: 可以修改 Tarn 自用吗？

可以**在本地修改自用**（不分发）。但禁止：
- 分发修改后的版本
- 逆向工程二进制
- 修改后再分发

### Q: 可以把 Tarn 打包进我的 ROM 吗？

**不可以**，除非获得商业授权。详见 [LICENSE_NOTICE.md#商业授权](./LICENSE_NOTICE.md#商业授权)。

### Q: 如何申请商业授权？

通过 GitHub Issue 联系版权人 linjoin，说明：
- 你的公司/产品信息
- 拟使用场景
- 预计部署规模

---

## 没找到答案？

- 📖 查看完整文档：[docs/](./)
- 🔍 搜索现有 Issue：[GitHub Issues](https://github.com/linjoin/Tarn/issues)
- 🐛 提交 Bug：[Bug Report](https://github.com/linjoin/Tarn/issues/new?template=bug_report.md)
- 💡 功能建议：[Feature Request](https://github.com/linjoin/Tarn/issues/new?template=feature_request.md)
- 🧹 贡献规则：[Rule Request](https://github.com/linjoin/Tarn/issues/new?template=rule_request.md)

---

Copyright (c) 2025 linjoin. All Rights Reserved.
