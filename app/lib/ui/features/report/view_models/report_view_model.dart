import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../../../data/models/sleep_class_map.dart';
import '../../../../data/services/event_player.dart';
import '../../../../domain/models/recording_session.dart';
import '../../../../domain/models/ui_message.dart';
import '../../../../domain/repositories/audio_clip_store.dart';

/// 报告详情页的 ViewModel。
///
/// 除了持有会话数据，主要管片段播放：把点击的事件对应到音频文件、
/// 解析相对路径、控制播放状态。
class ReportViewModel extends ChangeNotifier {
  ReportViewModel({
    required this._session,
    required this._clipStore,
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

  final RecordingSession _session;
  final AudioClipStore _clipStore;
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

  RecordingSession get session => _session;

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
    if (index < 0 || index >= _session.events.length) return null;
    final player = _player;
    if (player == null) return null;

    final event = _session.events[index];
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

  @override
  void dispose() {
    _sub?.cancel();
    // 视图销毁时把声音停掉——报告页退出了还在响会很突兀
    _player?.stop();
    super.dispose();
  }
}
