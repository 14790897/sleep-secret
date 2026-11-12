<!--
PR 标题必须遵循 Conventional Commits（feat: / fix: / chore: / test: ...），
semantic-release 靠它决定版本号：feat → minor，fix → patch，其余不发版。
写法：类型: 简短描述，例如 fix: 鼾声时长按实际有声计算
-->

## Problem

<!-- 这个 PR 解决什么问题？为什么需要改？引用相关 issue（如 #16）。 -->

## Solution

<!-- 具体做了什么，逐条列出关键改动；说明取舍、边界情况和被有意排除的范围。 -->

## Screenshots

<!-- 涉及界面或生成结果变化时必填：用表格做前后对比，图片直接拖进文本框上传。纯逻辑/重构可删除本节。 -->

| Before | After |
| --- | --- |
|  |  |

## Validation

<!-- 逐条列出你实际跑过的命令和验证步骤，不要只写"测试通过"。 -->

-

## Checklist

- [ ] 标题是 Conventional Commits 格式
- [ ] 新增的用户可见文字已同时提供中英文（`app/lib/l10n/app_zh.arb` / `app_en.arb`）
- [ ] 改了数据库 schema：补了迁移和「老库能平滑升级」的测试
- [ ] 改了界面：在模拟器/真机上实际跑过，不是只看测试
- [ ] 未手动修改 `pubspec.yaml` 的版本号（semantic-release 负责）

<!--
按需保留的可选小节：
## Root cause   —— 修 bug 时说明根因，而不只是现象
## Impact       —— 对 API、配置、用户行为的影响范围
## Dependency   —— 合并顺序，以及依赖的其他 PR
-->
