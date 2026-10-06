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

/// 一条诊断结论。
class Diagnosis {
  const Diagnosis({
    required this.level,
    required this.title,
    required this.detail,
  });

  final DiagnosisLevel level;

  /// 一句话结论。
  final String title;

  /// 说清楚**为什么**，以及**能做什么**。
  ///
  /// 只有结论没有下一步的诊断等于噪音——用户看完只会困惑。
  final String detail;
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
      title: '整晚几乎没有触发分析',
      detail: '所有窗口都没越过能量门控。常见原因：手机被被子或枕头挡住、'
          '离得太远、或者麦克风权限被系统收回了。'
          '建议把手机放在枕边、屏幕朝上、不要盖东西。',
    ));
    return out;
  }

  final inferredRatio = s.windowsInferred / s.windowsTotal;
  if (isFullNight && inferredRatio < 0.02) {
    out.add(Diagnosis(
      level: DiagnosisLevel.warning,
      title: '只有极少窗口触发了分析',
      detail: '整晚 ${(inferredRatio * 100).toStringAsFixed(1)}% 的窗口越过了'
          '能量门控（${s.windowsInferred}/${s.windowsTotal}）。'
          '如果那晚确实有打鼾，说明手机可能被挡住或放得太远。',
    ));
  }

  // ---- 整晚都有声音，但模型基本认不出来 ----
  //
  // 光看低置信度比例会误报：**安静的一夜比例也很高**——VAD 只放行零星几声，
  // 模型对这零星几声自然没什么把握。实测在安静房间里就是 10/11 = 91%。
  // 那是正常结果，不该报警。
  //
  // 真正异常的是「整晚大部分时间都有声音，而模型几乎什么都认不出」——
  // 那说明有持续的低频噪声（风扇、空调、雨声）占满了整晚。
  if (isFullNight && inferredRatio > 0.5 && s.windowsInferred > 20) {
    final lowConfRatio = s.windowsLowConfidence / s.windowsInferred;
    if (lowConfRatio > 0.9) {
      out.add(Diagnosis(
        level: DiagnosisLevel.warning,
        title: '整晚都有声音，但模型几乎都认不出来',
        detail: '${(inferredRatio * 100).toStringAsFixed(0)}% 的窗口都有声音'
            '（越过了能量门控），其中 ${(lowConfRatio * 100).toStringAsFixed(0)}% '
            '模型没有把握。通常是持续的背景噪声——风扇、空调、雨声、电视。'
            '这类声音会被算进分析但归不了类。',
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
      title: '鼾声占比异常高（${s.snoreIndex.toStringAsFixed(0)}%）',
      detail: '整晚有一半以上的时间被判定为鼾声。持续的低频噪声——'
          '风扇、空调、抽湿机——很容易被听成鼾声。'
          '如果那晚确实打了一整夜，这条可以忽略。',
    ));
  }

  // ---- 录了很久却一个事件都没有 ----
  if (isFullNight && s.eventCount == 0 && s.windowsInferred > 0) {
    out.add(const Diagnosis(
      level: DiagnosisLevel.info,
      title: '整晚没有检出任何声音事件',
      detail: '有窗口进了模型，但都没达到置信度门槛。'
          '如果那晚环境很安静，这是正常结果。',
    ));
  }

  return out;
}

/// 这次录音有没有值得用户看一眼的问题。
bool hasWarnings(List<Diagnosis> diagnoses) =>
    diagnoses.any((d) => d.level == DiagnosisLevel.warning);
