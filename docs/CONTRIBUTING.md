# 贡献指南

> 首先，**感谢你对 Tarn 的兴趣！** 🙏

Tarn 是**闭源专有软件**，因此贡献方式与开源项目有所不同。请仔细阅读本指南。

---

## ⚠️ 重要的前提

### Tarn 不接受源代码贡献

由于 Tarn 是闭源项目，**我们不接受源代码形式的 Pull Request**。请勿提交：

- ❌ Rust 源代码修改
- ❌ 反编译/逆向工程产物
- ❌ 二进制 patch
- ❌ 要求公开源代码的 Issue

### 我们欢迎的贡献方式

- ✅ **Bug 报告**（帮助我们发现和修复问题）
- ✅ **功能建议**（帮助我们规划路线图）
- ✅ **清理规则贡献**（扩充规则库，惠及所有用户）
- ✅ **文档改进建议**（让文档更易懂）
- ✅ **使用经验分享**（在社区分享你的配置心得）

---

## 🐛 报告 Bug

### 提交前请先搜索

在 [提交新 Issue](https://github.com/linjoin/Tarn/issues/new?template=bug_report.md) 前，请先搜索现有 Issue，避免重复。

### 收集诊断信息

提交 Bug 时请提供以下信息（使用 Bug Report 模板会自动引导）：

1. **环境信息**
   - 设备型号（如 Pixel 7）
   - Android 版本（如 Android 14）
   - Root 框架与版本（如 Magisk 26.4 / KernelSU 1.0.0）
   - Tarn 版本（`tarn --version`）

2. **复现步骤**
   - 你做了什么（具体操作）
   - 你期望发生什么
   - 实际发生了什么

3. **诊断输出**
   ```bash
   # 健康检查
   /data/adb/modules/tarn/tarn doctor

   # 最近日志
   tail -100 /data/adb/tarn/logs/tarn.log

   # 状态文件
   cat /data/adb/tarn/state.json

   # dry-run 输出（如涉及规则问题）
   /data/adb/modules/tarn/tarn run --dry-run --json
   ```

4. **配置文件**（如涉及规则问题，请附上相关规则片段，**去除敏感路径**）

### Bug 报告原则

- **一个 Issue 一个问题**：不要在一个 Issue 里报告多个不相关的 Bug
- **提供最小复现**：尽量精简配置，定位问题
- **不要包含敏感信息**：去除 token、私人路径、包名等
- **及时回复**：维护者可能需要更多信息

---

## 💡 功能建议

### 提交建议

使用 [Feature Request 模板](https://github.com/linjoin/Tarn/issues/new?template=feature_request.md) 提交。

请说明：
1. **你的使用场景**：你遇到什么问题，需要什么功能
2. **期望的解决方案**：你希望 Tarn 怎么做
3. **替代方案**：你考虑过其他做法吗
4. **额外上下文**：截图、参考链接等

### 路线图考量

功能建议会根据以下因素评估优先级：
- 受益用户数
- 实现复杂度
- 与现有架构的契合度
- 安全风险
- 维护成本

我们不保证所有建议都会实现，但每一条都会认真阅读和回复。

---

## 🧹 贡献清理规则

这是我们**最欢迎**的贡献方式！规则库的扩充惠及所有用户。

### 提交流程

1. **编写规则**：参考 [清理规则要求.md](./清理规则要求.md) 编写
2. **本地测试**：
   ```bash
   # 导入规则后先 dry-run
   /data/adb/modules/tarn/tarn run --dry-run --json --rule <your-rule-id>

   # 检查 audit 日志，确认无误
   # 真实执行
   /data/adb/modules/tarn/tarn run --rule <your-rule-id>
   ```
3. **提交 Issue**：使用 [Rule Request 模板](https://github.com/linjoin/Tarn/issues/new?template=rule_request.md)，附上：
   - 规则的 toml 内容
   - 覆盖的 App 名称与包名
   - 测试结果（dry-run 统计 + 真实执行统计）
   - 安全性说明（为什么这条规则是安全的）

### 规则质量要求

提交的规则须满足：

| 要求 | 说明 |
|---|---|
| ✅ 路径合法 | path 在 ALLOWED_ROOTS 内 |
| ✅ 包名准确 | 使用真实的 Android 包名 |
| ✅ older_than_days 兜底 | 除非有充分理由，否则不设 0 |
| ✅ 安全的 mode | 清 cache 用 clear_dirs，不用 delete_dirs |
| ✅ 必要的 exclude | 排除数据库、语音等敏感目录 |
| ✅ 已实测 | 在真实设备上 dry-run + 真实执行验证 |
| ✅ id 唯一 | 不与现有规则冲突 |

### 规则审核

提交的规则会由维护者审核，审核要点：
- 路径准确性（包名是否正确）
- 安全性（是否会误删重要数据）
- 通用性（是否适用于多数设备）
- 与现有规则的重复度

审核通过后，规则会合并进官方规则包，随下一个版本发布。**贡献者会被记录在规则文件头部注释中**（如果你愿意署名）。

---

## 📝 文档改进

如果你发现文档有错误、遗漏或表述不清，欢迎：

1. 提 Issue 说明问题
2. 提供建议的修改内容

由于源代码闭源，文档无法通过 PR 直接修改，但我们会认真对待每一条文档改进建议。

---

## 🤝 行为准则

请保持友善和尊重：

- 🟢 **友善**：对维护者和其他贡献者保持友善
- 🟢 **耐心**：维护者是个人开发者，回复可能不及时
- 🟢 **建设性**：提建议时请提供解决方案，而非单纯抱怨
- 🟢 **隐私**：不要在 Issue 中泄露自己的敏感信息
- 🔴 **禁止**：人身攻击、骚扰、广告、政治话题
- 🔴 **禁止**：要求公开源代码、质疑闭源决策

违反行为准则的 Issue/评论会被关闭或删除，情节严重者会被 block。

---

## 📋 Issue 状态说明

| 标签 | 含义 |
|---|---|
| `bug` | 确认的 Bug |
| `feature` | 功能建议 |
| `rule` | 规则贡献/请求 |
| `docs` | 文档相关 |
| `duplicate` | 重复 Issue |
| `wontfix` | 不会修复 |
| `invalid` | 无效 Issue |
| `in-progress` | 正在处理 |
| `fixed` | 已修复（待发布） |
| `released` | 已在某个版本发布 |

---

## ❓ 还有疑问？

- 通用问题：先看 [FAQ](FAQ.md)
- 安全问题：按 [SECURITY.md](SECURITY.md) 流程私密报告
- 商业授权：通过 Issue 联系

---

**再次感谢你的支持！** Tarn 的发展离不开社区的帮助。

Copyright (c) 2025 linjoin. All Rights Reserved.
