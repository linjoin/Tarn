<div align="center">

# Tarn

### 系统级、高并发、低功耗、防雪崩的 Android 文件治理引擎

**Rust 内核 · Magisk/KernelSU 模块 · 穿透 Doze 定时清理**

[![License](https://img.shields.io/badge/license-TPL--2.0%20Proprietary-red.svg)](./LICENSE.txt)
[![Platform](https://img.shields.io/badge/platform-Android%20arm64--v8a-green.svg)](#系统要求)
[![Min Android](https://img.shields.io/badge/min--android-9.0%20(API%2028)-blueviolet.svg)](#系统要求)
[![Latest](https://img.shields.io/badge/version-v0.9.0-orange.svg)](https://github.com/linjoin/Tarn/releases)

</div>

---

> ⚠️ **闭源专有软件声明**
>
> 本项目为**闭源专有软件（Proprietary Software）**，仅以编译后的二进制模块形式分发，**不提供源代码**。
> 使用本软件即视为您已阅读并接受 [《Tarn 专有软件许可协议》(TPL-2.0)](./LICENSE.txt) 全部条款。
>
> - ❌ **不开放源代码** · 不接受源代码 PR
> - ❌ **禁止再分发** · 请只从本仓库 Release 下载
> - ❌ **禁止逆向工程** · 禁止修改二进制
> - ✅ **个人/内部非商业免费使用**
> - ✅ **欢迎提交 Bug 报告与规则建议**
>
> 商业使用须另行申请授权，详见 [LICENSE_NOTICE.md](./docs/LICENSE_NOTICE.md)。

---

## 目录

- [✨ 特性](#-特性)
- [📊 与同类工具对比](#-与同类工具对比)
- [📱 系统要求](#-系统要求)
- [📥 安装](#-安装)
- [🚀 快速开始](#-快速开始)
- [⚙️ 配置](#️-配置)
- [🧹 清理规则](#-清理规则)
- [🖥️ WebUI](#️-webui)
- [🔧 命令行](#-命令行)
- [📦 项目结构](#-项目结构)
- [❓ FAQ](#-faq)
- [🛡️ 安全](#️-安全)
- [📄 许可证](#-许可证)
- [🙏 致谢](#-致谢)

---

## ✨ 特性

### 🏗️ 系统级架构

- **Rust 内核 + POSIX shell 壳**：Magisk/KernelSU 模块，开机自启 daemon，系统级权限
- **双引擎**：Rayon（CPU 并行遍历）+ Tokio（异步 IO 调度），充分利用多核
- **单二进制多子命令**：`tarn run / webui / daemon / doctor / reload / trigger ...`

### ⚡ 高性能

- **io_uring 批量 stat**（内核 5.10+ 自动启用，低版本回退 lstat）
- **getdents64 直读目录**，绕过 std::fs 开销
- **unlinkat 合并调用**，减少路径解析开销
- **opt-level=z + LTO + strip**，二进制仅 3.6MB
- **批量 unlink**，单批最多 500 文件合并 syscall

### 🔋 低功耗

- **nice 19 + CPU 绑小核**：CPU 占用 <1.5%，不抢前台资源
- **自适应限速**：前台忙才限速，空闲全速
- **timerfd + CLOCK_BOOTTIME_ALARM**：内核级定时，**穿透 Doze 模式**，不依赖 Android AlarmManager

### 🛡️ 防雪崩

- **6 层白名单保护**：路径前缀 / 路径通配符 / 包名 / 扩展名 / 修改时间 / 硬编码
- **dry-run 预览**：先扫描统计，不真删，确认后再执行
- **older_than_days 兜底**：只删 N 天前的旧文件，保护热数据
- **路径白名单 ALLOWED_ROOTS**：规则只能清理允许的根目录，防止误删系统文件
- **原子写状态文件**：JSON + 临时文件 rename，防写坏

### 🧹 智能清理

- **三种处理模式**：删文件 / 清空目录 / 删整个目录（适配不同场景）
- **globset DFA 匹配**：`*` 不跨 `/`，`**` 跨 `/`，语义符合 POSIX shell 直觉
- **多 target 规则**：一条规则可清理多个目标
- **空目录清理**：删完文件后可选清理空目录，支持三态覆盖
- **71 条社区规则包**：覆盖 50+ 主流 App，开箱即用

### 🖥️ WebUI 管理

- **axum + token 鉴权**：TCP 端口 + Unix socket 双通道
- **小白友好表单**：快捷按钮填路径，实时校验，不用懂通配符也能用
- **实时状态**：当前任务、历史记录、释放空间统计
- **规则导入导出**：支持 .toml 规则包批量导入

---

## 📊 与同类工具对比

| 特性 | Tarn | SD Maid SE | 基础清理模块 | 系统自带清理 |
|---|---|---|---|---|
| 运行级别 | **系统级 (root)** | 用户级 (SAF) | 系统级 (root) | 用户级 |
| 定时穿透 Doze | **✅ 内核 timerfd** | ❌ 依赖 AlarmManager | ❌ | ❌ |
| 并行清理 | **✅ Rayon 多核** | ✅ | ❌ | ❌ |
| 低功耗绑核 | **✅ nice 19 + 小核** | ❌ | ❌ | ❌ |
| 自定义规则 | **✅ TOML + glob** | ✅ | ❌ 固定规则 | ❌ |
| 规则社区包 | **✅ 71 条 / 50+ App** | ❌ | 少量 | ❌ |
| 空目录清理 | **✅ 三态覆盖** | ✅ | ❌ | ❌ |
| dry-run 预览 | **✅** | ✅ | ❌ | ❌ |
| WebUI 管理 | **✅** | ✅ (App) | ❌ | ❌ |
| 开源 | ❌ 闭源 | ✅ | 视项目 | ❌ |

---

## 📱 系统要求

| 项目 | 要求 |
|---|---|
| 设备架构 | **arm64-v8a**（不支持 x86 / armeabi-v7a） |
| Android 版本 | **Android 9.0 (API 28) 及以上** |
| Root 框架 | **Magisk** 或 **KernelSU**（APatch 理论兼容，未测试） |
| 内核版本 | 5.10+ 可启用 io_uring（低版本自动回退） |
| 存储空间 | 安装后约 8MB（含二进制 + 脚本 + 规则） |

---

## 📥 安装

### 方式一：Magisk/KernelSU 模块安装（推荐）

1. 从 [Releases](https://github.com/linjoin/Tarn/releases) 下载最新 `tarn-vX.Y.Z-versionCode.zip`
   > 📌 命名格式说明：`tarn-vX.Y.Z-versionCode.zip`，其中 `X.Y.Z` 为语义化版本号，`versionCode` 为单调递增的整数版本号（用于 Magisk/KernelSU 模块升级判定）。
   > 例如：`tarn-v0.9.0-74.zip`
2. 打开 Magisk / KernelSU 管理器
3. 模块 → 从本地安装 → 选择下载的 zip
4. 安装完成后**重启设备**
5. 重启后 daemon 自动启动，WebUI 默认在 `http://127.0.0.1:8080`

### 方式二：命令行安装（进阶）

```bash
# 通过 adb 或终端
su
magisk --install-module /sdcard/Download/tarn-v0.9.0-74.zip
reboot
```

### 验证安装

重启后执行：

```bash
su
/data/adb/modules/tarn/tarn doctor
```

`doctor` 命令会检查：
- ✅ 二进制完整性
- ✅ 配置文件存在性
- ✅ daemon 运行状态
- ✅ WebUI 端口监听
- ✅ token 可读性
- ✅ 内核版本与 io_uring 支持

---

## 🚀 快速开始

### 1. 访问 WebUI

```bash
# 获取 token
cat /data/adb/tarn/run/token

# 浏览器访问（设备本机）
# http://127.0.0.1:8080
# 输入 token 登录
```

### 2. 首次 dry-run 预览

```bash
su
/data/adb/modules/tarn/tarn run --dry-run --json
```

输出示例：

```json
{
  "files_scanned": 12453,
  "files_deleted": 0,
  "files_would_delete": 3421,
  "freed_bytes": 0,
  "would_free_bytes": 89456742,
  "duration_ms": 1234
}
```

### 3. 执行真实清理

```bash
# WebUI：首页 → 快速清理 → 关闭「预览模式」→ 点击清理
# 或命令行：
/data/adb/modules/tarn/tarn run --json
```

### 4. 设置定时清理

编辑 `/data/adb/tarn/config/blacklist.toml`，给规则加上 cron 触发：

```toml
[[rule]]
id = "daily-cache"
name = "每日缓存清理"
enabled = true

[rule.trigger]
on = ["cron"]
cron_expr = "0 3 * * *"    # 每天 3:00 自动清理

[[rule.targets]]
path = "/data/data"
glob = "*cache"
mode = "clear_dirs"
older_than_days = 3
```

```bash
# 热重载配置（无需重启 daemon）
/data/adb/modules/tarn/tarn reload
```

---

## ⚙️ 配置

Tarn 采用**三文件分离**的配置体系，职责正交：

| 文件 | 位置 | 职责 |
|---|---|---|
| `settings.toml` | `/data/adb/tarn/config/settings.toml` | 引擎全局设置（并发、日志、WebUI） |
| `blacklist.toml` | `/data/adb/tarn/config/blacklist.toml` | 清理规则（要删什么） |
| `whitelist.toml` | `/data/adb/tarn/config/whitelist.toml` | 保护规则（不删什么） |

配置加载优先级：`引擎默认值 < settings.toml < CLI flag`

完整配置规范见 [docs/CONFIG-SPEC.md](./docs/CONFIG-SPEC.md)。

### settings.toml 速览

```toml
[engine]
parallel_workers = 0          # 0=自动(CPU核数)
batch_size = 500              # 单批 unlink 文件数
low_power = true              # nice 19 + 绑小核
cpu_affinity = []             # 空=自动探测小核

[log]
level = "info"                # trace|debug|info|warn|error
max_size_mb = 5
keep_files = 3

[webui]
enabled = true
bind = "127.0.0.1"
port = 8080
```

---

## 🧹 清理规则

### 规则包

内置 71 条社区规则，覆盖 50+ 主流 App，按类别分包：

| 规则包 | 覆盖范围 | 规则数 |
|---|---|---|
| `system-junk` | 系统日志/ANR/dropbox/临时文件 | 4 |
| `app-cache` | 所有 App 通用缓存 | 5 |
| `tencent-apps` | 微信/QQ/腾讯视频 | 9 |
| `social-apps` | 抖音/快手/小红书/知乎/微博 | 11 |
| `ecommerce-apps` | 淘宝/京东/拼多多/美团 | 9 |
| `media-apps` | B站/网易云/爱奇艺/YouTube | 12 |
| `browsers` | Chrome/Edge/Firefox/夸克/UC | 10 |
| `utility-apps` | 支付宝/高德/12306/钉钉/飞书 | 11 |

### 规则编写

完整规则编写指南见 [清理规则要求.md](./docs/清理规则要求.md)。

一条典型规则：

```toml
[[rule]]
id = "wechat-cache"
name = "微信缓存清理"
enabled = true
priority = 50

[rule.trigger]
on = ["manual", "boot", "cron"]
cron_expr = "0 3 * * *"

[[rule.targets]]
path = "/data/data/com.tencent.mm"
glob = "*cache"
mode = "clear_dirs"           # 清空目录内容，保留目录本身
older_than_days = 3           # 仅清 3 天前的
exclude = ["**/voice2/**"]    # 排除语音消息
```

### 三种处理模式

| 模式 | 图标 | 行为 | 适合场景 |
|---|---|---|---|
| `delete_files` | 🗑 | 严格按通配符匹配**文件**，目录不动 | 删 `*.log` `*.tmp` `*.apk` |
| `clear_dirs` | 🧹 | 匹配到的**目录**，清空内容，目录保留 | 清 `cache` `temp`（推荐） |
| `delete_dirs` | ⚠ | 匹配到的目录**连根删** | 删临时目录 `.tmp_dir` |

---

## 🖥️ WebUI

WebUI 提供 Web 管理界面，默认地址 `http://127.0.0.1:8080`。

### 功能

- **仪表盘**：当前状态、最近运行记录、释放空间统计
- **快速清理**：一键清理，支持 dry-run 预览
- **规则管理**：增删改查规则，支持表单编辑（小白友好）
- **保护名单**：可视化配置白名单
- **设置**：在线编辑 settings.toml
- **日志**：实时查看引擎日志
- **导入导出**：.toml 规则包批量导入

### 访问方式

```bash
# 1. 获取 token
cat /data/adb/tarn/run/token

# 2. 设备本机浏览器访问
#    http://127.0.0.1:8080

# 3. 远程访问（不推荐，需改 bind 为 0.0.0.0）
#    编辑 settings.toml → [webui] bind = "0.0.0.0"
#    ⚠️ 务必妥善保管 token，避免在公共网络暴露
```

---

## 🔧 命令行

```bash
# 健康检查
tarn doctor

# 手动运行清理（预览模式）
tarn run --dry-run --json

# 手动运行清理（真实执行）
tarn run --json

# 仅运行指定规则
tarn run --rule wechat-cache

# 启动/停止 daemon
tarn daemon
tarn daemon --stop

# 启动 WebUI
tarn webui

# 热重载配置
tarn reload

# 触发事件
tarn trigger event <name>

# 查看状态
tarn status

# 查看版本
tarn --version
```

所有命令的完整参数：

```bash
tarn --help
tarn <command> --help
```

---

## 📦 项目结构

```
Tarn/                          # 仓库根
├── LICENSE.txt                # TPL-2.0 闭源专有许可协议
├── README.md                  # 本文件
├── CHANGELOG.md               # 版本变更记录
├── docs/
│   ├── 清理规则要求.md        # 规则编写规范
│   ├── CONFIG-SPEC.md         # 三文件配置完整规范
│   ├── FAQ.md                 # 常见问题
│   ├── LICENSE_NOTICE.md      # 闭源声明补充
│   ├── SECURITY.md            # 安全策略
│   ├── SUPPORT.md             # 支持与帮助
│   ├── CONTRIBUTING.md        # 贡献指南
│   ├── CODE_OF_CONDUCT.md     # 行为准则
│   └── ARCHITECTURE.md        # 架构概述（不涉及源码）
├── examples/
│   ├── settings.example.toml  # 设置示例
│   ├── blacklist.example.toml # 清理规则示例
│   └── whitelist.example.toml # 保护规则示例
├── module/                    # Magisk 模块打包内容
│   ├── tarn                   # 编译后的 ELF 二进制（arm64）
│   ├── module.prop            # 模块描述
│   ├── customize.sh           # 安装脚本
│   ├── service.sh             # 开机服务脚本
│   ├── uninstall.sh           # 卸载脚本
│   ├── verify.sh              # 完整性校验
│   ├── debug.sh               # 调试脚本
│   ├── config/                # 默认配置模板
│   ├── rules/                 # 社区规则包
│   ├── webroot/               # WebUI 前端资源
│   └── apk/                   # KsuWebUI 配套 APK
└── dist/                      # 构建产物（不入 git）
    └── tarn-vX.Y.Z-versionCode.zip
```

> 📌 **注意**：本仓库**不包含 Rust 源代码**。`module/tarn` 为编译后的 ELF 二进制。
> 如需了解架构设计，见 [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md)（仅描述设计，不含源码）。

---

## ❓ FAQ

<details>
<summary><b>Q: Tarn 是开源的吗？</b></summary>

**不是。** Tarn 是闭源专有软件（Proprietary Software），采用 TPL-2.0 协议，仅以编译后的二进制形式分发，不提供源代码。个人/内部非商业使用免费，商业使用需另行授权。

</details>

<details>
<summary><b>Q: 为什么 Tarn 不开源？</b></summary>

闭源是作者的有意选择，原因包括：
1. 规则文件是耗费大量人力搜集整理的智力成果，开源容易被直接搬运
2. 系统级 root 工具被恶意 fork 后植入后门的风险较高
3. 维护开源社区的成本高于个人开发者承受范围

但我们承诺：二进制不含任何遥测、不上传用户数据、不联网回传任何信息。所有运行数据均在设备本地。

</details>

<details>
<summary><b>Q: Tarn 会上传我的数据吗？</b></summary>

**不会。** Tarn 运行过程中处理的文件元数据（路径、大小、修改时间）仅用于执行清理任务，生成的日志和状态文件均存放在设备本地 `/data/adb/tarn/`。Tarn 不包含任何网络上传代码，不连接任何服务器。详见 [docs/SECURITY.md](./docs/SECURITY.md)。

</details>

<details>
<summary><b>Q: 定时清理会穿透 Doze 模式吗？</b></summary>

**会。** Tarn 使用内核 `timerfd` + `CLOCK_BOOTTIME_ALARM` 实现定时，不依赖 Android 的 AlarmManager，因此能穿透 Doze 省电模式，在设定时间准确触发。

</details>

<details>
<summary><b>Q: 误删了重要文件怎么办？</b></summary>

1. 立即停止 daemon：`kill $(cat /data/adb/tarn/run/tarn.pid)`
2. 查看 `/data/adb/tarn/state.json` 的 `recent_runs` 审计轨迹
3. 查看 `/data/adb/tarn/logs/tarn.log` 的删除记录
4. **下次务必先用 `tarn run --dry-run` 预览！**

Tarn 不提供撤销功能（删除是物理 unlink），请务必先备份重要数据并配置好白名单。

</details>

<details>
<summary><b>Q: 支持 x86 / 32 位设备吗？</b></summary>

不支持。目前仅编译 `aarch64-linux-android`（arm64-v8a）目标。绝大多数现代 Android 设备均为 arm64。

</details>

<details>
<summary><b>Q: 可以把 Tarn 打包进我的 ROM / 刷机包分发吗？</b></summary>

**不可以。** TPL-2.0 协议明确禁止再分发。如您需将 Tarn 集成进商业 ROM 或付费产品，请申请商业授权，见 [docs/LICENSE_NOTICE.md](docs/LICENSE_NOTICE.md)。

</details>

更多 FAQ 见 [docs/FAQ.md](./docs/FAQ.md)。

---

## 🛡️ 安全

- **不上传任何数据**：无遥测、无回传、无统计上报
- **token 鉴权**：WebUI 访问需 token，默认仅绑定 127.0.0.1
- **路径白名单**：规则只能清理 `ALLOWED_ROOTS` 内的路径
- **硬编码保护**：`/system` `/vendor` `/data/adb` 等永不删除
- **dry-run 预览**：执行前可预览将删除的文件列表

如发现安全漏洞，请按 [docs/SECURITY.md](docs/SECURITY.md) 流程私密报告，请勿公开 Issue。

---

## 📄 许可证

Copyright (c) 2025 linjoin. All Rights Reserved.

本软件受 [《Tarn 专有软件许可协议》(TPL-2.0)](LICENSE.txt) 约束：

| 行为 | 是否允许 |
|---|---|
| 个人/内部非商业安装运行 | ✅ 允许 |
| 配置定制、规则定制 | ✅ 允许 |
| 个人备份（≤2 份） | ✅ 允许 |
| 再分发（源码/二进制/规则/文档） | ❌ 禁止 |
| 修改（含二进制 patch、脚本篡改） | ❌ 禁止 |
| 派生作品创作与分发 | ❌ 禁止 |
| 逆向工程 | ❌ 禁止 |
| 商业使用 | ❌ 需另行授权 |

第三方开源组件许可证见 [THIRD_PARTY_LICENSES.txt](./THIRD_PARTY_LICENSES.txt)。

---

## 🙏 致谢

Tarn 的规则包整理参考了以下社区项目与资源：

- [SD Maid SE](https://github.com/d4rken-org/sdmaid-se) — 最专业的 Android 清理工具
- [WeirdMidas/BasicCleaner](https://github.com/WeirdMidas/BasicCleaner) — Magisk 清理模块
- [DEMONNICA/Clear-Optimization](https://github.com/DEMONNICA/Clear-Optimization) — Magisk 优化模块
- [Cai-Ming-Yu/CMY-CacheCleaner](https://github.com/Cai-Ming-Yu/CMY-CacheCleaner) — KernelSU 缓存清理
- Android 官方存储规范文档
- 知乎、CSDN、百度经验等社区教程

感谢以上项目与社区贡献者。Tarn 的二进制编译使用了大量 MIT/Apache-2.0 许可的 Rust 开源 crate，完整清单见 [THIRD_PARTY_LICENSES.txt](/THIRD_PARTY_LICENSES.txt)。

---

<div align="center">

**[📥 下载最新版](https://github.com/linjoin/Tarn/releases)** · **[📖 文档](./docs/)** · **[🐛 报告 Bug](https://github.com/linjoin/Tarn/issues/new?template=bug_report.md)** · **[💡 建议规则](https://github.com/linjoin/Tarn/issues/new?template=rule_request.md)**

Made with Rust 🦀 by linjoin

</div>

