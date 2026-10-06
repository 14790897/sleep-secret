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
