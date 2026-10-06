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
