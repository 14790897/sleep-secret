/// 与睡眠呼吸问题相关、而模型**真的能分辨出来**的那几个声音信号。
///
/// ## 为什么只有一个
///
/// 2026-10-07 拿 CC0 素材跑过一轮（`scripts/fetch_test_audio.py --slots ...`），
/// 判据和 App 完全一致：**527 维里取 argmax，且分数 ≥ 0.5**——App 的门槛是
/// 0.25，这里留一倍余量。结果：
///
/// | 想要的标签 | 试了几段 | 通过 | 模型实际给的 |
/// |---|---|---|---|
/// | `Gasp` | 4 | **1**（0.510） | 就是它 |
/// | `Wheeze` | 37 | 0 | Screaming / Groan / Cough / Throat clearing |
/// | `Pant` | 40 | 0 | **Gasp**（0.68~0.89）/ Breathing / Groan |
/// | `Snort` | 40 | 0 | Oink（猪）/ Sneeze / Horse / Fart |
///
/// ⚠️ **这不等于证明了模型认不出它们。** 素材是从 Openverse 搜来的，
/// 「Wheeze 1.mp3」未必真是哮鸣——这一轮里大半候选根本不是那个声音
/// （笑、僵尸叫、狗叫、音乐）。准确的说法只是：
/// **在能找到的 CC0 素材上，没能证明它们会响。**
///
/// ⚠️ `Snort` 那一行还测偏了：猪的喷嚏被判成 `Oink`、马的被判成 `Horse`，
/// 那是模型**做对了**——它们本来就不是人的喷鼻息。所以那一行说明的是
/// 「没找到人打喷嚏的素材」，不是「模型不会」。
///
/// ## 但「没能证明」就够做决定了
///
/// 这张卡会明确告诉用户**我们盯着哪几样**。挂一个证明不了的进去，
/// 就是在给「没检出」加一份它没有的可信度——而那正是这个应用最不想制造的
/// 东西（同一条道理见过好几次：`peak_rms` 的 null vs 0、
/// `signals_collected` 的「没查」vs「没有」）。
///
/// 另外 `Snort` 的落点本身也重复：它归在「鼾声」大类里，而鼾声那一行的
/// 检出率是 0.91~0.97——喷鼻息这个信息**已经由鼾声那一行交付了**。
///
/// 拿到真实素材（真人哮鸣、真人睡眠里的喷鼻息）随时加回来：
/// 改这个列表 + 补一段 fixture，两处而已。加了之后
/// `test/domain/apnea_signals_test.dart` 会拿真实映射表验名字对不对。
///
/// ## 只剩 `Gasp` 之后，它有多准
///
/// 上面那轮还顺带暴露一件事：**真人「heavy breathing」素材有 8 段被认成
/// `Gasp`，分数 0.68~0.89**。也就是说模型把「喘得厉害」也归到这一维里，
/// 所以这一栏**不专指呼吸暂停之后那一声**——卡片文案里必须说出来。
library;

import '../models/recording_session.dart';
import '../models/sound_event.dart';

const List<String> kApneaSignalLabels = ['Gasp'];

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
