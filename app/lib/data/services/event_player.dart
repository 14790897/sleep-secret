import 'dart:async';

import 'package:just_audio/just_audio.dart';

/// 事件片段播放器。
///
/// 抽成接口是为了让 ViewModel 能在测试里注入假实现——测试环境没有音频设备。
///
/// 除了「放 / 停」，还要**位置**和**跳转**：播放面板上有波形和进度条，
/// 用户得看得见播到哪儿了，也得能拖回去重听某一句。
abstract interface class EventPlayer {
  /// 播放指定文件，会替换掉当前正在播的。
  Future<void> play(String absolutePath);

  /// 暂停。[resume] 从暂停处接着放。
  Future<void> pause();
  Future<void> resume();

  /// 跳到某个位置。越界由实现自己夹——界面不该关心这件事。
  Future<void> seek(Duration position);

  Future<void> stop();

  /// 是否正在播放。播放自然结束、被停止或出错都会变回 false。
  Stream<bool> get playingStream;

  /// 当前播放位置。字面意思：没在放的时候不保证发。
  Stream<Duration> get positionStream;

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
  Stream<Duration> get positionStream => _player.positionStream;

  @override
  Future<void> pause() async {
    try {
      await _player.pause();
    } catch (_) {
      // 播放器已经没了就当暂停成功——面板上那个按钮不该因为这就点不动
    }
  }

  @override
  Future<void> resume() async {
    try {
      await _player.play();
    } catch (_) {}
  }

  @override
  Future<void> seek(Duration position) async {
    try {
      await _player.seek(position);
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await _sub.cancel();
    await _controller.close();
    await _player.dispose();
  }
}
