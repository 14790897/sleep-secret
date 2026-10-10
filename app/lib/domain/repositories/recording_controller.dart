import '../models/recording_session.dart';
import '../models/recording_state.dart';

/// 整夜录音的契约。
abstract interface class RecordingController {
  /// 当前状态快照。
  RecordingState get state;

  /// 状态变化流。ViewModel 订阅它来刷新界面。
  Stream<RecordingState> get states;

  /// 申请录音权限。返回 false 表示用户拒绝，调用方应提示而不是硬来。
  Future<bool> ensurePermission();

  /// 是否为鼾声事件保存音频片段。
  ///
  /// 关掉之后 App 完全不落任何原始音频——这是隐私开关，会影响存储占用。
  bool get recordClips;

  Future<void> setRecordClips(bool enabled);

  /// 是否启用能量门控：安静窗口直接跳过，不送进模型。
  ///
  /// 默认**关着**（见 `AnalysisConfig.vadEnabled` 里那段说明）。打开能省算力，
  /// 并且报告里不会出现「整晚一条环境噪音」；代价是**比门槛轻的声音会被一起
  /// 跳掉**——门槛按房间噪声底自适应，但下限是 `vadRms/4`，非常轻的鼾声
  /// （手机放得远、隔着被子）可能就在那之下。
  bool get vadEnabled;

  Future<void> setVadEnabled(bool enabled);

  /// 开始整夜录音。已在进行中时是空操作。
  ///
  /// 不接收时间参数：会话起始时间应当是**音频真正开始采集的时刻**，
  /// 而不是用户按下按钮的时刻。两者之间隔着权限弹窗和模型加载，
  /// 可能相差十几秒，写进会话里会让计时和事件时间轴整体偏早。
  Future<void> start();

  /// 停止录音、落库，返回本次会话。未在录音时返回 null。
  Future<RecordingSession?> stop();

  Future<List<RecordingSession>> listSessions();

  Future<RecordingSession?> loadSession(int id);

  Future<void> deleteSession(int id);

  Future<void> dispose();
}
