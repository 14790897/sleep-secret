import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sleep_secret/domain/repositories/export_target.dart';

/// 内存版的导出目标，用来测导出/导入逻辑本身。
///
/// 存在的意义就是那层抽象：`SafExportTarget` 在电脑上跑不了（要 Android SAF），
/// 但**除了它之外的全部逻辑**都能靠这个假实现覆盖到——
/// 和录音那边用 `WavReplayAudioCapture` 换掉 `RecordAudioCapture` 是同一个思路。
///
/// 注意：本地文件那一侧是真的（`copyIn` 会真去读 `localPath`），
/// 因为那本来就是真实文件系统；只有"目标"这一侧是内存里的。
class InMemoryExportTarget implements ExportTarget {
  InMemoryExportTarget({this.description = 'memory://export'});

  /// 相对路径 -> 内容。文本存 String，二进制存 Uint8List。
  final Map<String, Object> files = {};

  @override
  final String description;

  @override
  String get serialized => 'memory:$description';

  /// 置为 false 可以模拟「SAF 授权被撤销」。
  bool usable = true;

  /// 置为 true 可以让每次写入都抛异常，验证调用方不会因此崩掉。
  bool failWrites = false;

  @override
  Future<bool> isUsable() async => usable;

  @override
  Future<void> ensureDirectory(String relativeDir) async {
    // 内存版没有目录概念，什么都不用做
  }

  @override
  Future<void> writeText(String relativePath, String content) async {
    if (failWrites) throw const FileSystemException('模拟写入失败');
    files[relativePath] = content;
  }

  @override
  Future<String?> readText(String relativePath) async {
    final v = files[relativePath];
    return v is String ? v : null;
  }

  @override
  Future<void> copyIn(String localPath, String relativePath) async {
    if (failWrites) throw const FileSystemException('模拟写入失败');
    files[relativePath] = await File(localPath).readAsBytes();
  }

  @override
  Future<bool> copyOut(String relativePath, String localPath) async {
    final v = files[relativePath];
    if (v is! Uint8List) return false;
    await File(localPath).writeAsBytes(v, flush: true);
    return true;
  }

  @override
  Future<List<String>> listFiles(String relativeDir) async {
    final prefix = relativeDir.isEmpty ? '' : '$relativeDir/';
    final out = <String>[];
    for (final key in files.keys) {
      if (!key.startsWith(prefix)) continue;
      final rest = key.substring(prefix.length);
      // 只列直接子项，不递归
      if (rest.isEmpty || rest.contains('/')) continue;
      out.add(rest);
    }
    out.sort();
    return out;
  }

  /// 直接塞一个文本文件，省得测试里到处调 writeText。
  void put(String relativePath, String content) => files[relativePath] = content;

  /// 直接塞一个二进制文件。
  void putBytes(String relativePath, List<int> bytes) =>
      files[relativePath] = Uint8List.fromList(bytes);

  /// 某个文件的文本内容，方便断言。
  String? textAt(String relativePath) {
    final v = files[relativePath];
    return v is String ? v : null;
  }

  /// 解码某个 JSON 文件。
  Map<String, dynamic>? jsonAt(String relativePath) {
    final t = textAt(relativePath);
    return t == null ? null : jsonDecode(t) as Map<String, dynamic>;
  }
}
