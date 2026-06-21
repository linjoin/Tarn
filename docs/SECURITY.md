# 安全策略

> 本文件说明 Tarn 的安全设计、漏洞报告流程与隐私保护承诺。

---

## 🔒 安全设计

### 1. 无网络上传

Tarn **不包含任何网络上传代码**。运行过程中：

- ❌ 不连接版权人或第三方服务器
- ❌ 不发送遥测数据
- ❌ 不上报使用统计
- ❌ 不下载远程规则（除非用户主动通过 WebUI 导入）

所有运行数据（日志、状态、统计）均存放在设备本地 `/data/adb/tarn/`。

### 自查方法

```bash
# 检查 tarn 进程的网络连接
netstat -tunp | grep tarn

# 抓包确认无外联（运行 5 分钟后分析）
tcpdump -i any -w /sdcard/tarn.pcap host not 127.0.0.1
# 用 Wireshark 打开 tarn.pcap 检查

# 检查文件权限
ls -la /data/adb/tarn/
ls -la /data/adb/tarn/logs/
ls -la /data/adb/tarn/run/
```

### 2. WebUI 鉴权与绑定

- **token 鉴权**：访问 WebUI 必须提供 token，token 存放于 `/data/adb/tarn/run/token`（权限 0600）
- **默认本地绑定**：WebUI 默认监听 `127.0.0.1:8080`，不对外暴露
- **远程访问需手动开启**：如需远程访问，须编辑 `settings.toml` 将 `bind` 改为 `0.0.0.0`，**此时务必妥善保管 token**

### 3. 路径白名单

清理规则的 `path` 字段必须位于 `ALLOWED_ROOTS` 内，防止误删系统文件：

```
/data/data                    # App 内部数据
/sdcard                       # 外置存储
/storage/emulated/0           # 外置存储（同上）
/data/local/tmp               # 临时目录
/data/anr                     # ANR 日志
/data/system/dropbox          # 系统 dropbox 日志
/data/adb/tarn/rules          # 规则包目录
```

不在白名单内的路径会被拒绝执行。

### 4. 硬编码保护

以下路径**永远不删除**，即使白名单为空、规则配置错误：

- `/data/adb` — Magisk / Tarn 自身数据
- `/system` `/vendor` `/product` `/apex` — 系统分区
- `/proc` `/sys` `/dev` — 内核伪文件系统

### 5. dry-run 预览

执行清理前可用 `--dry-run` 预览将删除的文件列表，不真删：

```bash
/data/adb/modules/tarn/tarn run --dry-run --json
```

输出包含 `would_free_bytes` 和 audit 日志，可逐条检查。

### 6. 6 层白名单保护

| 层 | 类型 | 说明 |
|---|---|---|
| 1 | 硬编码保护 | 系统关键路径永不删除 |
| 2 | `ALLOWED_ROOTS` | 规则路径必须在白名单内 |
| 3 | `protect` | 路径前缀/通配符保护 |
| 4 | `protect_package` | 按包名保护整个 App |
| 5 | `protect_ext` | 按扩展名保护（如 .db） |
| 6 | `protect_mtime` | 按修改时间保护（如 7 天内） |

白名单**永远优先**于清理规则，命中保护即跳过。

---

## 🛡️ 隐私保护

### 数据收集范围

Tarn 在运行过程中**仅在设备本地**处理以下数据：

| 数据类型 | 用途 | 存储位置 | 是否上传 |
|---|---|---|---|
| 文件路径 | 匹配清理规则 | 内存（临时） | ❌ 否 |
| 文件大小 | 统计释放空间 | 内存（临时） | ❌ 否 |
| 文件修改时间 | older_than_days 过滤 | 内存（临时） | ❌ 否 |
| 运行日志 | 排查问题 | `/data/adb/tarn/logs/` | ❌ 否 |
| 状态文件 | 记录最近运行 | `/data/adb/tarn/state.json` | ❌ 否 |
| token | WebUI 鉴权 | `/data/adb/tarn/run/token` | ❌ 否 |

### 用户责任

- Tarn 运行需 root 权限，请确保你对所使用设备拥有合法 root 权限
- 在处理涉及他人个人信息的设备上使用 Tarn 时，应确保已取得合法授权
- WebUI token 请妥善保管，避免在公共网络环境暴露管理端口
- 如不再使用 Tarn，可通过 `uninstall.sh` 完整卸载，所有数据会从 `/data/adb/tarn/` 清除

### 合规声明

Tarn 的设计符合《中华人民共和国网络安全法》《数据安全法》《个人信息保护法》要求：
- 不收集用户个人信息
- 不上传任何数据
- 数据所有权归设备所有者

---

## 🐞 报告安全漏洞

### 不要公开 Issue

**安全漏洞请勿通过公开 Issue 报告！** 请按以下流程私密报告，避免被恶意利用。

### 报告方式

1. **首选**：在 GitHub 创建 **private** security advisory（仓库 Security 标签页 → Report a vulnerability）
2. **备选**：在仓库新建一个 Issue 并 @ 维护者，仅说明“发现安全问题，请私下联系”，不要在 Issue 中描述漏洞细节

### 报告内容

请提供：

- 漏洞描述（什么问题、影响范围）
- 复现步骤（具体操作）
- 影响版本（`tarn --version`）
- 你的环境（设备、Android 版本、Root 框架）
- 建议的修复方向（可选）
- 你的联系方式（用于反馈进度）

### 响应流程

| 阶段 | 时间 | 动作 |
|---|---|---|
| 确认收到 | 48 小时内 | 维护者确认收到报告 |
| 初步评估 | 7 天内 | 评估漏洞严重性与影响范围 |
| 修复开发 | 视严重性 | 开发修复方案 |
| 发布修复 | 修复完成后 | 随下一个版本发布，或紧急发布补丁 |
| 公开披露 | 修复发布后 30 天 | 在 Release Notes 中公开致谢 |

### 报告原则

- ✅ 请给我们合理的时间修复（至少 30 天，高危至少 90 天）
- ✅ 报告前请确认是真实漏洞而非误用
- ✅ 不要在公开渠道讨论漏洞细节
- ❌ 不要利用漏洞攻击其他用户
- ❌ 不要索取漏洞赏金（Tarn 是个人项目，无赏金预算，但会在 Release Notes 致谢）

---

## ⚠️ 使用风险提示

### Tarn 是高风险系统级工具

Tarn 具有**文件删除功能**，运行在 root 权限下，属高风险系统级工具。使用前请注意：

1. **务必备份**：使用前请备份重要数据
2. **先 dry-run**：每条新规则都先 `--dry-run` 预览
3. **配置白名单**：银行/支付类 App 用 `protect_package` 保护
4. **审慎评估规则**：不理解的规则不要启用
5. **从官方渠道下载**：非官方渠道的副本可能被植入恶意代码

### 不承担责任的情形

根据 [LICENSE.txt](../LICENSE.txt) 第十章、第十一章，以下情形版权人不承担责任：

- 未按文档要求配置、使用本软件导致的损失
- 用户修改二进制/脚本后引入的缺陷
- 从非官方渠道获取的副本导致的问题
- 第三方组件或第三方规则导致的问题
- 用户违反协议或适用法律所致后果

---

## 📞 联系方式

- **安全漏洞报告**：[GitHub Private Security Advisory](https://github.com/linjoin/Tarn/security/advisories/new)
- **通用问题**：[GitHub Issues](https://github.com/linjoin/Tarn/issues)
- **项目仓库**：https://github.com/linjoin/Tarn

---

Copyright (c) 2025 linjoin. All Rights Reserved.
