import 'package:flutter/material.dart';

import '../../../../domain/analysis/session_insights.dart';
import '../../../../domain/models/recording_session.dart';
import '../../../core/theme.dart';
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
        title: '鼾声指数趋势',
        child: Text(
          '再记录一晚就能看出变化了。',
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textDim),
        ),
      );
    }

    return SectionCard(
      title: '鼾声指数趋势',
      subtitle: '最近 ${summary.nights} 晚，虚线是你的平均值 '
          '${summary.averageIndex.toStringAsFixed(1)}%',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TrendChart(
            points: points,
            threshold: summary.averageIndex,
            thresholdLabel: '你的平均',
          ),
          const SizedBox(height: 16),
          MetricRow(
            children: [
              MetricTile(
                value: summary.averageIndex.toStringAsFixed(1),
                unit: '%',
                label: '平均',
              ),
              MetricTile(
                value: summary.bestIndex.toStringAsFixed(1),
                unit: '%',
                label: '最好一晚',
                valueColor: AppColors.statusGood,
              ),
              MetricTile(
                value: summary.worstIndex.toStringAsFixed(1),
                unit: '%',
                label: '最差一晚',
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
            '比第一晚少了 ${delta.abs().toStringAsFixed(1)} 个百分点',
            AppColors.statusGood,
            Icons.trending_down
          )
        : summary.worsening
            ? (
                '比第一晚多了 ${delta.abs().toStringAsFixed(1)} 个百分点',
                AppColors.statusCritical,
                Icons.trending_up
              )
            : ('和第一晚基本持平', AppColors.textDim, Icons.trending_flat);

    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text,
              style: theme.textTheme.bodySmall?.copyWith(color: color)),
        ),
        Text(
          '共 ${summary.nights} 晚',
          style: theme.textTheme.labelSmall?.copyWith(color: AppColors.textDim),
        ),
      ],
    );
  }
}
