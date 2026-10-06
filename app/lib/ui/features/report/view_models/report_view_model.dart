import 'dart:async';

import 'package:flutter/foundation.dart';
import '../../../../data/services/event_player.dart';
import '../../../../domain/models/recording_session.dart';
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
  StreamSubscription<bool>? _sub;

  int _playingIndex = -1;
  int _loadingIndex = -1;
  String? _error;

  RecordingSession get session => _session;

  /// 正在播放的事件下标，-1 表示没有。
  int get playingIndex => _playingIndex;

  /// 正在解析文件路径的事件下标（点击到出声之间的短暂间隔）。
  int get loadingIndex => _loadingIndex;

  String? get error => _error;

  bool isPlaying(int index) => index == _playingIndex;
  bool isLoading(int index) => index == _loadingIndex;

  /// 点同一个事件是"停"，点别的会切换过去。
  Future<void> togglePlay(int index) async {
    if (index < 0 || index >= _session.events.length) return;
    final player = _player;
    if (player == null) return;

    _error = null;

    if (_playingIndex == index) {
      await player.stop();
      _playingIndex = -1;
      notifyListeners();
      return;
    }

    final event = _session.events[index];
    final relative = event.clipPath;
    if (relative == null || relative.isEmpty) return;

    _loadingIndex = index;
    notifyListeners();

    final absolute = await _clipStore.resolve(relative);
    if (absolute == null) {
      // 文件被清理掉了（用户删过、或系统清过缓存）。说清楚原因，
      // 不要只是"点了没反应"。
      _loadingIndex = -1;
      _error = '这段音频已经不在了';
      notifyListeners();
      return;
    }

    // 不能 await play()。just_audio 的 play() 返回的 Future 要等到**播放结束**
    // 才 resolve，await 它就意味着"正在播放"这个状态在整个片段期间都设不上，
    // 界面会一直转圈。播放结束由 playingStream 通知。
    unawaited(player.play(absolute));

    _loadingIndex = -1;
    _playingIndex = index;
    notifyListeners();
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
