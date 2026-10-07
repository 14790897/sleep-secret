import 'package:flutter/material.dart';

import '../../../../domain/analysis/analysis_config.dart';
import '../../../../domain/analysis/apnea_signals.dart';
import '../../../../domain/analysis/decibel.dart';
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
import '../../../core/l10n/domain_text.dart';
import '../../../core/l10n/l10n_context.dart';
import '../../../core/l10n/ui_message_text.dart';
import '../../../core/widgets/sound_timeline.dart';
import '../view_models/report_view_model.dart';

/// 低于它就认为**把握不大**，界面上标成警示色。
///
/// 直接引用配置值而不是写死 0.25——这是个**展示用的参考线**，
/// 不参与任何判定（判定里已经没有置信度门槛了），
/// 但显示和配置必须一致，否则标记会自相矛盾。
///
/// 顺带一个好性质：这个值正好等于**旧置信度门槛**。所以被标出来的条目，
/// 正好就是那道门槛当年会直接丢掉的那些——一眼能看出它藏掉了什么。
final double _lowConfidenceMark = const AnalysisConfig().lowConfidenceThreshold;

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
        final signals = analyzeApneaSignals(session);

        return Scaffold(
          appBar: AppBar(
            title: Text(context.l10n.reportViewTitle),
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(24),
              child: Padding(
                padding: const EdgeInsets.only(left: 16, bottom: 8),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    context.l10n.reportHeaderStart(started.year,
                            started.month, started.day, _hhmm(started)) +
                        (session.endedAt != null
                            ? context.l10n.reportHeaderTotal(formatSpan(
                                session.duration.inSeconds.toDouble()))
                            : ''),
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
              // 高危信号卡排在「鼾声录音」之前：它是这一页里唯一一条和健康
              // 直接相关的发现，而且**每一条都能点开听**——想听那一声倒吸气
              // 的人不该先翻过一整屏鼾声。
              //
              // 两种情况才出现：新录音（有没有信号都显示），或者老记录但有
              // 正经分析数据（要解释一句「那一版不记这个」）。
              if (signals.collected || session.stats.windowsInferred > 0) ...[
                const SizedBox(height: 12),
                _ApneaSignalCard(viewModel: viewModel, summary: signals),
              ],
              // 放在概览区之后、图表之前：想听一段鼾声是打开报告后最直接的
              // 动作，不该让人先翻过八张统计卡才找到播放键。
              //
              // 没打鼾的一晚整张卡不出现——否则列表里会多出一段空白。
              // 高危信号不算「鼾声」：它们有自己那张卡。
              if (session.events
                  .any((e) => !e.isSignal && (e.hasClip || e.isSnore))) ...[
                const SizedBox(height: 12),
                _ClipListCard(viewModel: viewModel),
              ],
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
                label: context.l10n.reportScoreTitle,
                subLabel: score.gradeLabel(context),
                higherIsBetter: true,
              )
            else
              ScoreGauge(
                value: stats.snoreIndex.clamp(0, 100),
                label: context.l10n.reportSnoreIndex,
                formattedValue: stats.snoreIndex.toStringAsFixed(1),
                unit: '%',
                subLabel: context.l10n.reportTooShortNoScore,
              ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MetricTile(
                    value: stats.snoreIndex.toStringAsFixed(1),
                    unit: '%',
                    label: context.l10n.reportSnoreIndex,
                  ),
                  const SizedBox(height: 14),
                  MetricTile(
                    value: formatSpan(stats.snoreSeconds),
                    label: context.l10n.reportSnoreTotal,
                    hint: context.l10n.reportSnoreSegments(stats.snoreEventCount),
                  ),
                  const SizedBox(height: 14),
                  MetricTile(
                    value: '${stats.eventCount}',
                    label: context.l10n.reportSoundEvents,
                    unit: context.l10n.reportTimesUnit,
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
      title: context.l10n.reportDiagnosisTitle,
      subtitle: warn
          ? context.l10n.reportDiagnosisWarn
          : context.l10n.reportDiagnosisInfo,
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
                diagnosis.title(context),
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 4),
              Text(
                diagnosis.detail(context),
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
        title: context.l10n.reportScoreTitle,
        child: Text(
          context.l10n.reportTooShortBody(kMinScorableDuration.inMinutes),
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.textDim, height: 1.6),
        ),
      );
    }

    return SectionCard(
      title: context.l10n.reportScoreBreakdown,
      subtitle: context.l10n.reportScoreBreakdownSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final d in score.deductions) ...[
            Row(
              children: [
                SizedBox(
                  width: 76,
                  child: Text(d.label(context), style: theme.textTheme.bodySmall),
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
                    d.points <= 0
                        ? context.l10n.reportNoDeduction
                        : '−${d.points.round()}',
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
              child: Text(d.detail(context),
                  style: theme.textTheme.labelSmall
                      ?.copyWith(color: AppColors.textDim)),
            ),
          ],
          const Divider(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(context.l10n.reportHundredPoints,
                  style: theme.textTheme.bodySmall),
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
                  child: Text(score.caveat(context),
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

/// 把**带录音的片段**单独收到一张卡里。
///
/// ## 为什么要单独一张卡
///
/// 这些片段原本只出现在「事件明细」里，而那里是按时间排的**全部**事件。
/// 实测一晚 81 条事件里只有 9 条带音频——播放键夹在环境噪音、呼吸声、
/// 翻身中间，想听一段得先一段一段找过去。
///
/// ## 和「事件明细」的关系
///
/// 用的是**原来的事件下标**（`viewModel.togglePlay(i)` 认的就是它），
/// 所以两处共享同一套播放状态：在任何一处点了播放，另一处也跟着变。
/// 这也是为什么不新造一个行控件——用同一个 [_EventRow]，两处长得一致。
///
/// **只有鼾声会存片段**（见 `night_analysis_engine._saveClipFor`），
/// 所以标题直接叫「鼾声录音」。
/// 「疑似呼吸暂停的信号」卡。
///
/// ## 它和「鼾声录音」卡为什么是分开的两张
///
/// 两张都能点开听，但说的不是一回事：一张是整夜鼾声的样本，一张是模型认出来
/// 的几种特定声音。混在一起会有两个后果——「鼾声录音」里冒出「倒吸气」会被
/// 当成写错了；而真正想找倒吸气的人得在一屏鼾声里翻。
///
/// ## 「没数据」和「没有」必须分开说
///
/// 升级前的记录里事件的 `signal` 全是 null，和「这一夜确实一个都没认出来」
/// 长得一模一样。前者说「没查」，后者说「查了没有」，措辞完全不同——
/// 见 [ApneaSignalSummary.collected]。
class _ApneaSignalCard extends StatelessWidget {
  const _ApneaSignalCard({required this.viewModel, required this.summary});

  final ReportViewModel viewModel;
  final ApneaSignalSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final session = viewModel.session;
    final note = theme.textTheme.bodySmall
        ?.copyWith(color: AppColors.textDim, height: 1.7);

    final rows = <int>[
      for (var i = 0; i < session.events.length; i++)
        if (session.events[i].isSignal) i,
    ];

    return SectionCard(
      key: ReportKeys.apneaSignals,
      title: context.l10n.reportSignalsTitle,
      subtitle: context.l10n.reportSignalsSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!summary.collected)
            Text(summary.notCollectedNote(context), style: note)
          else if (summary.isEmpty)
            Text(summary.emptyNote(context), style: note)
          else ...[
            Text(
              summary.countNote(context),
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 10),
            if (viewModel.error != null) ...[
              _InlineError(message: viewModel.error!.message(context)),
              const SizedBox(height: 10),
            ],
            for (final i in rows)
              _EventRow(
                key: ReportKeys.signalRow(i),
                event: session.events[i],
                startedAt: session.startedAt,
                isPlaying: viewModel.isPlaying(i),
                isLoading: viewModel.isLoading(i),
                // 没留下片段就不给播放键——给一个点了没反应的按钮
                // 比没有按钮更让人以为应用坏了。
                onPlay: session.events[i].hasClip
                    ? () => viewModel.togglePlay(i)
                    : null,
              ),
          ],
          // 认出来了才需要那段说明。什么都没认出来时它只是在解释一个
          // 还不存在的问题，白占四行。
          if (summary.collected) ...[
            const SizedBox(height: 12),
            Text(summary.caveat(context), style: note),
          ],
        ],
      ),
    );
  }
}

class _ClipListCard extends StatelessWidget {
  const _ClipListCard({required this.viewModel});

  final ReportViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final events = viewModel.session.events;
    final clipIndexes = <int>[
      for (var i = 0; i < events.length; i++)
        // 高危信号有自己的那张卡（[_ApneaSignalCard]），不在这儿重复。
        // 这张卡标题是「鼾声录音」，里面列出「倒吸气」会被当成写错了。
        if (events[i].hasClip && !events[i].isSignal) i,
    ];

    if (clipIndexes.isEmpty) {
      // 走到这儿说明这一晚检出了鼾声、但一段录音都没留下。
      // 说清楚为什么，不然「怎么没有」会变成一个谜。
      return SectionCard(
        key: ReportKeys.snoreClips,
        title: context.l10n.reportClipsTitle,
        child: Text(
          context.l10n.reportClipsNone,
          style: theme.textTheme.bodySmall
              ?.copyWith(color: AppColors.textDim, height: 1.7),
        ),
      );
    }

    final totalSeconds = clipIndexes.fold<double>(
        0, (sum, i) => sum + events[i].durationSeconds);

    return SectionCard(
      key: ReportKeys.snoreClips,
      title: context.l10n.reportClipsTitle,
      subtitle: context.l10n.reportClipsSubtitle(
          clipIndexes.length, _clipDurationLabel(context, totalSeconds)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (viewModel.error != null) ...[
            _InlineError(message: viewModel.error!.message(context)),
            const SizedBox(height: 10),
          ],
          for (final i in clipIndexes)
            _EventRow(
              key: ReportKeys.clipRow(i),
              event: events[i],
              startedAt: viewModel.session.startedAt,
              isPlaying: viewModel.isPlaying(i),
              isLoading: viewModel.isLoading(i),
              onPlay: () => viewModel.togglePlay(i),
            ),
        ],
      ),
    );
  }
}

/// 报告页的测试锚点。
///
/// ## 为什么要有这个东西
///
/// 原来测试是**按标题文字**找卡片的：
///
///     find.ancestor(of: find.text('事件明细'), matching: find.byType(SectionCard))
///
/// 那是拿用户可见的文案当结构标识。改一次措辞，一堆断言就散架；
/// 而且失败信息只会说「找不到」，看不出是文案改了还是卡片真的没了。
/// 这一场里已经咬到两次：`textContaining('共 2 段')` 撞上「鼾声段时长」卡里的
/// 同一句话；上面那种按文字定位的写法到处都是。
///
/// ## 分工
///
/// - **定位用 key**：这张卡、这一行在哪儿 → [snoreClips] / [clipRow] 等
/// - **文案用 text**：用户看到的是不是这句话 → `find.text('鼾声录音')`
///
/// 两者都要有，但不能混。断言「标题写的是不是『鼾声录音』」就该用 text——
/// 那句话变了本来就该有人看一眼。反过来，`_EventRow` 的播放键用 key 定位，
/// 就没人会因为改了个字而挂掉。
abstract final class ReportKeys {
  /// 「鼾声录音」卡。
  static const ValueKey<String> snoreClips = ValueKey('section-snore-clips');

  /// 「事件明细」卡。
  static const ValueKey<String> eventDetail = ValueKey('section-event-detail');

  /// 「鼾声录音」卡里第 i 个事件的那一行。**i 是事件在会话里的原始下标**，
  /// 和「事件明细」里指的是同一条。
  static ValueKey<String> clipRow(int i) => ValueKey('clip-row-$i');

  /// 「事件明细」里第 i 个事件的那一行。
  static ValueKey<String> eventRow(int i) => ValueKey('event-row-$i');

  /// 「疑似呼吸暂停的信号」卡。
  static const ValueKey<String> apneaSignals = ValueKey('section-apnea-signals');

  /// 「疑似呼吸暂停的信号」卡里第 i 个事件的那一行。
  /// **i 同样是事件在会话里的原始下标**，和别处指的是同一条。
  static ValueKey<String> signalRow(int i) => ValueKey('signal-row-$i');

}

/// 片段总时长。
///
/// **不能直接用 [formatSpan]**——它只精确到分钟，一段 30 秒的鼾声会显示成
/// 「0m」。鼾声片段本来就常常只有几十秒，那个精度在这儿等于没写。
String _clipDurationLabel(BuildContext context, double seconds) {
  final total = seconds.round();
  if (total < 60) return context.l10n.reportDurSeconds(total);
  final minutes = total ~/ 60;
  final rest = total % 60;
  return rest == 0
      ? context.l10n.reportDurMinutes(minutes)
      : context.l10n.reportDurMinSec(minutes, rest);
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
      title: context.l10n.reportTimelineTitle,
      subtitle: context.l10n.reportTimelineSubtitle,
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
                  c.label(context): c.color,
            },
          ),
          const SizedBox(height: 8),
          Text(
            context.l10n.reportTimelineHint,
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
        title: context.l10n.reportHourlyTitle,
        child: Text(context.l10n.hourlyEmpty,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textDim)),
      );
    }

    // 找出鼾声最重的钟点，直接写进副标题——省得读者自己在图上找
    final peak = buckets.reduce((a, b) =>
        a.snoreSeconds >= b.snoreSeconds ? a : b);
    final subtitle = peak.snoreSeconds > 0
        ? context.l10n.reportHourlyPeak(
            peak.hour, formatSpan(peak.snoreSeconds))
        : context.l10n.reportHourlyFlat;

    return SectionCard(
      title: context.l10n.reportHourlyTitle,
      subtitle: subtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          HourlyChart(buckets: buckets),
          const SizedBox(height: 12),
          CategoryLegend(entries: {
            context.l10n.legendSnore: SleepCategory.snore.soundClass.color,
            context.l10n.legendOther: AppColors.textDim.withValues(alpha: 0.45),
          }),
          const SizedBox(height: 8),
          Text(
            context.l10n.reportHourlyHint,
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
        title: context.l10n.reportDurationTitle,
        child: Text(context.l10n.histogramEmpty,
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
      title: context.l10n.reportDurationTitle,
      subtitle: context.l10n.reportDurationSubtitle(total, formatSpan(longest)),
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
        title: context.l10n.reportDistributionTitle,
        child: Text(context.l10n.reportDistributionEmpty,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textDim)),
      );
    }

    final sorted = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final maxValue = sorted.first.value;

    return SectionCard(
      title: context.l10n.reportDistributionTitle,
      subtitle: context.l10n.reportDistributionSubtitle,
      child: Column(
        children: [
          for (final entry in sorted)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: _DistributionRow(
                label: entry.key.label(context),
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
      title: context.l10n.reportPipelineTitle,
      subtitle: context.l10n.reportPipelineSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MetricRow(
            children: [
              MetricTile(
                  value: '${s.windowsTotal}',
                  label: context.l10n.recordingWindowsProcessed),
              MetricTile(
                value: '${s.windowsInferred}',
                label: context.l10n.recordingWindowsInferred,
                hint: '${ratio.toStringAsFixed(0)}%',
                valueColor: AppColors.accent,
              ),
              MetricTile(
                value: '${s.windowsVadSkipped}',
                label: context.l10n.reportPipelineSkipped,
                valueColor: AppColors.statusGood,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text(context.l10n.reportInferenceRatio,
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
                context.l10n.reportLowConfidenceNote(
                    s.windowsLowConfidence,
                    AnalysisConfig().lowConfidenceThreshold.toString()),
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
        key: ReportKeys.eventDetail,
        title: context.l10n.reportEventsTitle,
        child: Text(context.l10n.reportEventsEmpty,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: AppColors.textDim)),
      );
    }

    final playable = events.where((e) => e.hasClip).length;

    return SectionCard(
      key: ReportKeys.eventDetail,
      title: context.l10n.reportEventsTitle,
      subtitle: playable > 0
          ? context.l10n.reportEventsSubtitle(events.length, playable)
          : context.l10n.reportEventsSubtitlePlain(events.length),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (viewModel.error != null) ...[
            _InlineError(message: viewModel.error!.message(context)),
            const SizedBox(height: 10),
          ],
          for (var i = 0; i < events.length; i++)
            _EventRow(
              key: ReportKeys.eventRow(i),
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
    super.key,
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
            child: Row(
              children: [
                Flexible(
                  child: Text(event.displayName(context),
                      style: theme.textTheme.bodyMedium),
                ),
                const SizedBox(width: 6),
                // 把把握程度露出来。
                //
                // 以前这里只有类别，「0.93 的鼾声」和「0.33 的鼾声」长得一模一样，
                // 而后者其实是模型在两个几乎相同的分数里挑了一个。
                // 与其用一条门槛把它藏掉，不如标出来让用户自己判断。
                Text(
                  '${(event.confidence * 100).round()}%',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: event.confidence < _lowConfidenceMark
                        ? AppColors.statusWarning
                        : AppColors.textDim,
                  ),
                ),
              ],
            ),
          ),
          Text('${event.durationSeconds.round()}s',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textDim)),
          // 分贝。**带波浪号**：那是「约」的意思，而这里的值确实是估算的
          // （手机麦克风没有校准，误差 ±10 分贝）。不带波浪号会读成测量值。
          //
          // 老记录没有电平（`peakRms` 是 null）——那时**什么都不显示**，
          // 不要拿 0 顶上去：0 分贝是"极其安静"，而真相是"那时候没记"。
          if (event.peakRms != null) ...[
            const SizedBox(width: 8),
            Text('~${estimatedDbSplRounded(event.peakRms!)}dB',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textDim)),
          ],
          SizedBox(
            width: 40,
            child: onPlay == null
                ? null
                : IconButton(
                    onPressed: isLoading ? null : onPlay,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    tooltip: isPlaying
                        ? context.l10n.reportStop
                        : context.l10n.reportListen,
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
