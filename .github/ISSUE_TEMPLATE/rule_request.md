---
name: 清理规则贡献
about: 贡献新的清理规则或改进现有规则
title: "[RULE] "
labels: rule
assignees: linjoin
---

## 规则覆盖的 App

- App 名称：
- App 包名：<!-- 如 com.tencent.mm -->
- 应用商店链接（可选）：

## 规则内容

```toml
[[rule]]
id = ""
name = ""
enabled = true

[rule.trigger]
on = [""]

[[rule.targets]]
path = ""
glob = ""
mode = ""
older_than_days =
```

## 测试结果

### dry-run 统计

```bash
/data/adb/modules/tarn/tarn run --dry-run --json --rule <rule_id>
```

```json
粘贴输出（含 files_scanned / would_delete / would_free_bytes）
```

### 真实执行统计

```bash
/data/adb/modules/tarn/tarn run --rule <rule_id>
```

```json
粘贴输出（含 files_deleted / freed_bytes / duration_ms）
```

## 安全性说明

<!-- 说明这条规则为什么是安全的 -->

- [ ] 只清缓存目录（cache/code_cache），不碰 databases/files/shared_prefs
- [ ] 已设置 older_than_days 兜底
- [ ] 已配置必要的 exclude（如语音、数据库）
- [ ] mode 选择正确（清 cache 用 clear_dirs，不用 delete_dirs）
- [ ] 在真实设备上测试通过，未发现误删

## 测试环境

- 设备型号：
- Android 版本：
- App 版本：

## 补充说明

<!-- 该 App 的缓存目录特点、特殊注意事项等 -->

---

**检查清单**：

- [ ] 我已阅读 [清理规则要求.md](https://github.com/linjoin/Tarn/blob/main/docs/清理规则要求.md)
- [ ] 规则 path 在 ALLOWED_ROOTS 内
- [ ] 包名准确（已通过 `pm list packages` 确认）
- [ ] 已 dry-run 验证
- [ ] 已真实执行验证
- [ ] 未误删重要数据

**贡献者署名**（如规则被采纳）：
- [ ] 我希望在规则文件中署名
- [ ] 我希望匿名

GitHub 用户名：
