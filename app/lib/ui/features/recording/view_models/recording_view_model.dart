import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../domain/models/recording_session.dart';
import '../../../../domain/models/recording_state.dart';
import '../../../../domain/repositories/recording_controller.dart';

/// 录音页的 ViewModel。
///
/// 只做两件事：把 [RecordingController] 的状态流转成 ChangeNotifier，
/// 以及把「开始/停止」这类用户意图翻译成对控制器的调用。
class RecordingViewModel extends ChangeNotifier {
  RecordingViewModel({required RecordingController controller})
      : _controller = controller,
        _state = controller.state {
    _subscription = _controller.states.listen((s) {
      _state = s;
      notifyListeners();
    });
  }

  final RecordingController _controller;
  StreamSubscription<RecordingState>? _subscription;

  RecordingState _state;
  RecordingState get state => _state;

  bool _busy = false;

  /// 正在处理一次开始/停止操作。用于禁用按钮，防止连点。
  bool get busy => _busy;

  List<RecordingSession> _sessions = const [];
  List<RecordingSession> get sessions => _sessions;

  bool _loadingSessions = false;
  bool get loadingSessions => _loadingSessions;

  /// 开始或停止录音。行为取决于当前是否在录。
  Future<void> toggle() async {
    if (_busy) return;
    _busy = true;
    notifyListeners();

    try {
      if (_state.isRecording) {
        await _controller.stop();
        await loadSessions();
      } else {
        await _controller.start();
      }
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<void> loadSessions() async {
    _loadingSessions = true;
    notifyListeners();
    try {
      _sessions = await _controller.listSessions();
    } catch (e) {
      debugPrint('加载会话列表失败: $e');
      _sessions = const [];
    } finally {
      _loadingSessions = false;
      notifyListeners();
    }
  }

  Future<RecordingSession?> loadSession(int id) => _controller.loadSession(id);

  /// 是否为鼾声事件保存音频片段。
  bool get recordClips => _controller.recordClips;

  Future<void> setRecordClips(bool enabled) async {
    await _controller.setRecordClips(enabled);
    notifyListeners();
  }

  Future<void> deleteSession(int id) async {
    await _controller.deleteSession(id);
    await loadSessions();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}

/// 把时长格式化成 `H:MM:SS`，界面统一用它。
String formatDuration(Duration d) {
  final hours = d.inHours;
  final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$hours:$minutes:$seconds';
}

/// 把秒数格式化成 `MM:SS`，用于事件时间点。
String formatClock(double seconds) {
  final total = seconds.round();
  final m = (total ~/ 60).toString().padLeft(2, '0');
  final s = (total % 60).toString().padLeft(2, '0');
  return '$m:$s';
}
