# 更新日志 (Changelog)

本文件记录 Tarn 每个版本的变更。版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> 📌 下载地址见 [Releases](https://github.com/linjoin/Tarn/releases)。仅提供编译后二进制模块，不含源代码。

---

## [v0.9.0] - 2025-06-21

### 🎉 里程碑

Tarn v0.9.0 — 协议升级 + 规则包扩充 + 稳定性优化

### ⚖️ 协议

- **BREAKING**：许可协议从 TSL-1.0 升级为 **TPL-2.0（闭源专有）**
  - 明确本项目为闭源专有软件，仅以编译后二进制形式分发
  - 删除源代码可见相关条款（不提供源代码）
  - 强化禁止逆向工程、禁止修改、禁止再分发条款
  - 新增商业授权章节
  - 详见 [LICENSE.txt](./LICENSE.txt)

### ✨ 新增

- 规则包扩充至 17 个分类文件，覆盖 100+ App
  - 新增 `games.txt` 游戏类清理规则
  - 新增 `system-deep.txt` 系统深度清理
  - 新增 `cloud-input-reading.txt` 云盘/输入法/阅读类
  - 新增 `ai-im-overseas.txt` AI 工具与海外 App
  - 新增 `finance-news-fitness.txt` 金融/新闻/健身
  - 新增 `lifestyle-stream-email.txt` 生活/直播/邮箱
  - 新增 `niche-apps-a/b/c.txt` 小众 App 三册
- WebUI 前端优化：开关滑块定位修复（transform→left）

### 🐛 修复

- WebUI 开关 CSS 兼容性加固（appearance:none）
- 去除解释性日志括号，日志格式统一
- trace 级别日志补充

### 📦 产物

- `tarn-v0.9.0-74.zip` (2.77 MB)
- `tarn-rules-v0.9.0.zip` (60 KB)

> 📌 **发布物命名规范化**（自 v0.9.0 起）
> 统一采用 `tarn-vX.Y.Z-versionCode.zip` 格式，其中：
> - `X.Y.Z`：语义化版本号
> - `versionCode`：单调递增整数，与 `module.prop` 的 `versionCode` 一致，供 Magisk/KernelSU 模块升级判定
>
> 例：`tarn-v0.9.0-74.zip`

---

## [v0.8.10] - 2025-06-21

### ✨ 新增

- 全网搜集社区清理规则包：71 条规则 / 50+ App
- 按类别分 8 个 toml 文件，放在 `module/rules/` 目录，即导即用
- 规则来源：SD Maid SE / BasicCleaner / CMY-CacheCleaner / 知乎 / CSDN / Android 官方文档

### 📊 规则包清单

| 文件 | 覆盖 | 规则数 | 默认启用 |
|------|------|--------|----------|
| system-junk.toml | 系统日志/ANR/dropbox/临时文件 | 4 | 4 |
| app-cache.toml | 所有 App 通用缓存（通配符） | 5 | 3 |
| tencent-apps.toml | 微信/QQ/腾讯视频 | 9 | 8 |
| social-apps.toml | 抖音/快手/小红书/知乎/头条/微博/贴吧 | 11 | 11 |
| ecommerce-apps.toml | 淘宝/京东/拼多多/美团/饿了么/携程/唯品会 | 9 | 9 |
| media-apps.toml | B站/网易云/爱奇艺/优酷/芒果TV/喜马拉雅/YouTube/Spotify | 12 | 11 |
| browsers.toml | Chrome/Edge/Firefox/夸克/UC/QQ/百度/Via | 10 | 10 |
| utility-apps.toml | 支付宝/高德/百度地图/滴滴/12306/点评/WPS/钉钉/企微/飞书 | 11 | 11 |

### 🔧 规则设计原则

1. 安全第一：只清 cache/code_cache，不碰 databases/files/shared_prefs
2. 风险分级：激进规则和离线缓存清理默认 enabled=false
3. 定时策略：高频 App 每日（0 3 * * *），低频项每周（0 3 * * 0）
4. older_than_days 防误删：视频缓存 3 天，图片缩略图 14-30 天，系统日志 3-7 天
5. 排除关键 App：通用规则排除输入法/启动器/系统 UI

### ✅ 验证

- Python tomllib 验证（TOML 1.0 语法 + 字段完整性 + id 唯一性 + path 白名单）
- Rust toml crate 验证（用 tarn_core::config::Blacklist 结构解析，引擎同款）
- 字段全部一一对应，无拼写错误

---

## [v0.8.9] - 2025-06-21

### 🐛 修复

- WebUI 开关描述去除版本号元信息

---

## [v0.8.8] - 2025-06-20

### 🐛 修复

- WebUI 开关 CSS 兼容性加固（appearance:none）

---

## [v0.8.6] - 2025-06-20

### 🐛 修复

- 去除解释性日志括号

---

## [v0.7.11] - 2025-06-19

### ✨ 新增

- 日志样本真实化 + 补 trace 级别日志

---

## 历史版本

早期版本（v0.1.0 ~ v0.7.10）的变更记录略，主要里程碑：

- **v0.7.x**：WebUI 完善、规则系统成熟、社区规则包引入
- **v0.6.x**：双引擎稳定、io_uring 集成、低功耗调优
- **v0.5.x**：白名单系统完善、dry-run 预览、空目录清理
- **v0.4.x**：WebUI（axum + token 鉴权）上线
- **v0.3.x**：cron 定时触发、穿透 Doze
- **v0.2.x**：nice 19 + 绑核低功耗、批量 unlink
- **v0.1.x**：Rust 内核框架搭建、Rayon + Tokio 双引擎
- **v0.1.0**：项目初始化

---

## 版本号规则

Tarn 版本号格式：`vMAJOR.MINOR.PATCH`

- **MAJOR**：协议或架构发生破坏性变更
- **MINOR**：新增功能、规则包扩充（向下兼容）
- **PATCH**：Bug 修复、小优化

`versionCode`（整数）用于 Magisk 模块升级判定，单调递增。

### 发布物命名规范（自 v0.9.0 起）

自 v0.9.0 起，Release 附件统一采用以下命名格式：

```
tarn-vX.Y.Z-versionCode.zip
```

- `X.Y.Z`：语义化版本号，与 `module.prop` 的 `version` 字段一致
- `versionCode`：整数版本号，与 `module.prop` 的 `versionCode` 字段一致，单调递增，用于 Magisk/KernelSU 模块升级判定

**示例**：`tarn-v0.9.0-74.zip`

规则包独立分发时采用：`tarn-rules-vX.Y.Z.zip`（例：`tarn-rules-v0.9.0.zip`）

---

**反馈渠道**：[GitHub Issues](https://github.com/linjoin/Tarn/issues)
