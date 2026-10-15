/// 录音为什么停了 / 起不来。
///
/// **领域层只说"是哪种"，不说"这句话怎么写"**——文案在界面层按语言渲染
/// （见 `lib/ui/core/l10n/domain_text.dart`）。
///
/// 加多语言之前这里是直接把中文句子塞进 [RecordingState.error] 的，
/// 而 `RecordingRepository` 整条链上**拿不到 `BuildContext`**（它在
/// `main.dart` 的 initState 里装配，生命周期也长于任何页面）。
enum RecordingErrorKind {
  /// 没有麦克风权限。
  micDenied,

  /// 采集流本身出错。
  streamFailed,

  /// 起不来（前台服务、模型加载等）。
  startFailed,

  /// 分析环节出错。
  analysisFailed,
}

/// 一条录音错误。[detail] 是异常原文。
///
/// **异常原文要留给用户看**：它往往是报 bug 时唯一的线索。
/// 所以它不是日志，是界面文案的一部分——只不过这部分不翻译。
class RecordingError {
  const RecordingError(this.kind, {this.detail});

  final RecordingErrorKind kind;
  final String? detail;
}

/// 需要提醒、但**不影响录音继续**的事情。
enum RecordingWarningKind {
  /// 通知权限被拒——录音照跑，但后台被系统清掉的风险变高。
  notificationsDenied,
}

/// 录音进行中的实时状态，供界面展示。
class RecordingState {
  const RecordingState({
    this.isRecording = false,
    this.startedAt,
    this.elapsed = Duration.zero,
    this.windowsProcessed = 0,
    this.windowsInferred = 0,
    this.eventCount = 0,
    this.snoreEventCount = 0,
    this.inferenceErrors = 0,
    this.inputLevel = 0,
    this.peakLevel = 0,
    this.vadThreshold,
    this.error,
    this.warning,
  });

  final bool isRecording;
  final DateTime? startedAt;
  final Duration elapsed;

  /// 已经处理的窗口总数。
  final int windowsProcessed;

  /// 其中真正送进模型的窗口数。与总数的比值就是推理比例，
  /// 直接决定耗电。
  final int windowsInferred;

  final int eventCount;
  final int snoreEventCount;

  /// 推理失败的窗口数。持续增长说明模型或输入有问题。
  final int inferenceErrors;

  /// 最近一个窗口的输入电平（RMS）。界面用它画电平条。
  final double inputLevel;

  /// 本次录音以来的最高电平。
  final double peakLevel;

  /// **当前生效的**能量门控阈值。**能量门控关掉时为 null。**
  ///
  /// 阈值会随房间噪声底自适应，所以界面上的电平条必须画在这个位置，
  /// 不能画在配置的固定值上——两者不一样时，画错了就是在骗用户。
  /// 而门控关掉时根本没有"门槛"这回事，界面不该再画那条线。
  final double? vadThreshold;

  /// 出错信息。非 null 表示录音异常结束或无法开始。
  final RecordingError? error;

  /// 需要提醒、但**不影响录音继续**的事情。
  ///
  /// 和 [error] 的区别是严重的程度：error 意味着录音没在跑，
  /// warning 意味着在跑、但用户该知道某件事（比如通知权限被拒，
  /// 于是后台被系统清掉的风险变高了）。
  final RecordingWarningKind? warning;

  /// 实际推理比例。能量门控跳过的窗口不计入。
  double get inferenceRatio =>
      windowsProcessed == 0 ? 0.0 : windowsInferred / windowsProcessed;

  RecordingState copyWith({
    bool? isRecording,
    DateTime? startedAt,
    Duration? elapsed,
    int? windowsProcessed,
    int? windowsInferred,
    int? eventCount,
    int? snoreEventCount,
    int? inferenceErrors,
    double? inputLevel,
    double? peakLevel,
    double? vadThreshold,
    RecordingError? error,
    bool clearError = false,
    RecordingWarningKind? warning,
    bool clearWarning = false,
  }) =>
      RecordingState(
        isRecording: isRecording ?? this.isRecording,
        startedAt: startedAt ?? this.startedAt,
        elapsed: elapsed ?? this.elapsed,
        windowsProcessed: windowsProcessed ?? this.windowsProcessed,
        windowsInferred: windowsInferred ?? this.windowsInferred,
        eventCount: eventCount ?? this.eventCount,
        snoreEventCount: snoreEventCount ?? this.snoreEventCount,
        inferenceErrors: inferenceErrors ?? this.inferenceErrors,
        inputLevel: inputLevel ?? this.inputLevel,
        peakLevel: peakLevel ?? this.peakLevel,
        vadThreshold: vadThreshold ?? this.vadThreshold,
        error: clearError ? null : (error ?? this.error),
        warning: clearWarning ? null : (warning ?? this.warning),
      );
}
