/// 与睡眠呼吸问题相关、而模型**真的能分辨出来**的那几个声音信号。
///
/// ## 为什么是这几个
///
/// AudioSet 的 527 个标签里，和上气道直接相关的就这些。挑的标准是
/// 「声学上有明确定义 **且** 与呼吸事件或上气道阻塞有已知关联」，
/// 不是「听起来吓人」：
///
/// | 标签 | 中文 | 关联 |
/// |---|---|---|
/// | `Gasp` | 倒吸气 | 呼吸事件结束时常以一次爆发性的吸气收尾 |
/// | `Snort` | 喷鼻息 | 上气道部分阻塞时的爆破音 |
/// | `Wheeze` | 哮鸣 | 气道狭窄 |
/// | `Pant` | 急促呼吸 | 呼吸费力 |
///
/// ## 没进来的几个，以及为什么
///
/// **吸鼻子（`Sniff`）**：它不是气道在做功，是**鼻子堵了**。那是鼻塞这个
/// **长期风险因素**的标记，不是那一夜**呼吸事件**的标记——两件事的时间尺度
/// 都不是一回事。更要紧的是代价：感冒、干燥、过敏季都会让人整夜吸鼻子，
/// 放进这张卡里就会在什么都没发生的夜晚反复报警，而**一张见谁都喊的卡，
/// 真有事的时候也就没人看了**。它仍然归在「鼾声」大类里，照常算进鼾声统计。
///
/// **咳嗽、清嗓、叹气**：夜里很常见，和呼吸事件的关联也弱得多，
/// 放进来只会让这张卡变成噪音。
///
/// ## 这里存的是 AudioSet 原始标签名，不是大类
///
/// 大类会把它们盖掉：倒吸气、哮鸣、急促呼吸全归在「呼吸」里。要单独盯住
/// 它们，只能按**模型输出的原始标签**比对。
///
/// ⚠️ **字符串必须和 `assets/models/sleep_class_map.json` 里的标签一字不差。**
/// 写错一个字母，那个信号会永远显示 0 次，而且不会有任何报错——
/// `test/domain/apnea_signals_test.dart` 里有一条专门比对真实资源文件的测试。
library;

import '../models/recording_session.dart';
import '../models/sound_event.dart';

const List<String> kApneaSignalLabels = [
  'Gasp',
  'Snort',
  'Wheeze',
  'Pant',
];

/// 这个 AudioSet 标签算不算高危信号。
bool isApneaSignalLabel(String? rawLabel) =>
    rawLabel != null && kApneaSignalLabels.contains(rawLabel);

/// 认出来的某一种信号，以及它这一夜出现的每一次。
class SignalHit {
  const SignalHit({required this.label, required this.events});

  /// AudioSet 原始标签名（`Gasp` 等）。
  final String label;

  /// 这一夜认出的该信号事件，按时间先后。
  final List<SoundEvent> events;

  int get count => events.length;
}

/// 一夜的高危信号汇总。
class ApneaSignalSummary {
  const ApneaSignalSummary({required this.hits, required this.collected});

  /// 这一晚的录音**根本没有**这类数据（升级前的记录）。
  const ApneaSignalSummary.notCollected()
      : hits = const [],
        collected = false;

  /// 认出来的信号，按 [kApneaSignalLabels] 的顺序——**不按次数排**。
  ///
  /// 按次数排会让「哪几个更值得注意」悄悄变成「哪几个更多」，而这两件事没有
  /// 关系；固定顺序还让用户跨夜对比时不必每次重新找位置。
  final List<SignalHit> hits;

  /// 这一晚的录音到底有没有在收集这类信号。
  ///
  /// 升级前的记录里所有事件的 `signal` 都是 null，那和「这一夜确实一个都没
  /// 认出来」是两回事。分不开的话，用户会拿一份没有数据的旧报告当作
  /// 「我一切正常」的证据——这正是这个项目最不想制造的东西。
  final bool collected;

  bool get isEmpty => hits.isEmpty;

  int get totalCount => hits.fold(0, (sum, h) => sum + h.count);
}

/// 从会话事件里挑出高危信号。
///
/// 它做的事只有一件：**把模型自己认出来的那几个声音摆出来**。不做时序推断，
/// 不算间隔，不给严重程度——麦克风分不清「呼吸停了一下」和「呼吸轻到没录到」，
/// 见 [SoundEvent.signal] 和 `kApneaSignalLabels` 里的说明。
ApneaSignalSummary analyzeApneaSignals(RecordingSession session) {
  if (!session.stats.signalsCollected) {
    return const ApneaSignalSummary.notCollected();
  }

  final byLabel = <String, List<SoundEvent>>{};
  for (final e in session.events) {
    final s = e.signal;
    if (s == null) continue;
    (byLabel[s] ??= []).add(e);
  }

  return ApneaSignalSummary(
    hits: [
      for (final label in kApneaSignalLabels)
        if (byLabel.containsKey(label))
          SignalHit(label: label, events: List.unmodifiable(byLabel[label]!)),
    ],
    collected: true,
  );
}
