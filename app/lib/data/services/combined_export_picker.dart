/// 一个能还原**两种**导出目标的 picker：普通文件夹，和 WebDAV。
///
/// ## 为什么是组合，而不是改仓储
///
/// `ArchiveRepository` 只认 `ExportTargetPicker.restore(serialized)` 这一个入口，
/// 而目标串里本来就带类型（桌面存路径、Android 存树 URI）。WebDAV 只是
/// **第三种类型**——所以在这里分流就够了，仓储和导出逻辑一个字都不用动。
///
/// 这也是那层抽象当初划对了的证据：加一种全新的存储位置，
/// 改的是「谁提供目标」，不是「怎么导出」。
library;

import '../../domain/repositories/export_target.dart';
import 'webdav_client.dart';
import 'webdav_export_target.dart';
import 'webdav_settings.dart';

class CombinedExportTargetPicker implements ExportTargetPicker {
  CombinedExportTargetPicker({
    required this.folderPicker,
    required this.settingsStore,
  });

  final ExportTargetPicker folderPicker;
  final WebDavSettingsStore settingsStore;

  /// 缓存住客户端，别每次 `restore` 都新建一个。
  ///
  /// `restore` 在导出页每次加载时都会调；每次都 new 一个 `HttpClient`
  /// 又不关，连接就会一点点攒着。
  WebDavClient? _client;
  String? _clientKey;

  @override
  Future<ExportTarget?> pick() => folderPicker.pick();

  @override
  Future<ExportTarget?> restore(String serialized) async {
    if (serialized != WebDavExportTarget.serializedTag) {
      return folderPicker.restore(serialized);
    }

    final settings = await settingsStore.read();
    // 配置在，但凭据没了（重装过、或者被系统清了 Keystore）——
    // 返回 null 让界面显示「失效」，而不是拿空账号去撞 401。
    if (settings == null) return null;

    final key = '${settings.baseUrl}|${settings.username}|${settings.password}';
    if (_client == null || _clientKey != key) {
      _client?.close();
      _client = WebDavClient(
        baseUrl: settings.baseUrl,
        username: settings.username,
        password: settings.password,
      );
      _clientKey = key;
    }

    return WebDavExportTarget(client: _client!, settings: settings);
  }
}
