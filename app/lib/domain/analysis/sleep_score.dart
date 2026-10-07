import '../models/recording_session.dart';
import '../models/sleep_category.dart';

/// 这是哪一项扣分。
///
/// **领域层只说"是哪一项、数值多少"，不说"这句话怎么写"**——措辞在界面层
/// 按语言渲染，见 `lib/ui/core/l10n/domain_text.dart`。
enum DeductionKind {
  /// 鼾声占整夜的多少。
  snoreRatio,

  /// 长时间连续鼾声占鼾声总时长的多少。
  snoreContinuity,

  /// 咳嗽 / 梦话 / 翻身平均每小时多少次。
  disturbances,

  /// 环境声占整夜的多少。
  ambient,
}

/// 评分里的一个扣分项。
class ScoreDeduction {
  const ScoreDeduction({
    required this.kind,
    required this.maxPoints,
    required this.points,
    this.params = const {},
  });

  final DeductionKind kind;

  /// 这项最多能扣多少分。
  final double maxPoints;

  /// 实际扣了多少分。
  final double points;

  /// 渲染这句话需要的数值。键名和渲染方（`domain_text.dart`）是一对。
  final Map<String, Object?> params;
}

/// 分数落在哪一档。
///
/// 以前是个中文字符串（'很安静' / '鼾声很重'），同样是领域层在写展示文本。
enum ScoreGrade {
  /// 很安静。
  quiet,

  /// 比较安静。
  good,

  /// 有些声音。
  fair,

  /// 鼾声明显。
  noisy,

  /// 鼾声很重。
  heavy,
}

/// 基于**声音**的睡眠评分。
///
/// ⚠️ 这不是医学意义上的睡眠质量。
///
/// 睡眠分期（深睡/浅睡/REM）和觉醒次数需要加速度计或心率，只有麦克风做不到。
/// 这个分数衡量的是**这一夜有多吵**。
///
/// 用**扣分制**而不是加权平均：加权平均在"整夜只有鼾声"时会托底到 40 分左右
/// （另外三项因为没有其他声音而满分），把重度打鼾的夜晚评得偏高。
/// 从 100 往下扣没有这个问题，而且用户可以直接验算「100 − 60 − 15 = 25」。
class SleepScore {
  const SleepScore({
    required this.total,
    required this.deductions,
    required this.grade,
  });

  /// 总分 0–100。
  final int total;

  final List<ScoreDeduction> deductions;

  /// 落在哪一档。
  final ScoreGrade grade;

  // 原先这里还有个 `caveat`——一段解释「这个分数不是睡眠质量」的长文案。
  // 它是常量，跟分数无关，所以搬进 ARB 了（`scoreCaveat`）。
  // 一句话说明挂在每个实例上，只是让每个实例都背一遍同样的话。
}

/// 低于这个分析时长就不给分。
///
/// 20 分钟录音算出来的"一夜评分"没有意义，不如不显示。
const Duration kMinScorableDuration = Duration(minutes: 90);

// 各项扣分上限，合计 100 —— 全部拉满时正好归零。
const double _maxSnoreDeduction = 60;
const double _maxContinuityDeduction = 15;
const double _maxDisturbanceDeduction = 15;
const double _maxAmbientDeduction = 10;

/// 鼾声占比到达这个比例就扣满。**不是医学阈值**，是本评分的标尺上限。
const double _snoreRatioAtFullDeduction = 0.25;

/// 干扰事件达到每小时这个次数就扣满。同样是标尺上限。
const double _disturbancePerHourAtFullDeduction = 20;

/// 环境噪音占比到达这个比例就扣满。
const double _ambientRatioAtFullDeduction = 0.40;

/// 计算一晚的声音评分。分析时长不足时返回 null。
SleepScore? scoreSession(RecordingSession session) {
  final stats = session.stats;
  final analyzed = stats.analyzedSeconds;
  if (analyzed < kMinScorableDuration.inSeconds) return null;

  // ---- 1. 鼾声占比：鼾声时长 / 分析时长 ----
  final snoreRatio = stats.snoreIndex / 100;
  final snoreDeduction = _ramp(snoreRatio, _snoreRatioAtFullDeduction) *
      _maxSnoreDeduction;

  // ---- 2. 鼾声连续性：长时间连续鼾声比零碎鼾声更值得注意 ----
  final snoreEvents = session.events.where((e) => e.isSnore).toList();
  final totalSnoreSeconds =
      snoreEvents.fold<double>(0, (sum, e) => sum + e.durationSeconds);
  final longSnoreSeconds = snoreEvents
      .where((e) => e.durationSeconds >= 120)
      .fold<double>(0, (sum, e) => sum + e.durationSeconds);
  final longRatio =
      totalSnoreSeconds <= 0 ? 0.0 : longSnoreSeconds / totalSnoreSeconds;
  final continuityDeduction = longRatio * _maxContinuityDeduction;

  // ---- 3. 干扰频次：咳嗽 / 梦话 / 翻身，每小时多少次 ----
  //
  // ⚠️ 这里以前是「非鼾声、非静音」全都算（`!e.isSnore && !e.label.isRecessive`），
  // **把环境噪音和呼吸声也算成了干扰**——和界面上那句「咳嗽、梦话、翻身等」
  // 对不上，而且环境噪音被扣了两次（这里一次，下面第 4 项占比又一次）。
  //
  // 真实整夜数据上这个 bug 很扎眼：一晚 81 个事件里绝大多数是低置信度的
  // 环境噪音碎片，于是「干扰频次 9.4 次/小时」扣掉 7 分——而那一晚
  // 其实几乎没被任何东西打断过。
  //
  // 干扰指的是**可能打断睡眠的声音**：咳嗽、梦话、翻身。
  // 呼吸和背景噪音不是——前者是睡眠本来的样子，后者是环境不是事件。
  const disturbances = {
    SleepCategory.cough,
    SleepCategory.vocal,
    SleepCategory.movement,
  };
  final disturbanceCount =
      session.events.where((e) => disturbances.contains(e.label)).length;
  final perHour = disturbanceCount / (analyzed / 3600);
  final disturbanceDeduction =
      _ramp(perHour, _disturbancePerHourAtFullDeduction) *
          _maxDisturbanceDeduction;

  // ---- 4. 环境噪音占比 ----
  final ambientSeconds = session.events
      .where((e) => e.label == SleepCategory.ambient)
      .fold<double>(0, (sum, e) => sum + e.durationSeconds);
  final ambientRatio = ambientSeconds / analyzed;
  final ambientDeduction =
      _ramp(ambientRatio, _ambientRatioAtFullDeduction) * _maxAmbientDeduction;

  final deductions = [
    ScoreDeduction(
      kind: DeductionKind.snoreRatio,
      maxPoints: _maxSnoreDeduction,
      points: snoreDeduction,
      params: {'ratio': snoreRatio * 100},
    ),
    ScoreDeduction(
      kind: DeductionKind.snoreContinuity,
      maxPoints: _maxContinuityDeduction,
      points: continuityDeduction,
      params: {'hasSnore': totalSnoreSeconds > 0, 'longRatio': longRatio * 100},
    ),
    ScoreDeduction(
      kind: DeductionKind.disturbances,
      maxPoints: _maxDisturbanceDeduction,
      points: disturbanceDeduction,
      params: {'perHour': perHour},
    ),
    ScoreDeduction(
      kind: DeductionKind.ambient,
      maxPoints: _maxAmbientDeduction,
      points: ambientDeduction,
      params: {'ratio': ambientRatio * 100},
    ),
  ];

  final total = (100 - deductions.fold<double>(0, (a, d) => a + d.points))
      .round()
      .clamp(0, 100);

  return SleepScore(
    total: total,
    deductions: deductions,
    grade: _gradeFor(total),
  );
}

/// 线性斜坡：0 -> 0，[full] 及以上 -> 1。
double _ramp(double value, double full) {
  if (full <= 0) return value > 0 ? 1 : 0;
  final r = value / full;
  return r < 0 ? 0.0 : (r > 1 ? 1.0 : r);
}

ScoreGrade _gradeFor(int total) {
  if (total >= 85) return ScoreGrade.quiet;
  if (total >= 70) return ScoreGrade.good;
  if (total >= 55) return ScoreGrade.fair;
  if (total >= 35) return ScoreGrade.noisy;
  return ScoreGrade.heavy;
}
