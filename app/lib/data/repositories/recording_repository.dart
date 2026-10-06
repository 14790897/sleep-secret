import 'dart:async';
import 'dart:typed_data';

import '../../domain/analysis/analysis_config.dart';
import '../../domain/analysis/night_analysis_engine.dart';
import '../../domain/models/recording_session.dart';
import '../../domain/models/recording_state.dart';
import '../../domain/repositories/audio_clip_store.dart';
import '../../domain/repositories/recording_controller.dart';
import '../../domain/repositories/sleep_analyzer.dart';
import '../services/audio_capture_service.dart';
import '../services/foreground_service_controller.dart';
import '../services/session_database.dart';

/// 整夜录音的编排层：串起采集 → 分析 → 落库。
///
/// 录音期间只保留「分析结果」（事件时间戳），不保存原始音频——
/// 8 小时 16kHz 单声道约 920MB，全存既没必要也放不下。
class RecordingRepository implements RecordingController {
  RecordingRepository({
    required this._capture,
    required SleepAnalyzer analyzer,
    required this._database,
    required this._foregroundService,
    AudioClipStore? clipStore,
    AnalysisConfig config = const AnalysisConfig(),
    DateTime Function()? clock,
  })  : _analyzer = analyzer,
        _clipStore = clipStore,
        _engine = NightAnalysisEngine(
          analyzer: analyzer,
          config: config,
          clipStore: clipStore,
        ),
        _clock = clock ?? DateTime.now;

  final AudioCapture _capture;
  final SleepAnalyzer _analyzer;
  final SessionDatabase _database;
  final ForegroundServiceController _foregroundService;
  final AudioClipStore? _clipStore;
  final NightAnalysisEngine _engine;

  /// 取当前时间。抽成可注入是为了测试能控制时间流逝。
  final DateTime Function() _clock;

  final _stateController = StreamController<RecordingState>.broadcast();
  RecordingState _state = const RecordingState();

  StreamSubscription<Uint8List>? _pcmSubscription;
  Timer? _ticker;
  DateTime? _startedAt;

  /// 串行化闸门。PCM 块持续到达而推理是异步的，若两次处理重叠，
  /// 窗口会乱序进入累积器——事件时间线就毁了。
  Future<void> _queue = Future.value();

  /// 排队等待处理的 PCM 块数。持续增长说明推理跟不上采集速度。
  int _backlog = 0;
  int _maxBacklog = 0;

  static const String _kRecordClips = 'record_clips';

  /// 通知权限被拒时给用户看的话。
  ///
  /// 说清楚两件事：**录音没断**，以及**代价是什么**。
  /// 「关于」页写着「录音期间会有一条常驻通知」——那句话在权限被拒时是假的，
  /// 所以这里必须明确纠正，不能装作无事发生。
  static const String _notificationWarning =
      '通知权限被拒绝，录音期间不会显示常驻通知。录音本身不受影响，'
      '但系统在后台清理时更容易把它一并杀掉。'
      '建议到「设置 → 应用 → 睡眠录音 → 通知」里允许通知，'
      '并把省电策略改成「无限制」。';

  bool _recordClips = true;
  bool _settingsLoaded = false;

  /// 录音期间观察到的最大积压。非零且很大意味着设备跑不动这套配置，
  /// 需要调大 VAD 阈值或窗口长度。
  int get maxBacklog => _maxBacklog;

  @override
  RecordingState get state => _state;

  @override
  Stream<RecordingState> get states => _stateController.stream;

  void _emit(RecordingState next) {
    _state = next;
    if (!_stateController.isClosed) _stateController.add(next);
  }

  @override
  Future<bool> ensurePermission() => _capture.hasPermission(request: true);

  @override
  Future<void> start() async {
    if (_state.isRecording) return;

    final granted = await ensurePermission();
    if (!granted) {
      _emit(_state.copyWith(
        isRecording: false,
        error: '未获得麦克风权限，无法录音',
      ));
      return;
    }

    // 通知权限要在录音开始前申请：权限弹窗会打断流程，放在开始之后
    // 会让会话起始时间和音频真正开始的时刻对不上。
    //
    // 被拒也照常往下走——可见的常驻通知是保活手段，不是录音的前提。
    final notificationsOk =
        await _foregroundService.ensureNotificationPermission();

    await _analyzer.initialize();
    await _ensureSettingsLoaded();

    // 会话起始时间取这一刻，而不是用户按下按钮那一刻——中间隔着权限弹窗
    // 和模型加载，实测能差十几秒，写进会话会让计时和事件时间轴整体偏早。
    final actualStart = _clock();

    try {
      _startedAt = actualStart;
      _engine.reset();
      _engine.start(actualStart);
      _backlog = 0;
      _maxBacklog = 0;

      await _foregroundService.start(
        title: '睡眠录音中',
        text: '正在记录整夜声音',
      );

      final stream = await _capture.start();
      _pcmSubscription = stream.listen(
        _enqueue,
        onError: (Object e) => _emit(_state.copyWith(error: '录音流出错: $e')),
        cancelOnError: false,
      );

      // 每秒推一次状态即可。按 PCM 块推会把界面刷爆。
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _publish());

      _emit(_state.copyWith(
        isRecording: true,
        startedAt: actualStart,
        clearError: true,
        warning: notificationsOk ? null : _notificationWarning,
        clearWarning: notificationsOk,
      ));
    } catch (e) {
      await _teardown();
      _emit(_state.copyWith(isRecording: false, error: '启动录音失败: $e'));
    }
  }

  void _enqueue(Uint8List chunk) {
    _backlog++;
    if (_backlog > _maxBacklog) _maxBacklog = _backlog;

    _queue = _queue.then((_) async {
      try {
        await _engine.feedPcm(chunk);
      } catch (e) {
        // 单块失败不该中断整夜录音。
        _emit(_state.copyWith(error: '分析出错: $e'));
      } finally {
        _backlog--;
      }
    });
  }

  void _publish() {
    if (!_state.isRecording) return;
    final started = _startedAt;
    _emit(_state.copyWith(
      elapsed: started == null ? Duration.zero : _clock().difference(started),
      windowsProcessed: _engine.windowsProcessed,
      windowsInferred: _engine.windowsInferred,
      eventCount: _engine.events.length,
      snoreEventCount: _engine.events.where((e) => e.isSnore).length,
      inferenceErrors: _engine.inferenceErrors,
      inputLevel: _engine.lastRms,
      peakLevel: _engine.peakRms,
    ));
  }

  @override
  Future<RecordingSession?> stop() async {
    if (!_state.isRecording) return null;

    final endedAt = _clock();
    final startedAt = _startedAt ?? endedAt;
    await _teardown();

    final outcome = await _engine.finish();
    final session = _engine.toSession(startedAt, endedAt, outcome);

    final id = await _database.insertSession(session);

    _emit(_state.copyWith(
      isRecording: false,
      elapsed: endedAt.difference(startedAt),
      windowsProcessed: outcome.stats.windowsTotal,
      windowsInferred: outcome.stats.windowsInferred,
      eventCount: outcome.stats.eventCount,
      snoreEventCount: outcome.stats.snoreEventCount,
      inferenceErrors: _engine.inferenceErrors,
      // 录音已经结束，这次的通知权限提醒就过期了
      clearWarning: true,
    ));

    return session.copyWith(id: id);
  }

  /// 停掉采集、前台服务与定时器。重复调用安全。
  Future<void> _teardown() async {
    _ticker?.cancel();
    _ticker = null;

    await _pcmSubscription?.cancel();
    _pcmSubscription = null;

    // 等队列里排着的块处理完再收尾，否则会丢掉最后几秒。
    await _queue;

    try {
      await _capture.stop();
    } catch (_) {
      // 已经停了就算了，不该因此让 stop() 失败。
    }
    try {
      await _foregroundService.stop();
    } catch (_) {
      // 同上。
    }
  }

  @override
  bool get recordClips => _recordClips;

  @override
  Future<void> setRecordClips(bool enabled) async {
    _recordClips = enabled;
    // 立刻作用到引擎，而不是等下次启动——这是隐私开关，
    // 用户关掉就该马上停止落盘。
    _engine.recordClips = enabled;
    await _database.open();
    await _database.writeBoolSetting(_kRecordClips, enabled);
  }

  /// 读一次设置。放在 start() 里做，避免构造时就碰数据库。
  Future<void> _ensureSettingsLoaded() async {
    if (_settingsLoaded) return;
    _settingsLoaded = true;
    await _database.open();
    _recordClips =
        await _database.readBoolSetting(_kRecordClips, fallback: true);
    _engine.recordClips = _recordClips;
  }

  @override
  Future<List<RecordingSession>> listSessions() async {
    await _database.open();
    return _database.listSessions();
  }

  @override
  Future<RecordingSession?> loadSession(int id) async {
    await _database.open();
    return _database.loadSession(id);
  }

  @override
  Future<void> deleteSession(int id) async {
    await _database.open();

    // 先删音频文件再删数据库行——反过来的话会话记录没了，
    // 就再也定位不到那次的片段目录，文件会永久残留。
    final session = await _database.loadSession(id);
    if (session != null) {
      await _clipStore?.deleteSession(session.startedAt);
    }

    await _database.deleteSession(id);
  }

  @override
  Future<void> dispose() async {
    await _teardown();
    await _stateController.close();
    await _database.close();
    await _capture.dispose();
  }
}
