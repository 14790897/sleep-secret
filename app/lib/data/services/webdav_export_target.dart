/// 把导出目标放到 WebDAV 服务器上（坚果云是其中一个）。
///
/// ## 它存在的意义
///
/// 导出/导入的全部逻辑——写哪些文件、片段放哪儿、按开始时间去重、
/// 结果怎么汇报——**一行都不用改**。这是 `ExportTarget` 那层抽象当初
/// 留下的价值：Android 的 SAF、桌面的普通目录、现在的 WebDAV，
/// 上层看到的都只是「一个可以往里写文件、也可以从里面读文件的地方」。
///
/// ## 为什么默认建一层 `sleep-secret/`
///
/// 坚果云的根目录是用户整个网盘。往根目录里扔一堆按毫秒命名的 JSON 和
/// `clips/`，等于把别人的网盘搅乱。所以默认收进一个自己的文件夹里，
/// 卸载 App 之后也一眼能认出来哪些是它留下的。
library;

import 'dart:convert';
import 'dart:io';

import '../../domain/repositories/export_target.dart';
import 'webdav_client.dart';
import 'webdav_settings.dart';

class WebDavExportTarget implements ExportTarget {
  WebDavExportTarget({
    required this.client,
    required WebDavSettings settings,
    this.rootDir = 'sleep-secret',
  })  :
        // ignore: prefer_initializing_formals
        _settings = settings;

  final WebDavClient client;
  final WebDavSettings _settings;

  /// 服务器上那个文件夹的名字。
  final String rootDir;

  /// 存进设置表里的标识。
  ///
  /// **只有类型，没有凭据**——凭据在 Keystore 里（见 `webdav_settings.dart`）。
  /// 所以改地址、改账号都不用动这个串，`restore` 时重新读一次就行。
  static const String serializedTag = 'webdav';

  @override
  String get description => '坚果云 / WebDAV · ${_settings.host}/$rootDir';

  @override
  String get serialized => serializedTag;

  @override
  Future<bool> isUsable() async {
    // **刻意不发网络请求。** 这个方法在导出页加载时就会调一次，
    // 让它去 ping 服务器的话，进这一页会先卡住几秒（或者三十秒超时）。
    // 网络通不通由真正的同步去发现——那儿的错误信息也具体得多，
    // 而且页面上还有一个「测试连接」按钮专门干这件事。
    return true;
  }

  String _full(String relativePath) =>
      relativePath.isEmpty ? rootDir : '$rootDir/$relativePath';

  @override
  Future<void> ensureDirectory(String relativeDir) =>
      client.ensureDirectory(_full(relativeDir));

  @override
  Future<void> writeText(String relativePath, String content) =>
      client.putBytes(_full(relativePath), utf8.encode(content));

  @override
  Future<String?> readText(String relativePath) async {
    final bytes = await client.getBytes(_full(relativePath));
    if (bytes == null) return null;
    // 允许畸形字节：宁可让上层拿到一段读不动的文本（然后按坏文件跳过），
    // 也不要在这儿抛出去、把整个导入打断。
    return utf8.decode(bytes, allowMalformed: true);
  }

  @override
  Future<void> copyIn(String localPath, String relativePath) async {
    final bytes = await File(localPath).readAsBytes();
    await client.putBytes(_full(relativePath), bytes);
  }

  @override
  Future<bool> copyOut(String relativePath, String localPath) async {
    final bytes = await client.getBytes(_full(relativePath));
    if (bytes == null) return false;
    final file = File(localPath);
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return true;
  }

  @override
  Future<List<String>> listFiles(String relativeDir) async {
    final names = await client.listFileNames(_full(relativeDir));
    return names.toList()..sort();
  }
}
