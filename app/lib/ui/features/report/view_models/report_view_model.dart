import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../../../data/models/sleep_class_map.dart';
import '../../../../data/services/event_player.dart';
import '../../../../domain/analysis/night_grouping.dart';
import '../../../../domain/analysis/snore_display_filter.dart';
import '../../../../domain/models/recording_session.dart';
import '../../../../domain/models/sound_event.dart';
import '../../../../domain/models/ui_message.dart';
import '../../../../domain/repositories/audio_clip_store.dart';
import '../../../../domain/repositories/recording_controller.dart';

/// 报告详情页的 ViewModel。
///
/// 除了持有会话数据，主要管片段播放：把点击的事件对应到音频文件、
/// 解析相对路径、控制播放状态。
class ReportViewModel extends ChangeNotifier {
  ReportViewModel({
    required this._session,
    required this._clipStore,
    required this._settings,
    this.gaps = const [],
    this._player,
    this.classMap,
  }) {
    _sub = _player?.playingStream.listen((playing) {
      if (!playing) {
        _playingIndex = -1;
        _loadingIndex = -1;
        notifyListeners();
      }
    });
  }

  RecordingSession _session;
  final AudioClipStore _clipStore;

  /// 同一晚中间停止再开始的空档。单段录音 / 老记录为空。
  final List<SessionGap> gaps;

  /// 中间醒着的总时长。
  Duration get awakeDuration =>
      gaps.fold(Duration.zero, (sum, gap) => sum + gap.duration);

  /// 这一晚包含的所有录音段 id（合并夜有多段）。删片段时逐段删。
  ///
  /// 默认是当前会话自己的 id；[openReportPage] 打开合并夜时会覆盖成全部段。
  late List<int> segmentIds = [if (_session.id != null) _session.id!];

  /// 用户是否在这一次打开报告时删掉了片段（删完卡片要说明原因）。
  bool _clipsDeleted = false;
  bool get clipsDeleted => _clipsDeleted;

  /// 鼾声展示门槛的读写口。
  ///
  /// 设置本身存在录音仓库那边——它是 settings 表的唯一所有者，
  /// 再开一个只读一个整数的仓库不值当。这里只转发。
  final RecordingController _settings;
  final EventPlayer? _player;

  /// 映射表，用来在「详细视图」里把原始标签对照到大类。
  ///
  /// **可选**：拿不到就只是不显示那一列对照，报告本身照常渲染——
  /// 这是核查用的附加信息，不该成为打开报告的前提。
  final SleepClassMap? classMap;
  StreamSubscription<bool>? _sub;

  int _playingIndex = -1;
  int _loadingIndex = -1;
  UiMessage? _error;

  /// 鼾声展示门槛（百分比）。**0 表示不筛**，全部显示——这也是默认值。
  int get snoreThresholdPercent => _settings.snoreThresholdPercent;

  Future<void> setSnoreThresholdPercent(int percent) async {
    if (percent == snoreThresholdPercent) return;
    // ⚠️ 先停掉正在播的片段：过滤一改，列表的下标就指到别的事件上了。
    // 不停的话面板还在响，而它对应的已经不是同一段声音。
    await stopPlayback();
    await _settings.setSnoreThresholdPercent(percent);
    _visible = null;
    notifyListeners();
  }

  /// 这一夜一共有多少段鼾声（**未筛**）。
  ///
  /// 界面要拿它和筛后的段数相减，才能说出「还有 N 段没有显示」——
  /// 少了这个数，用户看到的就是一份「变干净了」的报告，
  /// 而看不出这份干净是筛出来的。
  int get allSnoreCount => _session.stats.snoreEventCount;

  /// 筛过之后的会话。**报告页整页都读它**（[ReportView] 里所有 `session.*`
  /// 都是这一个），所以门槛一改整页跟着变——事件列表、时间线、鼾声时长、
  /// 鼾声指数、类别分布、每小时分布全都是从 `events` 现算的，不必逐处改。
  ///
  /// **只筛鼾声**：别的类别不会因为这个门槛消失。
  RecordingSession get session => _visible ??= _filtered();

  RecordingSession? _visible;

  RecordingSession _filtered() => applySnoreThreshold(
        _session,
        snoreThresholdPercent,
      );

  /// 正在播放的事件下标，-1 表示没有。
  int get playingIndex => _playingIndex;

  /// 正在解析文件路径的事件下标（点击到出声之间的短暂间隔）。
  int get loadingIndex => _loadingIndex;

  UiMessage? get error => _error;

  bool isPlaying(int index) => index == _playingIndex;
  bool isLoading(int index) => index == _loadingIndex;

  /// 播放面板要用它来放、暂停、拖进度。
  EventPlayer? get player => _player;

  /// 打开某个事件的片段：解析路径、开始播放，再把面板要的两样东西给它。
  ///
  /// 返回 null 表示这个事件现在放不了——没有片段，或者文件已经不在了
  /// （后者会顺带把错误挂到 [error] 上，界面照常显示原因）。
  ///
  /// ⚠️ 这里**没有**「再点一次就停」：播放面板是模态的，盖住列表之后
  /// 根本点不到第二下，停由面板自己负责（关面板就停）。
  Future<({String path, double eventSeconds})?> openClip(int index) async {
    // 用**筛过之后**的列表：界面上的下标就是它的下标。
    final events = session.events;
    if (index < 0 || index >= events.length) return null;
    final player = _player;
    if (player == null) return null;

    final event = events[index];
    final relative = event.clipPath;
    if (relative == null || relative.isEmpty) return null;

    _error = null;
    _loadingIndex = index;
    notifyListeners();

    final absolute = await _clipStore.resolve(relative);
    if (absolute == null) {
      // 文件被清理掉了（用户删过、或系统清过缓存）。说清楚原因，
      // 不要只是"点了没反应"。
      _loadingIndex = -1;
      _error = const UiMessage(UiMessageKind.reportClipMissing);
      notifyListeners();
      return null;
    }

    // 不能 await play()。just_audio 的 play() 返回的 Future 要等到**播放结束**
    // 才 resolve，await 它就意味着"正在播放"这个状态在整个片段期间都设不上，
    // 界面会一直转圈。播放结束由 playingStream 通知。
    unawaited(player.play(absolute));

    _loadingIndex = -1;
    _playingIndex = index;
    notifyListeners();
    return (path: absolute, eventSeconds: event.durationSeconds);
  }

  Future<void> stopPlayback() async {
    await _player?.stop();
    _playingIndex = -1;
    _loadingIndex = -1;
    notifyListeners();
  }

  /// 删除这一晚的所有录音片段，**保留事件、统计和时间线**。
  ///
  /// 先停播放：文件的目录马上要被删掉。
  Future<void> deleteClips() async {
    if (!_session.events.any((e) => e.hasClip)) return;
    await stopPlayback();
    for (final id in segmentIds) {
      await _settings.deleteClipsForSession(id);
    }
    _session = _session.copyWith(
      events: [
        for (final event in _session.events)
          event.hasClip ? event.withClip(null) : event,
      ],
    );
    _visible = null;
    _clipsDeleted = true;
    notifyListeners();
  }

  /// 标记/撤销单个事件的用户标注（「这不是鼾声」）。
  ///
  /// 按事件 id 定位，而不是按下标：报告页可能先按展示门槛筛过事件，
  /// 筛后的下标和原始事件列表对不上。
  Future<void> setUserLabelForEvent(
    SoundEvent event,
    EventUserLabel? label,
  ) async {
    final events = [..._session.events];
    final index = events.indexWhere((e) => e.id != null && e.id == event.id);
    if (index < 0) return;
    final id = events[index].id!;
    await _settings.updateEventUserLabel(id, label);
    events[index] = events[index].withUserLabel(label);
    _session = _session.copyWith(
      events: events,
      stats: statsForEvents(_session.stats, events),
    );
    _visible = null;
    notifyListeners();
  }

  /// 测试/内部用的按下标版本（下标针对**未筛**的原始事件）。
  Future<void> setUserLabel(int index, EventUserLabel? label) =>
      setUserLabelForEvent(_session.events[index], label);

  @override
  void dispose() {
    _sub?.cancel();
    // 视图销毁时把声音停掉——报告页退出了还在响会很突兀
    _player?.stop();
    super.dispose();
  }
}
