import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// 事件片段播放器。
///
/// 抽成接口是为了让 ViewModel 能在测试里注入假实现——测试环境没有音频设备。
abstract interface class EventPlayer {
  /// 播放指定文件，会替换掉当前正在播的。
  Future<void> play(String absolutePath);

  Future<void> stop();

  /// 是否正在播放。播放自然结束、被停止或出错都会变回 false。
  Stream<bool> get playingStream;

  Future<void> dispose();
}

/// 基于 `just_audio` 的实现。
class JustAudioEventPlayer implements EventPlayer {
  JustAudioEventPlayer({AudioPlayer? player})
      : _player = player ?? AudioPlayer() {
    _sub = _player.playerStateStream.listen((state) {
      final playing = state.playing &&
          state.processingState != ProcessingState.completed;
      if (playing != _playing) {
        _playing = playing;
        if (!_controller.isClosed) _controller.add(playing);
      }
    });
  }

  final AudioPlayer _player;
  late final StreamSubscription<PlayerState> _sub;
  final _controller = StreamController<bool>.broadcast();

  bool _playing = false;

  @override
  Stream<bool> get playingStream => _controller.stream;

  @override
  Future<void> play(String absolutePath) async {
    try {
      // 用 setFilePath 而不是 setAudioSource：片段是本地小文件，
      // 不需要交给平台的媒体库去索引，也就不会出现在系统播放列表里。
      await _player.setFilePath(absolutePath);
      await _player.play();
    } catch (_) {
      // 文件被删、格式损坏等都不该让界面崩掉
      if (!_controller.isClosed) _controller.add(false);
    }
  }

  @override
  Future<void> stop() async {
    try {
      await _player.stop();
    } catch (_) {
      // 已经停了就算了
    }
  }

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    await _controller.close();
    await _player.dispose();
  }
}
