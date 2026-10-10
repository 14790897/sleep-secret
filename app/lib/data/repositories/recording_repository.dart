import 'dart:async';
import 'dart:typed_data';

import '../../domain/analysis/analysis_config.dart';
import '../../domain/analysis/night_analysis_engine.dart';
import '../../domain/models/recording_session.dart';
import '../../domain/models/recording_state.dart';
import '../../domain/repositories/audio_clip_store.dart';
import '../../l10n/app_strings.dart';
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
    this._autoExport,
  })  : _analyzer = analyzer,
        _clipStore = clipStore,
        _engine = NightAnalysisEngine(
          analyzer: analyzer,
          config: config,
          clipStore: clipStore,
        ),
        _vadDefault = config.vadEnabled,
        _clock = clock ?? DateTime.now;

  final AudioCapture _capture;
  final SleepAnalyzer _analyzer;
  final SessionDatabase _database;
  final ForegroundServiceController _foregroundService;
  final AudioClipStore? _clipStore;

  /// 一段录音**落库之后**被调用，用来自动导出到用户配的目录。
  ///
  /// 用回调而不是直接依赖导出那边：录音不该知道导出是怎么实现的，
  /// 而且测试里传 null 或一个假回调就行。
  final Future<void> Function(RecordingSession session)? _autoExport;
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
  static const String _kVadEnabled = 'vad_enabled';

  /// 通知权限被拒时给用户看的话。
  ///
  /// 说清楚两件事：**录音没断**，以及**代价是什么**。
  /// 「关于」页写着「录音期间会有一条常驻通知」——那句话在权限被拒时是假的，
  /// 所以这里必须明确纠正，不能装作无事发生。
  bool _recordClips = true;

  /// 能量门控。没拨过时用 [AnalysisConfig.vadEnabled] 的默认值。
  bool _vadEnabled = false;
  final bool _vadDefault;

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
        error: const RecordingError(RecordingErrorKind.micDenied),
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
        title: appStrings.notificationRecordingTitle,
        text: appStrings.notificationRecordingText,
      );

      final stream = await _capture.start();
      _pcmSubscription = stream.listen(
        _enqueue,
        onError: (Object e) => _emit(_state.copyWith(
            error: RecordingError(RecordingErrorKind.streamFailed, detail: '$e'))),
        cancelOnError: false,
      );

      // 每秒推一次状态即可。按 PCM 块推会把界面刷爆。
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _publish());

      _emit(_state.copyWith(
        isRecording: true,
        startedAt: actualStart,
        clearError: true,
        warning: notificationsOk ? null : RecordingWarningKind.notificationsDenied,
        clearWarning: notificationsOk,
      ));
    } catch (e) {
      await _teardown();
      _emit(_state.copyWith(
          isRecording: false,
          error: RecordingError(RecordingErrorKind.startFailed, detail: '$e')));
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
        _emit(_state.copyWith(error:
            RecordingError(RecordingErrorKind.analysisFailed, detail: '$e')));
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
      vadThreshold: _engine.vadThreshold,
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
    final saved = session.copyWith(id: id);

    // 自动导出。**故意不 await**：搬片段可能要好几秒，让用户点完「结束」
    // 还得多等一截。进度由导出那边自己报（`ArchiveController.busy`）。
    // 失败也只记在那边——这次录音已经落库了，不该被导出拖累。
    final export = _autoExport;
    if (export != null && saved.isFinished) {
      unawaited(export(saved));
    }

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

  @override
  bool get vadEnabled => _vadEnabled;

  @override
  Future<void> setVadEnabled(bool enabled) async {
    _vadEnabled = enabled;
    // 立刻作用到引擎。门槛和噪声底是**一直**在估的（见 NightAnalysisEngine
    // 构造里那段），所以拨开之后马上就有可用的阈值，不存在"要重新热一遍"。
    _engine.vadEnabled = enabled;
    await _database.open();
    await _database.writeBoolSetting(_kVadEnabled, enabled);
  }

  /// 读一次设置。放在 start() 里做，避免构造时就碰数据库。
  Future<void> _ensureSettingsLoaded() async {
    if (_settingsLoaded) return;
    _settingsLoaded = true;
    await _database.open();
    _recordClips =
        await _database.readBoolSetting(_kRecordClips, fallback: true);
    _engine.recordClips = _recordClips;
    _vadEnabled =
        await _database.readBoolSetting(_kVadEnabled, fallback: _vadDefault);
    _engine.vadEnabled = _vadEnabled;
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
