import 'dart:io';

import 'package:file_selector/file_selector.dart';

import '../../domain/repositories/export_target.dart';

/// 普通目录。桌面平台用这个。
///
/// 用正斜杠拼路径：Windows 的 `dart:io` 接受正斜杠，Linux/macOS 本来就是，
/// 所以一套写法通用，不用 `Platform.pathSeparator` 分支。
class DirectoryExportTarget implements ExportTarget {
  DirectoryExportTarget(this.rootPath)
      : _root = Directory(rootPath.replaceAll(r'\', '/'));

  final String rootPath;
  final Directory _root;

  @override
  String get description => rootPath;

  @override
  String get serialized => '$kPathTargetPrefix$rootPath';

  @override
  Future<bool> isUsable() async {
    try {
      if (!await _root.exists()) return false;
      // 光存在不够——可能是只读盘或者没权限。实际写一个探针文件最可靠。
      final probe = File('${_root.path}/.sleep_secret_write_test');
      await probe.writeAsString('ok', flush: true);
      await probe.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> ensureDirectory(String relativeDir) async {
    await Directory('${_root.path}/$relativeDir').create(recursive: true);
  }

  @override
  Future<void> writeText(String relativePath, String content) async {
    final file = File('${_root.path}/$relativePath');
    // 父目录可能还不存在——比如 clips/<会话毫秒>/ 是每次导出新会话时
    // 才第一次出现的。接口的约定是「把文件写到那儿」，
    // 不是「那儿必须已经建好」，所以这里自己建。
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
  }

  @override
  Future<String?> readText(String relativePath) async {
    final f = File('${_root.path}/$relativePath');
    return await f.exists() ? f.readAsString() : null;
  }

  @override
  Future<void> copyIn(String localPath, String relativePath) async {
    final dest = File('${_root.path}/$relativePath');
    await dest.parent.create(recursive: true);
    await File(localPath).copy(dest.path);
  }

  @override
  Future<bool> copyOut(String relativePath, String localPath) async {
    final src = File('${_root.path}/$relativePath');
    if (!await src.exists()) return false;
    final dest = File(localPath);
    await dest.parent.create(recursive: true);
    await src.copy(localPath);
    return true;
  }

  @override
  Future<List<String>> listFiles(String relativeDir) async {
    final dir = Directory('${_root.path}/$relativeDir');
    if (!await dir.exists()) return const [];
    final out = <String>[];
    await for (final e in dir.list(followLinks: false)) {
      if (e is File) {
        out.add(e.uri.pathSegments.lastWhere((s) => s.isNotEmpty));
      }
    }
    out.sort();
    return out;
  }
}

/// [ExportTarget.serialized] 里区分平台的前缀。
///
/// 两种目标的标识形状完全不同（一个是路径，一个是 `content://` URI），
/// 不加前缀的话还原时不知道该走哪条路。
const String kPathTargetPrefix = 'path:';
const String kSafTargetPrefix = 'saf:';

/// 桌面上用系统文件夹选择器。
class DesktopExportTargetPicker implements ExportTargetPicker {
  const DesktopExportTargetPicker();

  @override
  Future<ExportTarget?> pick() async {
    final path = await getDirectoryPath(confirmButtonText: '选这个目录');
    return path == null ? null : DirectoryExportTarget(path);
  }

  @override
  Future<ExportTarget?> restore(String serialized) async {
    if (!serialized.startsWith(kPathTargetPrefix)) return null;
    return DirectoryExportTarget(serialized.substring(kPathTargetPrefix.length));
  }
}
