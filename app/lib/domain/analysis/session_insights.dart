import '../models/recording_session.dart';
import '../models/sleep_category.dart';
import '../models/sound_event.dart';

/// 某个钟点内各类声音的时长。
class HourBucket {
  const HourBucket({
    required this.hour,
    required this.snoreSeconds,
    required this.otherSeconds,
  });

  /// 钟点，0–23。
  final int hour;

  /// 鼾声时长。
  final double snoreSeconds;

  /// 其余可分类声音的时长（静音不算，它是背景不是事件）。
  final double otherSeconds;

  double get totalSeconds => snoreSeconds + otherSeconds;

  bool get isEmpty => totalSeconds <= 0;
}

/// 按钟点汇总整夜的声音事件。
///
/// 钟点取事件开始时刻的**墙上时间**，这样"我几点打鼾最多"才有意义——
/// 按会话内偏移小时会随入睡时间漂移，跨晚没法比较。
///
/// 排序按**会话内的时间先后**，不是钟点数字大小。23 点入睡的一夜应当是
/// 23、0、1… 而不是 0、1、…、23；后者会把刚入睡那段排到图的最右边。
///
/// 只返回出现过事件的钟点。
List<HourBucket> hourlyBreakdown(RecordingSession session) {
  final started = session.startedAt;
  final snore = <int, double>{};
  final other = <int, double>{};
  final firstOffset = <int, double>{};

  for (final e in session.events) {
    if (e.label.isRecessive) continue;
    final hour = started.add(Duration(seconds: e.startSeconds.round())).hour;

    final seen = firstOffset[hour];
    if (seen == null || e.startSeconds < seen) {
      firstOffset[hour] = e.startSeconds;
    }

    if (e.isSnore) {
      snore[hour] = (snore[hour] ?? 0) + e.durationSeconds;
    } else {
      other[hour] = (other[hour] ?? 0) + e.durationSeconds;
    }
  }

  final hours = firstOffset.keys.toList()
    ..sort((a, b) => firstOffset[a]!.compareTo(firstOffset[b]!));

  return [
    for (final h in hours)
      HourBucket(
        hour: h,
        snoreSeconds: snore[h] ?? 0,
        otherSeconds: other[h] ?? 0,
      ),
  ];
}

/// 鼾声单次时长的一个分箱。
class DurationBin {
  const DurationBin({
    required this.label,
    required this.count,
    required this.minSeconds,
    required this.maxSeconds,
  });

  final String label;
  final int count;
  final double minSeconds;

  /// 上界，开区间；最后一箱为 null 表示无上界。
  final double? maxSeconds;
}

/// 鼾声段的时长分布。
///
/// 分箱边界按实际意义取（半分钟、一分钟、两分钟），不是等宽——
/// 鼾声段从几秒到几分钟跨两个数量级，等宽分箱会把短段全挤在第一格。
const List<(String, double, double?)> _durationBins = [
  ('<15秒', 0, 15),
  ('15–30秒', 15, 30),
  ('30–60秒', 30, 60),
  ('1–2分', 60, 120),
  ('2–5分', 120, 300),
  ('>5分', 300, null),
];

List<DurationBin> snoreDurationHistogram(List<SoundEvent> events) {
  final snoreEvents = events.where((e) => e.isSnore);
  final counts = List<int>.filled(_durationBins.length, 0);

  for (final e in snoreEvents) {
    for (var i = 0; i < _durationBins.length; i++) {
      final (_, lo, hi) = _durationBins[i];
      final inBin = e.durationSeconds >= lo &&
          (hi == null || e.durationSeconds < hi);
      if (inBin) {
        counts[i]++;
        break;
      }
    }
  }

  return [
    for (var i = 0; i < _durationBins.length; i++)
      DurationBin(
        label: _durationBins[i].$1,
        count: counts[i],
        minSeconds: _durationBins[i].$2,
        maxSeconds: _durationBins[i].$3,
      ),
  ];
}

/// 趋势图上的一个点，代表一晚。
class TrendPoint {
  const TrendPoint({
    required this.night,
    required this.snoreIndex,
    required this.snoreSeconds,
    required this.snoreEventCount,
    required this.analyzedSeconds,
  });

  /// 这一晚的开始时刻。
  final DateTime night;

  final double snoreIndex;
  final double snoreSeconds;
  final int snoreEventCount;
  final double analyzedSeconds;
}

/// 取出最近若干晚的趋势序列，按时间从旧到新。
///
/// 时长为零或没有分析数据的会话会被跳过——它们的鼾声指数是 0/0，
/// 画上去会得到一个假的"零鼾声"点，比缺一个点更误导。
List<TrendPoint> buildTrend(
  List<RecordingSession> sessions, {
  int maxNights = 14,
}) {
  final usable = sessions
      .where((s) => s.stats.analyzedSeconds > 0)
      .toList()
    ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

  final tail =
      usable.length > maxNights ? usable.sublist(usable.length - maxNights) : usable;

  return [
    for (final s in tail)
      TrendPoint(
        night: s.startedAt,
        snoreIndex: s.stats.snoreIndex,
        snoreSeconds: s.stats.snoreSeconds,
        snoreEventCount: s.stats.snoreEventCount,
        analyzedSeconds: s.stats.analyzedSeconds,
      ),
  ];
}

/// 趋势的概要：均值、极值、以及改善了还是变差了。
class TrendSummary {
  const TrendSummary({
    required this.averageIndex,
    required this.bestIndex,
    required this.worstIndex,
    required this.changeFromFirst,
    required this.nights,
  });

  final double averageIndex;
  final double bestIndex;
  final double worstIndex;

  /// 最近一晚相对最早一晚的变化（百分点）。正数表示变差。
  final double changeFromFirst;
  final int nights;

  bool get improving => changeFromFirst < -0.5;
  bool get worsening => changeFromFirst > 0.5;
}

TrendSummary? summarizeTrend(List<TrendPoint> points) {
  if (points.isEmpty) return null;
  final indices = points.map((p) => p.snoreIndex).toList();
  final avg = indices.reduce((a, b) => a + b) / indices.length;
  return TrendSummary(
    averageIndex: avg,
    bestIndex: indices.reduce((a, b) => a < b ? a : b),
    worstIndex: indices.reduce((a, b) => a > b ? a : b),
    changeFromFirst: indices.last - indices.first,
    nights: points.length,
  );
}

/// 会话里出现过的大类（按总时长降序），用于图例只列有内容的项。
List<SleepCategory> categoriesPresent(RecordingSession session) {
  final totals = <SleepCategory, double>{};
  for (final e in session.events) {
    totals[e.label] = (totals[e.label] ?? 0) + e.durationSeconds;
  }
  final list = totals.keys.toList()
    ..sort((a, b) => totals[b]!.compareTo(totals[a]!));
  return list;
}
