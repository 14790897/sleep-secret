import 'package:flutter/material.dart';

import '../../../../data/models/audioset_zh.dart';
import '../../../../domain/analysis/analysis_config.dart';
import '../../../../domain/models/sleep_category.dart';
import '../../../core/l10n/domain_text.dart';
import '../../../core/l10n/l10n_context.dart';
import '../../../core/theme.dart';
import '../view_models/report_view_model.dart';

/// 「详细视图」：模型整夜里给出的**原始 AudioSet 标签**。
///
/// ## 为什么是单独一页，而不是报告里的一张卡
///
/// 两件事决定的：
///
/// 1. **它很长。** 一夜几十种标签，放在报告里要么折叠（那用户就看不见），
///    要么把报告撑长一大截、把真正在「读报告」的人挡住。
/// 2. **它的用法不一样。** 上面每张卡说的都是**大类**——那是我们拼出来的；
///    这一页说的是模型的**原话**。报告哪里看着不对时，翻到这一页，
///    能立刻分清是**模型说错了**还是**我们映射错了**。那是核查，不是阅读。
///
/// 所以：报告里只留一个入口行（摘要 + 「未映射」那句，扫一眼就够），
/// 点进来是完整的表，返回键回去。
///
/// ## 「未映射」那一列最该看
///
/// 527 个标签里只映射了 47 个。没被映射的标签当冠军时，那一窗**不产生任何
/// 事件**——它在报告的其他任何地方都不会出现，只有这一页露一面。
class RawLabelsView extends StatelessWidget {
  const RawLabelsView({super.key, required this.viewModel});

  final ReportViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final counts = viewModel.session.stats.rawLabelCounts;

    // 拿不到映射表就只是不显示对照那一列——**不标「未映射」**。
    // 两者是两件事：一个是「没有归属」，一个是「我们不知道」。
    final classMap = viewModel.classMap;
    final hasMap = classMap != null;
    final byCategory =
        classMap?.labelToCategory() ?? const <String, SleepCategory>{};

    final rows = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final total = rows.fold<int>(0, (sum, e) => sum + e.value);
    final unmapped =
        hasMap ? rows.where((e) => !byCategory.containsKey(e.key)).length : 0;
    // 中文对照只在中文界面下显示——那张表只有中文（见 audioset_zh.dart）。
    final isZh = Localizations.localeOf(context).languageCode == 'zh';

    final note = theme.textTheme.bodySmall
        ?.copyWith(color: AppColors.textDim, height: 1.7);

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.reportRawLabelsTitle)),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text(
            context.l10n.reportRawLabelsSubtitle,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textDim, height: 1.5),
          ),
          const SizedBox(height: 12),
          if (counts.isEmpty)
            Text(context.l10n.reportRawLabelsNone, style: note)
          else ...[
            Text(
              context.l10n.reportRawLabelsSummary(rows.length, total),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            Text(
              context.l10n.reportRawLabelsWindowNote(
                  const AnalysisConfig().windowSeconds.round()),
              style: note,
            ),
            if (hasMap && unmapped > 0) ...[
              const SizedBox(height: 6),
              Text(
                context.l10n.reportRawLabelsUnmappedNote(unmapped),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.statusWarning, height: 1.6),
              ),
            ],
            const SizedBox(height: 12),
            FutureBuilder<Map<String, String>>(
              future: loadAudioSetZh(),
              builder: (context, snap) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final e in rows)
                    _RawLabelRow(
                      label: e.key,
                      zh: isZh ? (snap.data?[e.key]) : null,
                      count: e.value,
                      total: total,
                      category: byCategory[e.key],
                      showCategory: hasMap,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(context.l10n.reportRawLabelsCaveat, style: note),
          ],
        ],
      ),
    );
  }
}

class _RawLabelRow extends StatelessWidget {
  const _RawLabelRow({
    required this.label,
    required this.count,
    required this.total,
    required this.category,
    required this.showCategory,
    this.zh,
  });

  final String label;

  /// 中文对照。没有（界面不是中文）时为 null，那一行只显示英文——
  /// **英文才是模型的原话**，中文只是补充。
  final String? zh;

  final int count;
  final int total;

  /// 未映射时为 null——那一行会有个「未映射」的标记。
  final SleepCategory? category;

  /// 要不要显示「大类 / 未映射」那一列。
  ///
  /// 为 false 时**整列不渲染**（不只是留空）：映射表没拿到的时候，
  /// 「未映射」是个假消息，而空着那一列又把宽度白占了。
  final bool showCategory;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.labelSmall?.copyWith(color: AppColors.textDim);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 54,
            child: Text(
              '$count',
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.textDim,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 10),
          // 标签名不截断：这是模型的原话，正是核查要看的东西，
          // 长名字（"Male speech, man speaking"）换行显示，不省略。
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: theme.textTheme.bodySmall),
                if (zh != null) Text(zh!, style: dim?.copyWith(height: 1.4)),
              ],
            ),
          ),
          if (showCategory) ...[
            const SizedBox(width: 8),
            SizedBox(
              width: 62,
              child: Text(
                category?.label(context) ??
                    context.l10n.reportRawLabelsUnmappedTag,
                textAlign: TextAlign.right,
                style: category == null
                    ? dim?.copyWith(color: AppColors.statusWarning)
                    : dim,
              ),
            ),
          ],
          SizedBox(
            width: 46,
            child: Text(
              total == 0 ? '' : '${(count / total * 100).toStringAsFixed(1)}%',
              textAlign: TextAlign.right,
              style: dim,
            ),
          ),
        ],
      ),
    );
  }
}
