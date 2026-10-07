import 'dart:convert';

import 'package:saf_stream/saf_stream.dart';
// saf_stream.dart 只 import 了平台接口、没有 export，
// 所以 SafNewFile 必须单独从这一层导。
import 'package:saf_stream/saf_stream_platform_interface.dart' show SafNewFile;
import 'package:saf_util/saf_util.dart';

import '../../domain/repositories/export_target.dart';
import 'directory_export_target.dart' show kSafTargetPrefix;

/// Android：用户通过 SAF 选的目录。
///
/// 存的是**树 URI**（`content://...`），不是文件路径——Android 上拿不到
/// 用户所选目录的真实路径（`file_picker.getDirectoryPath()` 会给一个路径
/// 但**不授予写权限**，照着写会静默失败）。SAF 的授权可以持久化，
/// 跨重启有效，而且不需要任何危险权限。
class SafExportTarget implements ExportTarget {
  SafExportTarget(this.treeUri, {SafUtil? util, SafStream? stream})
      : _util = util ?? SafUtil(),
        _stream = stream ?? SafStream();

  final String treeUri;
  final SafUtil _util;
  final SafStream _stream;

  @override
  String get description {
    // 树 URI 的末段长这样：`primary%3ADownload%2F睡觉`
    // 解码后是 `primary:Download/睡觉`，把「primary:」去掉就是用户认得的目录名。
    // 直接把整条 URI 摆给用户看没意义。
    final tail = Uri.decodeComponent(treeUri.split('/').last);
    final colon = tail.indexOf(':');
    return colon >= 0 ? tail.substring(colon + 1) : tail;
  }

  @override
  String get serialized => '$kSafTargetPrefix$treeUri';

  @override
  Future<bool> isUsable() async {
    try {
      // 光查权限不够——用户可能把授权留着但把目录删了。
      // 所以再确认一次根目录还在。
      if (!await _util.hasPersistedPermission(treeUri,
          checkRead: true, checkWrite: true)) {
        return false;
      }
      return await _util.exists(treeUri, true);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> ensureDirectory(String relativeDir) async {
    final parts = _splitDir(relativeDir);
    if (parts.isEmpty) return;
    await _util.mkdirp(treeUri, parts);
  }

  @override
  Future<void> writeText(String relativePath, String content) async {
    await _write(relativePath, (dirUri, name) async {
      return _stream.writeFileBytes(
        dirUri,
        name,
        'application/json',
        utf8.encode(content),
        overwrite: true,
      );
    });
  }

  @override
  Future<String?> readText(String relativePath) async {
    final uri = await _fileUri(relativePath);
    if (uri == null) return null;
    return utf8.decode(await _stream.readFileBytes(uri));
  }

  @override
  Future<void> copyIn(String localPath, String relativePath) async {
    await _write(relativePath, (dirUri, name) async {
      return _stream.pasteLocalFile(
        localPath,
        dirUri,
        name,
        'audio/wav',
        overwrite: true,
      );
    });
  }

  @override
  Future<bool> copyOut(String relativePath, String localPath) async {
    final uri = await _fileUri(relativePath);
    if (uri == null) return false;
    await _stream.copyToLocalFile(uri, localPath);
    return true;
  }

  @override
  Future<List<String>> listFiles(String relativeDir) async {
    final dirUri = await _existingDirUri(relativeDir);
    if (dirUri == null) return const [];
    final entries = await _util.list(dirUri);
    final out = [for (final e in entries) if (!e.isDir) e.name]..sort();
    return out;
  }

  // ------------------------------------------------------------------ 内部

  /// 路径拆成「目录层级」和「文件名」。目录层级可能为空（根目录下）。
  static ({List<String> dir, String name}) _split(String relativePath) {
    final parts = _splitDir(relativePath);
    if (parts.isEmpty) {
      throw ArgumentError('relativePath 不能为空：$relativePath');
    }
    return (dir: parts.sublist(0, parts.length - 1), name: parts.last);
  }

  static List<String> _splitDir(String relativeDir) =>
      relativeDir.split('/').where((s) => s.isNotEmpty && s != '.').toList();

  /// 建好目录、写文件，**并核对 SAF 有没有偷偷改名**。
  ///
  /// ⚠️ SAF 在遇到重名文件时会自己生成一个新名字（`a.json` → `a (1).json`），
  /// **而且不报错**。`overwrite: true` 能避免它，但万一哪天参数被改掉，
  /// 结果就是每次重导都多出一份文件、越积越多，而没人会发现。
  /// 这里额外核一次名字，把那种静默失败变成显式错误。
  Future<void> _write(
    String relativePath,
    Future<SafNewFile> Function(String dirUri, String name) op,
  ) async {
    final parts = _split(relativePath);
    final dir = await _util.mkdirp(treeUri, parts.dir);
    final created = await op(dir.uri, parts.name);

    final actual = created.fileName;
    if (actual != null && actual != parts.name) {
      throw StateError(
        'SAF 把文件名改成了「$actual」（期望「${parts.name}」）——'
        '多半是重名且 overwrite 没生效，会越导越多',
      );
    }
  }

  Future<String?> _existingDirUri(String relativeDir) async {
    final parts = _splitDir(relativeDir);
    if (parts.isEmpty) return treeUri;
    final dir = await _util.child(treeUri, parts);
    return dir?.uri;
  }

  Future<String?> _fileUri(String relativePath) async {
    final parts = _split(relativePath);
    final dirUri = await _existingDirUri(parts.dir.join('/'));
    if (dirUri == null) return null;
    final file = await _util.child(dirUri, [parts.name]);
    return file?.uri;
  }
}

/// Android 上用 SAF 选目录，并要求**可持久化**的读写授权。
class SafExportTargetPicker implements ExportTargetPicker {
  SafExportTargetPicker({SafUtil? util}) : _util = util ?? SafUtil();

  final SafUtil _util;

  @override
  Future<ExportTarget?> pick() async {
    final dir = await _util.pickDirectory(
      writePermission: true,
      // 不加这个的话授权只在本次会话有效，重启后就用不了了
      persistablePermission: true,
    );
    return dir == null ? null : SafExportTarget(dir.uri);
  }

  @override
  Future<ExportTarget?> restore(String serialized) async {
    if (!serialized.startsWith(kSafTargetPrefix)) return null;
    final target =
        SafExportTarget(serialized.substring(kSafTargetPrefix.length));
    // 授权可能被用户在系统设置里撤销，或者目录被删了
    return await target.isUsable() ? target : null;
  }
}
