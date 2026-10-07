/// WebDAV 的连接信息，以及它存哪儿。
///
/// ## 坚果云要的是「应用密码」
///
/// 不是登录密码。在网页版：账户信息 → 安全选项 → 添加应用密码。
/// 这条一定要写在界面上——不知道这件事的人会拿登录密码试，然后卡在 401 上，
/// 而 401 本身不会告诉他这件事。
///
/// ## 密码存在哪：App 私有的 SQLite
///
/// **先说清楚这不是最安全的做法**：Android 上还有 Keystore 那条路
/// （`flutter_secure_storage`），密钥由系统硬件保护，比放在应用私有目录里强。
///
/// 没走那条路是因为**它会弄坏 Windows 构建**：那个插件的 Windows 端要 ATL
/// （`atlstr.h`），而这套环境和 CI 都没有，于是 `flutter build windows` 直接失败。
/// 而这个项目是**要出 Windows 包的**（CI 里那个 job 就是干这个的），
/// 为一个可选功能把整条 Windows 路砍掉不划算。
///
/// 现在的取舍：密码落在 `settings` 表里，也就是 App 私有目录。
/// **非 root 的机器上别的应用读不到它**（Android 的应用沙箱管这个），
/// 但拿到库文件的人能读出来——所以填进这里的一定得是**可以随时吊销**的
/// 应用密码，不能是网盘登录密码。
///
/// 好消息是换回去很便宜：这一整层只有一个接口（[WebDavSettingsStore]）
/// 和一个实现，换实现不影响任何调用方。
library;

import 'dart:convert';

import 'session_database.dart';

class WebDavSettings {
  const WebDavSettings({
    required this.baseUrl,
    required this.username,
    required this.password,
  });

  final String baseUrl;
  final String username;
  final String password;

  /// 坚果云的 WebDAV 地址。放在这儿是为了界面上那个「填入坚果云地址」的提示。
  static const String nutstoreUrl = 'https://dav.jianguoyun.com/dav/';

  /// 主机名，用来在界面上显示「传到哪里」。
  ///
  /// ⚠️ 用户填地址时**常常不写协议头**（就写 `dav.jianguoyun.com/dav/`），
  /// 而 `Uri.parse` 对没有协议的串解析出来的 `host` 是**空的**——
  /// 于是描述会变成「/sleep-secret」，看不出传到哪儿去了。先补一个再解析。
  String get host {
    final trimmed = baseUrl.trim();
    final parsed = Uri.tryParse(
        trimmed.contains('://') ? trimmed : 'https://$trimmed');
    final h = parsed?.host ?? '';
    return h.isEmpty ? trimmed : h;
  }
}

/// 读写连接信息。
///
/// 抽成接口有两个用处：测试能塞一份内存实现；将来要换回 Keystore 的话，
/// 只需要换掉 [DatabaseWebDavSettingsStore] 这一个类。
abstract interface class WebDavSettingsStore {
  Future<WebDavSettings?> read();
  Future<void> write(WebDavSettings settings);
  Future<void> clear();
}

class DatabaseWebDavSettingsStore implements WebDavSettingsStore {
  DatabaseWebDavSettingsStore(this._database);

  /// ⚠️ 一个**单独**的键，不混进别的设置。
  static const String _key = 'webdav_settings_v1';

  final SessionDatabase _database;

  @override
  Future<WebDavSettings?> read() async {
    await _database.open();
    final raw = await _database.readStringSetting(_key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final baseUrl = map['baseUrl'] as String?;
      final username = map['username'] as String?;
      final password = map['password'] as String?;
      if (baseUrl == null || username == null || password == null) return null;
      return WebDavSettings(
          baseUrl: baseUrl, username: username, password: password);
    } catch (_) {
      // 存坏了就当没设过，让用户重填。这里不抛——它不该拦住整个导出页。
      return null;
    }
  }

  @override
  Future<void> write(WebDavSettings settings) async {
    await _database.open();
    await _database.writeStringSetting(
      _key,
      jsonEncode({
        'baseUrl': settings.baseUrl,
        'username': settings.username,
        'password': settings.password,
      }),
    );
  }

  @override
  Future<void> clear() async {
    await _database.open();
    await _database.writeStringSetting(_key, null);
  }
}
