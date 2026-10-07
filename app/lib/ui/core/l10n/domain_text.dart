/// **领域层给事实、界面层给句子**——这一层就是那个转换点。
///
/// ## 为什么要有这么一层
///
/// 加多语言之前，`Diagnosis`、`ScoreDeduction`、`SleepCategory` 这些领域类型
/// **自己带着拼好的中文句子**（`title`/`detail`/`label`）。界面拿到就显示。
///
/// 那在单语言下看不出问题，但它意味着**领域层必须知道用户在看什么语言**——
/// 而领域层是纯逻辑，拿不到 `BuildContext`，也不该拿到。
///
/// 所以改成：领域层只回答「这是什么、数值多少」（枚举 + 参数），
/// 由这里翻成某个语言下的句子。好处不只是多语言：
/// 判定逻辑和措辞彻底分开了，改文案不会再碰算法。
///
/// 这一层**故意集中在一个文件**。散到各个 widget 里的话，「这句话是从哪来的」
/// 就要满仓库找。
library;

import 'package:flutter/widgets.dart';

import '../../../domain/analysis/apnea_signals.dart';
import '../../../domain/analysis/recording_diagnosis.dart';
import '../../../domain/analysis/sleep_score.dart';
import '../../../domain/analysis/session_insights.dart';
import '../../../domain/models/recording_state.dart';
import '../../../domain/models/sleep_category.dart';
import '../../../domain/models/sound_event.dart';
import '../theme.dart';
import 'l10n_context.dart';

// ---------------------------------------------------------------- 类别名

extension SleepCategoryText on SleepCategory {
  /// 用户的界面上该显示什么名字。
  String label(BuildContext context) => switch (this) {
        SleepCategory.snore => context.l10n.categorySnore,
        SleepCategory.breathing => context.l10n.categoryBreathing,
        SleepCategory.cough => context.l10n.categoryCough,
        SleepCategory.sneeze => context.l10n.categorySneeze,
        SleepCategory.vocal => context.l10n.categoryVocal,
        SleepCategory.movement => context.l10n.categoryMovement,
        SleepCategory.ambient => context.l10n.categoryAmbient,
        SleepCategory.deviceNoise => context.l10n.categoryDeviceNoise,
        SleepCategory.silence => context.l10n.categorySilence,
      };
}

// ------------------------------------------------------------ 录音质量诊断

extension DiagnosisText on Diagnosis {
  String title(BuildContext context) => switch (kind) {
        DiagnosisKind.noInference => context.l10n.diagnosisNoInferenceTitle,
        DiagnosisKind.tooFewInferred => context.l10n.diagnosisTooFewTitle,
        DiagnosisKind.lowConfidence => context.l10n.diagnosisLowConfidenceTitle,
        DiagnosisKind.snoreRatioHigh => context.l10n
            .diagnosisSnoreRatioTitle((params['percent'] as num).round()),
        DiagnosisKind.noEvents => context.l10n.diagnosisNoEventsTitle,
      };

  String detail(BuildContext context) => switch (kind) {
        DiagnosisKind.noInference => context.l10n.diagnosisNoInferenceDetail,
        DiagnosisKind.tooFewInferred => context.l10n.diagnosisTooFewDetail(
            (params['percent'] as num).toStringAsFixed(1),
            params['inferred'] as int,
            params['total'] as int,
          ),
        DiagnosisKind.lowConfidence => context.l10n.diagnosisLowConfidenceDetail(
            (params['inferredPercent'] as num).toStringAsFixed(0),
            (params['lowConfPercent'] as num).toStringAsFixed(0),
          ),
        DiagnosisKind.snoreRatioHigh => context.l10n.diagnosisSnoreRatioDetail,
        DiagnosisKind.noEvents => context.l10n.diagnosisNoEventsDetail,
      };
}

// ---------------------------------------------------------------- 高危信号

/// AudioSet 的高危信号标签名 → 界面上显示的名字。
///
/// **键必须和 [kApneaSignalLabels] 里的字符串一字不差**，那边写错一个字母，
/// 这里会静默走到兜底分支；`test/domain/apnea_signals_test.dart` 会拦住。
String apneaSignalName(BuildContext context, String rawLabel) =>
    switch (rawLabel) {
      'Gasp' => context.l10n.signalGasp,
      'Snort' => context.l10n.signalSnort,
      'Wheeze' => context.l10n.signalWheeze,
      'Pant' => context.l10n.signalPant,
      // 认不出的名字直接显示原文。它不该发生，但真发生了也不能显示成空白——
      // 「认出来了却没名字」比一个英文标签名更让人困惑。
      _ => rawLabel,
    };

extension SoundEventText on SoundEvent {
  /// 这一行该显示的名字。
  ///
  /// **高危信号优先于大类**：用户想知道的正是「具体是哪种声音」，
  /// 「倒吸气」比「呼吸」有用得多。没有信号时才回落到大类名。
  String displayName(BuildContext context) =>
      signal == null ? label.label(context) : apneaSignalName(context, signal!);
}

extension ApneaSignalSummaryText on ApneaSignalSummary {
  /// 一样都没认出来时那句话。
  ///
  /// **必须把「在盯着哪几样」列出来**，否则「这几样」指的是什么就成了谜——
  /// 而用户会拿这份没写清楚的东西当作「查过了，没问题」。
  String emptyNote(BuildContext context) => context.l10n.reportSignalsNone(
        kApneaSignalLabels
            .map((l) => apneaSignalName(context, l))
            .join('、'),
      );

  /// 这一晚根本没收集这类数据（升级前的记录）。
  ///
  /// 和 [emptyNote] 是**两件事**，措辞必须分开：一个是「查过了没有」，
  /// 一个是「没查」。
  String notCollectedNote(BuildContext context) =>
      context.l10n.reportSignalsNotCollected;

  String countNote(BuildContext context) =>
      context.l10n.reportSignalsCount(totalCount);

  String caveat(BuildContext context) => context.l10n.reportSignalsCaveat;
}

// -------------------------------------------------------------- 睡眠声音评分

extension ScoreGradeText on ScoreGrade {
  String label(BuildContext context) => switch (this) {
        ScoreGrade.quiet => context.l10n.gradeQuiet,
        ScoreGrade.good => context.l10n.gradeGood,
        ScoreGrade.fair => context.l10n.gradeFair,
        ScoreGrade.noisy => context.l10n.gradeNoisy,
        ScoreGrade.heavy => context.l10n.gradeHeavy,
      };
}

extension ScoreDeductionText on ScoreDeduction {
  String label(BuildContext context) => switch (kind) {
        DeductionKind.snoreRatio => context.l10n.deductionSnoreRatio,
        DeductionKind.snoreContinuity => context.l10n.deductionSnoreContinuity,
        DeductionKind.disturbances => context.l10n.deductionDisturbances,
        DeductionKind.ambient => context.l10n.deductionAmbient,
      };

  String detail(BuildContext context) => switch (kind) {
        DeductionKind.snoreRatio => context.l10n.deductionSnoreRatioDetail(
            (params['ratio'] as num).toStringAsFixed(1)),
        DeductionKind.snoreContinuity => params['hasSnore'] as bool
            ? context.l10n.deductionSnoreContinuityDetail(
                (params['longRatio'] as num).toStringAsFixed(0))
            : context.l10n.deductionSnoreContinuityNone,
        DeductionKind.disturbances => context.l10n.deductionDisturbancesDetail(
            (params['perHour'] as num).toStringAsFixed(1)),
        DeductionKind.ambient => context.l10n.deductionAmbientDetail(
            (params['ratio'] as num).toStringAsFixed(1)),
      };
}

extension SleepScoreText on SleepScore {
  String gradeLabel(BuildContext context) => grade.label(context);

  String caveat(BuildContext context) => context.l10n.scoreCaveat;
}

// ---------------------------------------------------------------- 时长分箱

extension DurationBinKindText on DurationBinKind {
  /// 直方图横轴上的那一小段文字。
  String label(BuildContext context) => switch (this) {
        DurationBinKind.under15s => context.l10n.binUnder15s,
        DurationBinKind.s15to30 => context.l10n.bin15to30,
        DurationBinKind.s30to60 => context.l10n.bin30to60,
        DurationBinKind.m1to2 => context.l10n.bin1to2m,
        DurationBinKind.m2to5 => context.l10n.bin2to5m,
        DurationBinKind.over5m => context.l10n.binOver5m,
      };
}

// ---------------------------------------------------------------- 录音错误

extension RecordingErrorText on RecordingError {
  /// 给用户看的那句话。
  ///
  /// [detail] 是异常原文——**不翻译**，直接拼进去。它往往是报 bug 时唯一的
  /// 线索，翻掉了就等于把线索也翻没了。
  String message(BuildContext context) => switch (kind) {
        RecordingErrorKind.micDenied => context.l10n.recordingErrorMicDenied,
        RecordingErrorKind.streamFailed =>
          context.l10n.recordingErrorStreamFailed(detail ?? ''),
        RecordingErrorKind.startFailed =>
          context.l10n.recordingErrorStartFailed(detail ?? ''),
        RecordingErrorKind.analysisFailed =>
          context.l10n.recordingErrorAnalysisFailed(detail ?? ''),
      };
}

extension RecordingWarningText on RecordingWarningKind {
  String message(BuildContext context) => switch (this) {
        RecordingWarningKind.notificationsDenied =>
          context.l10n.recordingWarningNotificationsDenied,
      };
}

// -------------------------------------------------------------- 时间线配色大类

extension SoundClassText on SoundClass {
  /// 图例上那个名字。
  String label(BuildContext context) => switch (this) {
        SoundClass.snore => context.l10n.soundClassSnore,
        SoundClass.event => context.l10n.soundClassEvent,
        SoundClass.background => context.l10n.soundClassBackground,
      };
}
