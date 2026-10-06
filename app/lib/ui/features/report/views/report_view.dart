import 'package:flutter/material.dart';

import '../../../../domain/analysis/recording_diagnosis.dart';
import '../../../../domain/analysis/session_insights.dart';
import '../../../../domain/analysis/sleep_score.dart';
import '../../../../domain/models/recording_session.dart';
import '../../../../domain/models/sleep_category.dart';
import '../../../../domain/models/sound_event.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/charts.dart';
import '../../../core/widgets/score_gauge.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/widgets/sound_timeline.dart';
import '../view_models/report_view_model.dart';

/// 单晚睡眠报告。
///
/// 版式参考蜗牛睡眠：环形指标打头，下面是分段的图表卡片。
/// 但内容只放**我们真实算得出来的**——鼾声指数、声音事件时间线、类别分布。
/// 睡眠分期（浅睡/深睡）需要加速度计或 PPG，我们没有采集，就不编造。
class ReportView extends StatelessWidget {
  const ReportView({super.key, required this.viewModel});

  final ReportViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final session = viewModel.session;
        final theme = Theme.of(context);
        final started = session.startedAt;
        final diagnoses = diagnoseSession(session);

        return Scaffold(
          appBar: AppBar(
            title: const Text('睡眠报告'),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(24),
              child: Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '${started.year}年${started.month}月${started.day}日 '
                    '${_hhmm(started)} 开始'
                    '${session.endedAt != null ? ' · 共 ${formatSpan(session.duration.inSeconds.toDouble())}' : ''}',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.textDim),
                  ),
                ),
              ),
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              _OverviewCard(session: session),
              // 放在概览之后、图表之前：有问题时用户应当**在按错误的理解
              // 读完一整页图表之前**就看到它。没有问题时整张卡不出现。
              if (diagnoses.isNotEmpty) ...[
                const SizedBox(height: 12),
                _DiagnosisCard(diagnoses: diagnoses),
              ],
              const SizedBox(height: 12),
              _ScoreBreakdownCard(session: session),
              const SizedBox(height: 12),
              _TimelineCard(session: session),
              const SizedBox(height: 12),
              _HourlyCard(session: session),
              const SizedBox(height: 12),
              _DurationCard(session: session),
              const SizedBox(height: 12),
              _DistributionCard(session: session),
              const SizedBox(height: 12),
              _PipelineCard(session: session),
              const SizedBox(height: 12),
              _EventListCard(viewModel: viewModel),
            ],
          ),
        );
      },
    );
  }

  static String _hhmm(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

/// 头部：环形评分 + 两个关键数字。
///
/// 有评分时圆环显示评分（越高越好），录音太短拿不到评分时退回显示鼾声指数。
/// 标签会跟着变，不会让人误读同一个圆环。
class _OverviewCard extends StatelessWidget {
  const _OverviewCard({required this.session});

  final RecordingSession session;

  @override
  Widget build(BuildContext context) {
    final stats = session.stats;
    final score = scoreSession(session);

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        child: Row(
          children: [
            if (score != null)
              ScoreGauge(
                value: score.total.toDouble(),
                label: '睡眠声音评分',
                subLabel: score.grade,
                higherIsBetter: true,
              )
            else
              ScoreGauge(
                value: stats.snoreIndex.clamp(0, 100),
                label: '鼾声指数',
                formattedValue: stats.snoreIndex.toStringAsFixed(1),
                unit: '%',
                subLabel: '录音太短，暂不计分',
              ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MetricTile(
                    value: stats.snoreIndex.toStringAsFixed(1),
                    unit: '%',
                    label: '鼾声指数',
                  ),
                  const SizedBox(height: 14),
                  MetricTile(
                    value: formatSpan(stats.snoreSeconds),
                    label: '鼾声总时长',
                    hint: '共 ${stats.snoreEventCount} 段',
                  ),
                  const SizedBox(height: 14),
                  MetricTile(
                    value: '${stats.eventCount}',
                    label: '声音事件',
                    unit: '次',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 评分构成。把扣分逐项摊开，用户能自己验算，也看得出分是怎么来的。
/// 录音质量诊断。
///
/// 存在的理由是：**报告为空有两种原因，而在界面上长得一模一样**——
/// 你昨晚确实没打鼾，还是麦克风被挡住了。用户分不清，
/// 于是要么白高兴一场，要么把能用的功能当成坏的。
///
/// 包里已经有全部需要的数字（都来自 [SessionStats]），这里只是把它翻译成人话。
class _DiagnosisCard extends StatelessWidget {
  const _DiagnosisCard({required this.diagnoses});

  final List<Diagnosis> diagnoses;

  @override
  Widget build(BuildContext context) {
    final warn = hasWarnings(diagnoses);

    return SectionCard(
      title: '录音质量',
      subtitle: warn ? '有几处可能影响这次结果的判断' : '几个说明',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < diagnoses.length; i++) ...[
            if (i > 0) const SizedBox(height: 16),
            _DiagnosisRow(diagnosis: diagnoses[i]),
          ],
        ],
      ),
    );
  }
}

class _DiagnosisRow extends StatelessWidget {
  const _DiagnosisRow({required this.diagnosis});

  final Diagnosis diagnosis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWarning = diagnosis.level == DiagnosisLevel.warning;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          isWarning ? Icons.warning_amber : Icons.info_outline,
          size: 18,
          color: isWarning ? AppColors.statusWarning : AppColors.textDim,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                diagnosis.title,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                diagnosis.detail,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textDim, height: 1.6),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ScoreBreakdownCard extends StatelessWidget {
  const _ScoreBreakdownCard({required this.session});

  final RecordingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final score = scoreSession(session);

    if (score == null) {
      return SectionCard(
        title: '睡眠声音评分',
        child: Text(
          '录音不足 ${kMinScorableDuration.inMinutes} 分钟，不给出评分——'
          '太短的录音算出来的"一夜评分"没有参考价值。',
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.textDim, height: 1.6),
        ),
      );
    }

    return SectionCard(
      title: '评分构成',
      subtitle: '满分 100，逐项扣分',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final d in score.deductions) ...[
            Row(
              children: [
                SizedBox(
                  width: 76,
                  child: Text(d.label, style: theme.textTheme.bodySmall),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: Stack(
                      children: [
                        Container(height: 10, color: AppColors.surfaceHigh),
                        FractionallySizedBox(
                          widthFactor:
                              (d.points / d.maxPoints).clamp(0.0, 1.0),
                          child: Container(
                            height: 10,
                            color: _deductionColor(d.points / d.maxPoints),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 52,
                  child: Text(
                    d.points <= 0 ? '不扣' : '−${d.points.round()}',
                    textAlign: TextAlign.right,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: d.points <= 0
                          ? AppColors.textDim
                          : _deductionColor(d.points / d.maxPoints),
                    ),
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 76, top: 2, bottom: 10),
              child: Text(d.detail,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.textDim)),
            ),
          ],
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('100 分逐项扣完', style: theme.textTheme.bodySmall),
              Text('= ${score.total}',
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 14),
          // 这一段必须原样展示。分数很容易被当成"睡眠质量"，
          // 而它只反映声音——不说清楚就是误导。
          Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surfaceHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.info_outline,
                    size: 15, color: AppColors.textDim),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(score.caveat,
                      style: theme.textTheme.labelSmall?.copyWith(
                          color: AppColors.textDim, height: 1.6)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Color _deductionColor(double ratio) {
    if (ratio <= 0.001) return AppColors.statusGood;
    if (ratio < 0.4) return AppColors.statusWarning;
    return AppColors.statusCritical;
  }
}

/// 整夜声音时间线 + 图例。
class _TimelineCard extends StatelessWidget {
  const _TimelineCard({required this.session});

  final RecordingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 时长优先用会话跨度；没有结束时间就退回分析时长。
    final total = session.duration.inSeconds.toDouble() > 0
        ? session.duration.inSeconds.toDouble()
        : session.stats.analyzedSeconds;

    return SectionCard(
      title: '整夜声音',
      subtitle: '点或拖动图表可查看具体事件',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SoundTimeline(
            events: session.events,
            totalSeconds: total,
            startedAt: session.startedAt,
          ),
          const SizedBox(height: 14),
          // 图例：3 个颜色大类。柱高区分细类，在下面说明。
          CategoryLegend(
            entries: {
              for (final c in SoundClass.values)
                if (session.events.any((e) => e.label.soundClass == c))
                  c.label: c.color,
            },
          ),
          const SizedBox(height: 8),
          Text(
            '柱子越高，事件越"突出"——鼾声最高，呼吸和环境声最低。'
            '具体类别在下方事件明细里。',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.textDim),
          ),
        ],
      ),
    );
  }
}

/// 每小时声音分布。
///
/// 回答「我几点打鼾最多」。堆叠柱里鼾声用大类色、其他声音用中性灰——
/// 这是"强调"式呈现：读者要的是鼾声的时段分布，其余只是背景信息。
class _HourlyCard extends StatelessWidget {
  const _HourlyCard({required this.session});

  final RecordingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final buckets = hourlyBreakdown(session);

    if (buckets.isEmpty) {
      return SectionCard(
        title: '每小时分布',
        child: Text('没有可统计的声音事件',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textDim)),
      );
    }

    // 找出鼾声最重的钟点，直接写进副标题——省得读者自己在图上找
    final peak = buckets.reduce((a, b) =>
        a.snoreSeconds >= b.snoreSeconds ? a : b);
    final subtitle = peak.snoreSeconds > 0
        ? '${peak.hour} 点前后鼾声最集中，合计 ${formatSpan(peak.snoreSeconds)}'
        : '这一晚各时段鼾声都不明显';

    return SectionCard(
      title: '每小时分布',
      subtitle: subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HourlyChart(buckets: buckets),
          const SizedBox(height: 12),
          CategoryLegend(entries: {
            '鼾声': SleepCategory.snore.soundClass.color,
            '其他声音': AppColors.textDim.withValues(alpha: 0.45),
          }),
          const SizedBox(height: 8),
          Text(
            '横轴是钟点，纵轴是该小时内声音的总时长。',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.textDim),
          ),
        ],
      ),
    );
  }
}

/// 鼾声段的单次时长分布。
///
/// 回答「一次打鼾持续多久」——比总数更能说明严重程度：
/// 十几秒的碎鼾和几分钟的连续鼾，意义完全不同。
class _DurationCard extends StatelessWidget {
  const _DurationCard({required this.session});

  final RecordingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bins = snoreDurationHistogram(session.events);
    final total = bins.fold<int>(0, (a, b) => a + b.count);

    if (total == 0) {
      return SectionCard(
        title: '鼾声段时长',
        child: Text('这一晚没有检出鼾声',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textDim)),
      );
    }

    final longest = session.snoreEvents.isEmpty
        ? 0.0
        : session.snoreEvents
            .map((e) => e.durationSeconds)
            .reduce((a, b) => a > b ? a : b);

    return SectionCard(
      title: '鼾声段时长',
      subtitle: '共 $total 段，最长一段 ${formatSpan(longest)}',
      child: DurationHistogram(bins: bins),
    );
  }
}

/// 类别分布：按大类分组、彩色，每行都直接标注名称和数值。
///
/// 每行有独立文字标签，所以颜色只是辅助分组，不承担识别职责。
class _DistributionCard extends StatelessWidget {
  const _DistributionCard({required this.session});

  final RecordingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 按事件总时长统计，比平均概率更好理解。
    final byCategory = <SleepCategory, double>{};
    for (final e in session.events) {
      if (e.label.isRecessive) continue;
      byCategory[e.label] = (byCategory[e.label] ?? 0) + e.durationSeconds;
    }

    if (byCategory.isEmpty) {
      return SectionCard(
        title: '类别分布',
        child: Text('这一晚没有检出可分类的声音事件',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textDim)),
      );
    }

    final sorted = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxValue = sorted.first.value;

    return SectionCard(
      title: '类别分布',
      subtitle: '按各类声音的总时长排序',
      child: Column(
        children: [
          for (final entry in sorted)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _DistributionRow(
                label: entry.key.label,
                seconds: entry.value,
                fraction: maxValue <= 0 ? 0 : entry.value / maxValue,
                color: entry.key.soundClass.color,
              ),
            ),
        ],
      ),
    );
  }
}

class _DistributionRow extends StatelessWidget {
  const _DistributionRow({
    required this.label,
    required this.seconds,
    required this.fraction,
    required this.color,
  });

  final String label;
  final double seconds;
  final double fraction;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(
          width: 68,
          child: Text(label, style: theme.textTheme.bodySmall),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: Stack(
              children: [
                Container(height: 12, color: AppColors.surfaceHigh),
                FractionallySizedBox(
                  widthFactor: fraction.clamp(0.0, 1.0),
                  child: Container(height: 12, color: color),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 52,
          child: Text(
            formatSpan(seconds),
            textAlign: TextAlign.right,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.textDim),
          ),
        ),
      ],
    );
  }
}

/// 分析过程：解释"为什么省电"以及端侧实际干了多少活。
class _PipelineCard extends StatelessWidget {
  const _PipelineCard({required this.session});

  final RecordingSession session;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = session.stats;
    final ratio = (s.inferenceRatio * 100);

    return SectionCard(
      title: '端侧分析',
      subtitle: '安静片段被直接跳过，没有送进模型',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MetricRow(
            children: [
              MetricTile(value: '${s.windowsTotal}', label: '处理窗口'),
              MetricTile(
                value: '${s.windowsInferred}',
                label: '送进模型',
                hint: '${ratio.toStringAsFixed(0)}%',
                valueColor: AppColors.accent,
              ),
              MetricTile(
                value: '${s.windowsVadSkipped}',
                label: '能量门控跳过',
                valueColor: AppColors.statusGood,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('推理占比',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textDim)),
              const SizedBox(width: 10),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: s.inferenceRatio.clamp(0.0, 1.0),
                    minHeight: 8,
                    backgroundColor: AppColors.surfaceHigh,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text('${ratio.toStringAsFixed(0)}%',
                  style: theme.textTheme.bodySmall),
            ],
          ),
          if (s.windowsLowConfidence > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                '另有 ${s.windowsLowConfidence} 个窗口模型没把握，判为未识别，不计入事件。',
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: AppColors.textDim),
              ),
            ),
        ],
      ),
    );
  }
}

/// 事件明细列表。有音频片段的事件可以点播放。
class _EventListCard extends StatelessWidget {
  const _EventListCard({required this.viewModel});

  final ReportViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final events = viewModel.session.events;

    if (events.isEmpty) {
      return SectionCard(
        title: '事件明细',
        child: Text('没有检出声音事件',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textDim)),
      );
    }

    final playable = events.where((e) => e.hasClip).length;

    return SectionCard(
      title: '事件明细',
      subtitle: playable > 0
          ? '共 ${events.length} 条，其中 $playable 条可以试听'
          : '共 ${events.length} 条',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (viewModel.error != null) ...[
            _InlineError(message: viewModel.error!),
            const SizedBox(height: 10),
          ],
          for (var i = 0; i < events.length; i++)
            _EventRow(
              event: events[i],
              startedAt: viewModel.session.startedAt,
              isPlaying: viewModel.isPlaying(i),
              isLoading: viewModel.isLoading(i),
              onPlay: events[i].hasClip ? () => viewModel.togglePlay(i) : null,
            ),
        ],
      ),
    );
  }
}

class _InlineError extends StatelessWidget {
  const _InlineError({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.statusCritical.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline,
              size: 15, color: AppColors.statusCritical),
          const SizedBox(width: 8),
          Expanded(
            child: Text(message,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.statusCritical)),
          ),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.startedAt,
    required this.isPlaying,
    required this.isLoading,
    required this.onPlay,
  });

  final SoundEvent event;
  final DateTime startedAt;
  final bool isPlaying;
  final bool isLoading;

  /// 为 null 表示这条没有片段，不显示播放按钮。
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = startedAt.add(Duration(seconds: event.startSeconds.round()));
    final clock = '${at.hour.toString().padLeft(2, '0')}:'
        '${at.minute.toString().padLeft(2, '0')}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(clock,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.textDim,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
          const SizedBox(width: 12),
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: event.label.soundClass.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(event.label.label,
                style: theme.textTheme.bodyMedium),
          ),
          Text('${event.durationSeconds.round()}s',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textDim)),
          SizedBox(
            width: 40,
            child: onPlay == null
                ? null
                : IconButton(
                    onPressed: isLoading ? null : onPlay,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    tooltip: isPlaying ? '停止' : '试听',
                    icon: isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(
                            isPlaying
                                ? Icons.stop_circle_outlined
                                : Icons.play_circle_outline,
                            size: 22,
                            color: isPlaying
                                ? AppColors.statusCritical
                                : AppColors.accent,
                          ),
                  ),
          ),
        ],
      ),
    );
  }
}
