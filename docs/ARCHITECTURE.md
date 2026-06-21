# 架构概述

> 本文件描述 Tarn 的架构设计**理念**与**模块划分**，不涉及源代码实现细节。

---

## 设计目标

Tarn 的核心设计目标：

| 目标 | 实现手段 |
|---|---|
| **系统级** | Magisk/KernelSU 模块，root 权限，开机自启 daemon |
| **高并发** | Rayon（CPU 并行遍历）+ Tokio（异步 IO 调度） |
| **低功耗** | nice 19 + 绑小核 + 自适应限速 |
| **防雪崩** | 6 层白名单 + dry-run + ALLOWED_ROOTS + 硬编码保护 |
| **穿透 Doze** | 内核 timerfd + CLOCK_BOOTTIME_ALARM |
| **可配置** | 三文件分离（settings/blacklist/whitelist），TOML 格式 |

---

## 模块划分

Tarn 在逻辑上划分为以下模块（按职责）：

```
┌─────────────────────────────────────────────────────┐
│                     CLI (clap)                       │
│  tarn run / webui / daemon / doctor / reload ...     │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│                    Core Engine                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │  Config  │  │  Matcher │  │     Walker       │   │
│  │ (TOML)   │  │ (globset)│  │ (getdents+rayon) │   │
│  └──────────┘  └──────────┘  └──────────────────┘   │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │  Protect │  │ Executor │  │    Scheduler     │   │
│  │ (6 层)   │  │ (unlink) │  │ (timerfd+cron)   │   │
│  └──────────┘  └──────────┘  └──────────────────┘   │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────┐   │
│  │  Logger  │  │  State   │  │   ConfigWatcher  │   │
│  │ (tracing)│  │  (JSON)  │  │  (热重载)        │   │
│  └──────────┘  └──────────┘  └──────────────────┘   │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│                  WebUI (axum)                         │
│  HTTP + WebSocket + token 鉴权 + Unix socket          │
└─────────────────────────────────────────────────────┘
```

### 各模块职责

| 模块 | 职责 | 关键技术 |
|---|---|---|
| **Config** | 加载/解析 TOML 配置 | serde + toml |
| **Matcher** | 编译 glob 模式为 DFA | globset |
| **Walker** | 并行遍历目录树 | Rayon + getdents64 |
| **Protect** | 6 层白名单校验 | 前缀匹配 + globset + 包名 + 扩展名 + mtime |
| **Executor** | 执行文件删除 | unlinkat 批量 + io_uring stat |
| **Scheduler** | 定时触发清理任务 | timerfd + CLOCK_BOOTTIME_ALARM + cron 解析 |
| **Logger** | 异步日志 | tracing + tracing-appender + 轮转 |
| **State** | 状态持久化 | JSON + 原子写（临时文件 rename） |
| **ConfigWatcher** | 配置热重载 | inotify |
| **WebUI** | Web 管理界面 | axum + tower-http + token 鉴权 |

---

## 执行流程

### 一次清理任务的执行流程

```
用户触发 (manual / boot / cron / event)
         │
         ▼
   Scheduler 接收触发
         │
         ▼
   加载 blacklist.toml (热重载)
         │
         ▼
   遍历 enabled 规则 (按 priority 排序)
         │
         ▼
   ┌─── 对每条规则 ───┐
   │                  │
   │  遍历 targets    │
   │       │          │
   │       ▼          │
   │  Walker 并行遍历目录 (Rayon)       │
   │       │                          │
   │       ▼                          │
   │  Matcher 匹配 glob               │
   │       │                          │
   │       ▼                          │
   │  Protect 白名单校验 (6 层)        │
   │       │                          │
   │       ▼                          │
   │  older_than / min_size 过滤      │
   │       │                          │
   │       ▼                          │
   │  dry_run? ──是──→ 只统计, 不删   │
   │       │                          │
   │       否                         │
   │       ▼                          │
   │  Executor 批量 unlinkat          │
   │       │                          │
   │       ▼                          │
   │  空目录清理 (可选)                │
   └──────────────────────────────────┘
         │
         ▼
   写 state.json (原子写)
         │
         ▼
   写 audit 日志
```

### 定时触发流程

```
daemon 启动
    │
    ▼
读取所有 cron 规则
    │
    ▼
为每条规则创建 timerfd
    │
    ▼
epoll 等待 timerfd 触发
    │
    ▼
timerfd 触发 (CLOCK_BOOTTIME_ALARM, 穿透 Doze)
    │
    ▼
执行清理任务 (见上图)
    │
    ▼
重新 arm timerfd (下一次触发)
```

---

## 双引擎设计

### Rayon（CPU 并行）

- 用于**目录遍历**和**文件匹配**（CPU 密集型）
- 工作窃取式调度，充分利用多核
- 遍历子目录时并行 fork

### Tokio（异步 IO）

- 用于 **WebUI**（axum 基于 Tokio）和**定时调度**
- 异步处理 HTTP 请求，不阻塞清理任务
- timerfd 通过 Tokio 的 AsyncFd 集成

### 协作方式

- 清理任务在 Rayon 线程池执行（CPU 密集）
- WebUI 和 Scheduler 在 Tokio runtime 执行（IO 密集）
- 两者通过 channel 通信，互不阻塞

---

## 低功耗设计

### nice 19

- CFS 调度器用 nice 值计算时间片权重：`weight = 1024 * 1.25^(-nice)`
- nice 19 → weight ~15，占 CPU ~1.5%
- 在所有 Android 设备有效

### CPU 绑小核

- 自动探测小核（读 `/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq`，频率最低的核）
- 通过 `sched_setaffinity` 绑定所有线程到小核
- 遍历 `/proc/self/task/<tid>` 对所有线程设置，覆盖 logger/webui/tokio worker

### 自适应限速

- 监测前台进程 IO 活跃度
- 前台忙时降速（每秒删 N 个文件）
- 空闲时全速

---

## 防雪崩设计

### 6 层保护

| 层 | 类型 | 何时生效 |
|---|---|---|
| 1 | 硬编码保护 | 永远生效（/system 等） |
| 2 | ALLOWED_ROOTS | 规则加载时校验 path |
| 3 | protect（路径） | 文件遍历时校验 |
| 4 | protect_package（包名） | 文件遍历时校验 |
| 5 | protect_ext（扩展名） | 文件遍历时校验 |
| 6 | protect_mtime（修改时间） | 文件遍历时校验 |

白名单**永远优先**于清理规则，命中保护即跳过，并记录 `action=block` 到 audit 日志。

### dry-run

- `--dry-run` 模式只扫描统计，不真删
- 输出 `would_free_bytes` 和 audit 日志
- WebUI 默认开启 dry-run（预览模式），用户确认后关闭

### older_than_days

- 只删 N 天前的旧文件
- 防止删掉 App 正在使用的热数据
- 默认推荐 3-7 天

---

## WebUI 架构

### 双通道

- **TCP**：`127.0.0.1:8080`，HTTP + WebSocket
- **Unix socket**：`/data/adb/tarn/run/tarn.sock`，本地进程间通信

### 鉴权

- token 存放于 `/data/adb/tarn/run/token`（权限 0600）
- 每次请求须携带 token（Header 或 query）
- WebSocket 连接时校验 token

### 前端

- 纯静态 HTML/JS/CSS，打包在 `module/webroot/`
- 不依赖外部 CDN，离线可用
- 小白友好的表单式规则编辑

---

## 数据持久化

### 文件布局

```
/data/adb/tarn/
├── config/                 # 用户配置（升级保留）
│   ├── settings.toml
│   ├── blacklist.toml
│   └── whitelist.toml
├── logs/                   # 日志（轮转）
│   └── tarn.log
├── run/                    # 运行时文件
│   ├── tarn.pid            # daemon PID
│   ├── tarn.sock           # Unix socket
│   └── token               # WebUI token
└── state.json              # 状态文件（最近运行记录）
```

### 原子写

`state.json` 采用原子写：
1. 写入临时文件 `state.json.tmp`
2. `fsync` 确保落盘
3. `rename` 覆盖原文件
4. 防止写坏导致状态丢失

### 日志轮转

- 单文件最大 5MB（可配置）
- 保留 3 份历史（可配置）
- 异步写入，不阻塞主线程

---

## 交叉编译

Tarn 使用 Rust + NDK 交叉编译到 `aarch64-linux-android`：

- **NDK**：r27c
- **linker**：NDK clang
- **优化**：`opt-level=z` + `lto=true` + `codegen-units=1` + `panic=abort` + `strip=true`
- **结果**：约 3.6MB ELF 二进制

---

## 技术选型理由

| 技术 | 选型 | 理由 |
|---|---|---|
| 语言 | Rust | 性能 + 内存安全 + 零成本抽象 |
| 异步 | Tokio | 生态成熟，与 axum 集成 |
| 并行 | Rayon | 工作窃取，CPU 密集型最佳 |
| Web | axum | 轻量，类型安全，与 Tokio 集成 |
| 匹配 | globset | DFA 编译，高性能 |
| 序列化 | serde + toml | TOML 人类友好，Rust 生态标准 |
| CLI | clap | 功能完整，derive 宏好用 |
| 日志 | tracing | 结构化日志，异步友好 |

---

## 限制与未来方向

### 当前限制

- 仅支持 arm64-v8a 架构
- 仅支持 Android 9.0+
- 不提供源代码
- 规则路径受 ALLOWED_ROOTS 限制

### 未来方向（视社区需求）

- 更多架构支持（视需求）
- 更丰富的事件触发（如 App 安装/卸载触发）
- 规则市场（社区规则分享平台）
- 统计报表（清理历史可视化）

> 注：以上为方向探索，不构成承诺。

---

copyright (c) 2025 linjoin. All Rights Reserved.
