import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import '../../domain/repositories/audio_clip_store.dart';
import 'wav_encoder.dart';

/// 把事件片段写成 WAV 文件，存在应用的私有目录里。
///
/// 用 `getApplicationSupportDirectory`（应用私有），不是相册或公共音乐目录——
/// 睡眠录音属于敏感内容，不该出现在用户随手能翻到的地方，也不该被其他应用读到。
///
/// 目录结构：`<support>/clips/<会话开始毫秒>/<起始秒>.wav`。
/// 以会话分组既方便整晚删除，也让"某次录音的片段"能一眼找全。
class FileAudioClipStore implements AudioClipStore {
  FileAudioClipStore({Directory? baseDirectory}) : _injectedBase = baseDirectory;

  static const String _rootName = 'clips';

  final Directory? _injectedBase;
  Directory? _root;

  /// 写入失败的次数。持续增长说明磁盘满了或权限有问题。
  int failureCount = 0;

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = _injectedBase ?? await getApplicationSupportDirectory();
    final root = Directory('${base.path}/$_rootName');
    if (!await root.exists()) {
      await root.create(recursive: true);
    }
    _root = root;
    return root;
  }

  /// 会话目录名用开始时刻的毫秒数。
  ///
  /// 这样删除时只需要会话记录里的 `startedAt` 就能定位目录，
  /// 不必额外存一个"片段组 id"。
  static String _sessionKey(DateTime startedAt) =>
      startedAt.millisecondsSinceEpoch.toString();

  @override
  Future<ClipWriter?> begin({
    required DateTime sessionStartedAt,
    required double startSeconds,
    required int sampleRate,
  }) async {
    try {
      final root = await _ensureRoot();
      final dir = Directory('${root.path}/${_sessionKey(sessionStartedAt)}');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final fileName = '${(startSeconds * 1000).round()}.wav';
      // 先写 `.part`：录到一半被系统杀掉时，它会留在盘上。
      // 用后缀而不是直接占着 .wav，是为了让"半成品"一眼可辨——
      // 万一真有残留，也不会被当成一段能播的片段。
      final part = File('${dir.path}/$fileName.part');
      final handle = await part.open(mode: FileMode.write);
      // 占位头：长度先写 0，收尾回填。录的时候还不知道会录多长。
      await handle.writeFrom(wavHeader(sampleRate, 0));

      return _FileClipWriter(
        handle: handle,
        part: part,
        finalPath: '${dir.path}/$fileName',
        relativePath: '${_sessionKey(sessionStartedAt)}/$fileName',
        sampleRate: sampleRate,
      );
    } catch (_) {
      failureCount++;
      return null;
    }
  }

  @override
  Future<String?> save({
    required DateTime sessionStartedAt,
    required double startSeconds,
    required Float32List samples,
    required int sampleRate,
  }) async {
    if (samples.isEmpty) return null;
    try {
      final root = await _ensureRoot();
      final dir = Directory('${root.path}/${_sessionKey(sessionStartedAt)}');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final fileName = '${(startSeconds * 1000).round()}.wav';
      final file = File('${dir.path}/$fileName');
      await file.writeAsBytes(
        encodeWavPcm16(samples, sampleRate: sampleRate),
        flush: true,
      );

      return '${_sessionKey(sessionStartedAt)}/$fileName';
    } catch (_) {
      // 磁盘满、权限问题等都不该中断整夜录音
      failureCount++;
      return null;
    }
  }

  @override
  Future<bool> adopt({
    required String relativePath,
    required String localPath,
  }) async {
    try {
      final root = await _ensureRoot();
      final dest = File('${root.path}/$relativePath');
      await dest.parent.create(recursive: true);
      await File(localPath).copy(dest.path);
      return true;
    } catch (_) {
      failureCount++;
      return false;
    }
  }

  @override
  Future<String?> resolve(String relativePath) async {
    final root = await _ensureRoot();
    final file = File('${root.path}/$relativePath');
    return await file.exists() ? file.path : null;
  }

  @override
  Future<void> deleteSession(DateTime sessionStartedAt) async {
    final root = await _ensureRoot();
    final dir = Directory('${root.path}/${_sessionKey(sessionStartedAt)}');
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<void> deleteAll() async {
    final root = await _ensureRoot();
    if (await root.exists()) {
      await root.delete(recursive: true);
    }
    _root = null;
  }

  /// 全部片段占用的字节数。界面上用来告诉用户会多占多少空间。
  Future<int> totalBytes() async {
    final root = await _ensureRoot();
    if (!await root.exists()) return 0;
    var total = 0;
    await for (final entity in root.list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }
}

/// [FileAudioClipStore.begin] 返回的写入器：边追加 PCM、收尾回填 WAV 头。
class _FileClipWriter implements ClipWriter {
  _FileClipWriter({
    required this._handle,
    required this._part,
    required this._finalPath,
    required this._relativePath,
    required this._sampleRate,
  });

  final RandomAccessFile _handle;
  final File _part;
  final String _finalPath;
  final String _relativePath;
  final int _sampleRate;

  int _sampleCount = 0;
  bool _failed = false;
  bool _closed = false;

  @override
  Future<void> append(Float32List samples) async {
    if (_closed || _failed || samples.isEmpty) return;
    try {
      await _handle.writeFrom(encodePcm16(samples));
      _sampleCount += samples.length;
    } catch (_) {
      // 磁盘满之类：记下来，收尾时把半成品删掉——留一个坏文件比不留更糟
      _failed = true;
    }
  }

  @override
  Future<String?> finish() async {
    if (_closed) return null;
    _closed = true;

    if (_failed || _sampleCount == 0) {
      await _discard();
      return null;
    }

    try {
      // 回填两个长度字段（偏移 4 和 40，见 wavHeader）
      await _handle.setPosition(0);
      await _handle.writeFrom(wavHeader(_sampleRate, _sampleCount * 2));
      await _handle.flush();
      await _handle.close();
      await _part.rename(_finalPath);
      return _relativePath;
    } catch (_) {
      await _discard();
      return null;
    }
  }

  @override
  Future<void> release() async {
    if (_closed) return;
    _closed = true;
    await _discard();
  }

  Future<void> _discard() async {
    try {
      await _handle.close();
    } catch (_) {
      // 已经关了就算了
    }
    try {
      if (await _part.exists()) await _part.delete();
    } catch (_) {}
  }
}
