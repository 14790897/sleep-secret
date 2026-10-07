import 'package:flutter/material.dart';

import '../../../../domain/analysis/session_insights.dart';
import '../../../../domain/models/recording_session.dart';
import '../../../core/theme.dart';
import '../../../core/l10n/l10n_context.dart';
import '../../../core/widgets/charts.dart';
import '../../../core/widgets/section_card.dart';

/// 跨晚趋势卡片。
///
/// 回答「我在变好吗」。参考线用**使用者自己的平均值**，不用固定的
/// "医学阈值"——鼾声指数多少算严重，取决于个人基线和临床背景，
/// 我这边没有依据去定义一个通用阈值，画一条线反而会误导。
class TrendCard extends StatelessWidget {
  const TrendCard({super.key, required this.sessions});

  final List<RecordingSession> sessions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final points = buildTrend(sessions);
    final summary = summarizeTrend(points);

    if (summary == null || points.length < 2) {
      // 只有一晚时不画趋势，直接告诉用户还差什么
      if (points.isEmpty) return const SizedBox.shrink();
      return SectionCard(
        title: context.l10n.trendTitle,
        child: Text(
          context.l10n.trendSingleNight,
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textDim),
        ),
      );
    }

    return SectionCard(
      title: context.l10n.trendTitle,
      subtitle: context.l10n.trendSubtitle(
          summary.nights, summary.averageIndex.toStringAsFixed(1)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TrendChart(
            points: points,
            threshold: summary.averageIndex,
            thresholdLabel: context.l10n.trendYourAverage,
          ),
          const SizedBox(height: 16),
          MetricRow(
            children: [
              MetricTile(
                value: summary.averageIndex.toStringAsFixed(1),
                unit: '%',
                label: context.l10n.trendAverage,
              ),
              MetricTile(
                value: summary.bestIndex.toStringAsFixed(1),
                unit: '%',
                label: context.l10n.trendBestNight,
                valueColor: AppColors.statusGood,
              ),
              MetricTile(
                value: summary.worstIndex.toStringAsFixed(1),
                unit: '%',
                label: context.l10n.trendWorstNight,
                valueColor: AppColors.statusCritical,
              ),
            ],
          ),
          const SizedBox(height: 14),
          _ChangeNote(summary: summary),
        ],
      ),
    );
  }
}

/// 把"变好还是变差"写成一句话。
///
/// 刻意不给方向加"健康建议"式的措辞——单看鼾声时长变化说明不了
/// 健康问题，只陈述数据本身。
class _ChangeNote extends StatelessWidget {
  const _ChangeNote({required this.summary});

  final TrendSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final delta = summary.changeFromFirst;
    final (text, color, icon) = summary.improving
        ? (
            context.l10n.trendDeltaDown(delta.abs().toStringAsFixed(1)),
            AppColors.statusGood,
            Icons.trending_down
          )
        : summary.worsening
            ? (
                context.l10n.trendDeltaUp(delta.abs().toStringAsFixed(1)),
                AppColors.statusCritical,
                Icons.trending_up
              )
            : (context.l10n.trendDeltaFlat, AppColors.textDim, Icons.trending_flat);

    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: theme.textTheme.bodySmall?.copyWith(color: color)),
        ),
        Text(
          context.l10n.trendTotalNights(summary.nights),
          style: theme.textTheme.labelSmall?.copyWith(color: AppColors.textDim),
        ),
      ],
    );
  }
}
