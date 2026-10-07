import '../models/recording_session.dart';

/// 严重程度。
///
/// 刻意只有两档：要么是「这一晚的结果可能不可信，值得看一眼」，
/// 要么是「知道了就行」。再多分档会让用户开始逐条权衡，反而没人看。
enum DiagnosisLevel {
  /// 结果可能不可信，需要用户做点什么。
  warning,

  /// 陈述事实，不需要行动。
  info,
}

/// 这是哪一条诊断。
///
/// **领域层只说"是哪一条、数值多少"，不说"这句话怎么写"**——
/// 措辞在界面层按语言渲染，见 `lib/ui/core/l10n/domain_text.dart`。
///
/// 加多语言之前，`Diagnosis` 直接带 `title`/`detail` 两个拼好的中文句子。
/// 那样领域层就被迫知道用户在看什么语言，而它拿不到 `BuildContext`，
/// 也不该拿到。
enum DiagnosisKind {
  /// 整晚几乎所有窗口都没进模型。
  noInference,

  /// 只有极少数窗口进了模型。
  tooFewInferred,

  /// 整晚都有声音，但模型对大多数窗口都没把握。
  lowConfidence,

  /// 鼾声占比高得离谱。
  snoreRatioHigh,

  /// 有窗口进了模型，但一个事件都没检出。
  noEvents,
}

/// 一条诊断结论。
class Diagnosis {
  const Diagnosis({
    required this.level,
    required this.kind,
    this.params = const {},
  });

  final DiagnosisLevel level;
  final DiagnosisKind kind;

  /// 渲染这条结论需要的数值。
  ///
  /// 用 `Map` 而不是给每个 kind 定义一个类：这里的参数最多三个，
  /// 每加一条规则就多一个类不划算。代价是取的时候要写死键名——
  /// 所以**键名和渲染方（`domain_text.dart`）是一对，改的时候要一起改**。
  final Map<String, Object?> params;
}

/// 从会话统计里推断这次录音可不可信。
///
/// ## 为什么需要这个
///
/// 报告是空的时候，有**两种完全不同的原因**，而它们在界面上长得一模一样：
///
///   1. 你那一晚确实没怎么打鼾
///   2. 麦克风被挡住了、手机放太远、或者阈值把该留的都滤掉了
///
/// 用户没法区分，于是要么白高兴一场，要么把能用的功能当成坏的。
/// 这里就是把这个区分做出来——**数据本来就都在 [SessionStats] 里**，
/// 只是之前没人把它翻译成人话。
///
/// 判定用的比例阈值都是取整的保守值，宁可漏报也不误报：
/// 一条错误的「可能有问题」会让用户去改本来没问题的用法。
///
/// **这里刻意不报「录音太短」。** 时长门槛 `kMinScorableDuration`（90 分钟）
/// 和评分用的是同一个，两者必然同时出现——评分仪表已经在说
/// 「录音太短，暂不计分」，这里再说一遍只是噪音。
/// 短录音对下面这些整夜性质的判断没有意义，所以它们统一要求 >= 90 分钟。
List<Diagnosis> diagnoseSession(RecordingSession session) {
  final s = session.stats;
  final out = <Diagnosis>[];

  if (s.windowsTotal == 0) {
    return out;
  }

  // 整夜性质的判断统一要求录满 90 分钟以上。
  //
  // 抽成一个变量而不是每条规则各写一遍：散着写的结果就是漏掉几条
  // （第一版就把鼾声占比那条漏了）。短录音里什么都可能还没发生，
  // 按比例下结论只会误导。
  final isFullNight = s.analyzedSeconds >= 90 * 60;

  // ---- 几乎没有窗口进模型 ----
  //
  // 这是最要命的一种：报告会显示"0 个事件"，而用户会以为"我昨晚没打鼾"。
  if (isFullNight && s.windowsInferred == 0) {
    out.add(const Diagnosis(
      level: DiagnosisLevel.warning,
      kind: DiagnosisKind.noInference,
    ));
    return out;
  }

  final inferredRatio = s.windowsInferred / s.windowsTotal;
  if (isFullNight && inferredRatio < 0.02) {
    out.add(Diagnosis(
      level: DiagnosisLevel.warning,
      kind: DiagnosisKind.tooFewInferred,
      params: {
        'percent': inferredRatio * 100,
        'inferred': s.windowsInferred,
        'total': s.windowsTotal,
      },
    ));
  }

  // ---- 整晚都有声音，但模型对绝大多数窗口都没把握 ----
  //
  // 光看低置信度比例会误报：**安静的一夜比例也很高**——VAD 只放行零星几声，
  // 模型对这零星几声自然没什么把握。实测在安静房间里就是 10/11 = 91%。
  // 那是正常结果，不该报警。
  //
  // 真正异常的是「整晚大部分时间都有声音，而模型几乎都认不出」——
  // 那说明有持续的低频噪声（风扇、空调、雨声）占满了整晚。
  //
  // ⚠️ 去掉置信度门控之后这条比以前**更重要**：那些窗口现在也会产生事件，
  // 于是报告里会出现大量类别不可靠的条目。
  if (isFullNight && inferredRatio > 0.5 && s.windowsInferred > 20) {
    final lowConfRatio = s.windowsLowConfidence / s.windowsInferred;
    if (lowConfRatio > 0.9) {
      out.add(Diagnosis(
        level: DiagnosisLevel.warning,
        kind: DiagnosisKind.lowConfidence,
        params: {
          'inferredPercent': inferredRatio * 100,
          'lowConfPercent': lowConfRatio * 100,
        },
      ));
    }
  }

  // ---- 鼾声占比高得离谱 ----
  //
  // 真打鼾一晚上通常占 10%~40%。过半往往意味着有持续背景噪声
  // 被当成了鼾声（低频的风扇声最像）。
  if (isFullNight && s.snoreIndex > 50) {
    out.add(Diagnosis(
      level: DiagnosisLevel.warning,
      kind: DiagnosisKind.snoreRatioHigh,
      // 这个数会进**标题**（「鼾声占比异常高（68%）」），所以渲染方也要它
      params: {'percent': s.snoreIndex},
    ));
  }

  // ---- 录了很久却一个事件都没有 ----
  if (isFullNight && s.eventCount == 0 && s.windowsInferred > 0) {
    out.add(const Diagnosis(
      level: DiagnosisLevel.info,
      kind: DiagnosisKind.noEvents,
    ));
  }

  return out;
}

/// 这次录音有没有值得用户看一眼的问题。
bool hasWarnings(List<Diagnosis> diagnoses) =>
    diagnoses.any((d) => d.level == DiagnosisLevel.warning);
