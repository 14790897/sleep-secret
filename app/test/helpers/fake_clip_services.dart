import 'dart:async';
import 'dart:typed_data';

import 'package:sleep_secret/data/services/event_player.dart';
import 'package:sleep_secret/domain/repositories/audio_clip_store.dart';

/// 内存版片段存储，用来验证"写了什么、删了什么"。
class FakeAudioClipStore implements AudioClipStore {
  /// 相对路径 -> 音频数据。
  final Map<String, Float32List> saved = {};

  /// 这些路径 resolve 时返回 null，模拟文件已被清理。
  final Set<String> missingFiles = {};

  /// 记录每次 save 的会话目录，用来验证按会话删除。
  final List<DateTime> savedSessions = [];
  final List<DateTime> deletedSessions = [];

  bool failOnSave = false;

  /// 流式写下来的整段音频（相对路径 -> 采样点）。
  ///
  /// 和 [saved] 分开：那个是 [save]（一次性给整段）留下的，
  /// 这个是 [begin] 那条路（边录边写）留下的。测试要判断"整段事件
  /// 是不是都写进去了"，看这个。
  final Map<String, List<double>> streamed = {};

  /// 被 release 掉的段（不是鼾声、或者开头没补全）。测试用来断言"没留下垃圾"。
  final List<String> released = [];

  bool failOnBegin = false;

  @override
  Future<ClipWriter?> begin({
    required DateTime sessionStartedAt,
    required double startSeconds,
    required int sampleRate,
  }) async {
    if (failOnBegin) return null;
    final key = '${sessionStartedAt.millisecondsSinceEpoch}'
        '/${(startSeconds * 1000).round()}.wav';
    final buffer = <double>[];
    return _FakeClipWriter(
      key,
      buffer,
      () {
        saved[key] = Float32List.fromList(buffer);
        streamed[key] = buffer;
        savedSessions.add(sessionStartedAt);
      },
      () => released.add(key),
    );
  }

  /// 导入时采用的路径。内存版没有真实文件，只记下调用。
  final List<({String relativePath, String localPath})> adopted = [];
  bool failOnAdopt = false;

  @override
  Future<bool> adopt({
    required String relativePath,
    required String localPath,
  }) async {
    if (failOnAdopt) return false;
    adopted.add((relativePath: relativePath, localPath: localPath));
    saved[relativePath] = Float32List(0);
    return true;
  }

  @override
  Future<String?> save({
    required DateTime sessionStartedAt,
    required double startSeconds,
    required Float32List samples,
    required int sampleRate,
  }) async {
    if (failOnSave) return null;
    final key = '${sessionStartedAt.millisecondsSinceEpoch}'
        '/${(startSeconds * 1000).round()}.wav';
    saved[key] = samples;
    savedSessions.add(sessionStartedAt);
    return key;
  }

  @override
  Future<String?> resolve(String relativePath) async {
    if (missingFiles.contains(relativePath)) return null;
    if (!saved.containsKey(relativePath)) return null;
    return '/fake/clips/$relativePath';
  }

  @override
  Future<void> deleteSession(DateTime sessionStartedAt) async {
    deletedSessions.add(sessionStartedAt);
    final prefix = '${sessionStartedAt.millisecondsSinceEpoch}/';
    saved.removeWhere((k, _) => k.startsWith(prefix));
  }

  @override
  Future<void> deleteAll() async {
    saved.clear();
    savedSessions.clear();
  }
}

/// 只记录调用的播放器——测试环境没有音频设备。
///
/// **刻意模仿 just_audio 的一个关键行为**：`play()` 返回的 Future 要等到
/// 播放结束才 resolve，而不是一调用就返回。真实播放器就是这样，
/// 假实现如果立刻返回，就会漏掉"await play() 导致界面永远转圈"这类 bug。
class FakeEventPlayer implements EventPlayer {
  final _controller = StreamController<bool>.broadcast();

  String? currentPath;
  int playCount = 0;
  int stopCount = 0;
  bool disposed = false;

  Completer<void>? _playing;

  @override
  Stream<bool> get playingStream => _controller.stream;

  @override
  Future<void> play(String absolutePath) {
    playCount++;
    currentPath = absolutePath;
    if (!_controller.isClosed) _controller.add(true);

    // 与 just_audio 一致：这个 Future 到播放结束才完成
    _playing = Completer<void>();
    return _playing!.future;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    currentPath = null;
    if (!_controller.isClosed) _controller.add(false);
    _completePlayback();
  }

  /// 手动模拟播放结束（播到尾巴、或系统打断）。
  void finishNaturally() {
    currentPath = null;
    if (!_controller.isClosed) _controller.add(false);
    _completePlayback();
  }

  void _completePlayback() {
    final c = _playing;
    _playing = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    _completePlayback();
    await _controller.close();
    await _positions.close();
  }

  // ------------------------------------------------------------ 位置与跳转
  //
  // 播放面板要靠这两样：进度条跟着 positionStream 走，拖动时调 seek。

  final _positions = StreamController<Duration>.broadcast();

  int pauseCount = 0;
  int resumeCount = 0;
  int seekCount = 0;
  Duration? lastSeek;

  @override
  Stream<Duration> get positionStream => _positions.stream;

  /// 手动推一个位置，模拟 just_audio 的 positionStream。
  void emitPosition(Duration position) {
    if (!_positions.isClosed) _positions.add(position);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    if (!_controller.isClosed) _controller.add(false);
  }

  @override
  Future<void> resume() async {
    resumeCount++;
    if (!_controller.isClosed) _controller.add(true);
  }

  @override
  Future<void> seek(Duration position) async {
    seekCount++;
    lastSeek = position;
  }
}

/// 内存版写入器：先攒在 list 里，finish 时一次性落进 store。
class _FakeClipWriter implements ClipWriter {
  _FakeClipWriter(this.relativePath, this._buffer, this._onFinish, this._onRelease);

  final String relativePath;
  final List<double> _buffer;
  final void Function() _onFinish;
  final void Function() _onRelease;

  bool _closed = false;

  @override
  Future<void> append(Float32List samples) async {
    if (_closed) return;
    _buffer.addAll(samples);
  }

  @override
  Future<String?> finish() async {
    if (_closed) return null;
    _closed = true;
    if (_buffer.isEmpty) return null;
    _onFinish();
    return relativePath;
  }

  @override
  Future<void> release() async {
    if (_closed) return;
    _closed = true;
    _onRelease();
  }
}
