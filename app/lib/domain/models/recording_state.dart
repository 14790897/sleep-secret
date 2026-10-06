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
    this.error,
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

  /// 出错信息。非 null 表示录音异常结束或无法开始。
  final String? error;

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
    String? error,
    bool clearError = false,
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
        error: clearError ? null : (error ?? this.error),
      );
}
