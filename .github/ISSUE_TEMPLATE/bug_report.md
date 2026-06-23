---
name: Bug 报告
about: 报告 Tarn 的 Bug 或异常行为
title: "[BUG] "
labels: bug
assignees: linjoin
---

## Bug 描述

<!-- 简要描述你遇到的问题 -->

## 复现步骤

1.
2.
3.

## 期望行为

<!-- 你期望发生什么 -->

## 实际行为

<!-- 实际发生了什么 -->

## 环境信息

- 设备型号：
- Android 版本：
- Root 框架与版本：
- Tarn 版本：<!-- 运行 `tarn --version` -->
- 内核版本：<!-- 运行 `uname -r` -->

## 诊断信息

<!-- 请运行以下命令并粘贴输出（注意去除敏感信息） -->

### tarn doctor 输出

```
粘贴输出
```

### 最近日志

```bash
tail -100 /data/adb/tarn/logs/tarn.log
```

```
粘贴日志
```

### 涉及的规则（如适用）

```toml
粘贴相关规则
```

### dry-run 输出（如涉及清理问题）

```bash
/data/adb/modules/tarn/tarn run --dry-run --json
```

```json
粘贴输出
```

## 补充信息

<!-- 截图、参考链接等 -->

---

**检查清单**（提交前请确认）：

- [ ] 我已搜索现有 Issue，确认无重复
- [ ] 我已阅读 [FAQ](https://github.com/linjoin/Tarn/blob/main/docs/FAQ.md)
- [ ] 我已阅读 [清理规则要求.md](https://github.com/linjoin/Tarn/blob/main/清理规则要求.md)（如涉及规则问题）
- [ ] 我已提供完整的环境信息
- [ ] 我已去除敏感信息（token、私人路径等）
- [ ] 我理解 Tarn 是闭源项目，不要求公开源代码
