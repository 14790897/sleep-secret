import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/services/session_database.dart';
import 'package:sleep_secret/data/services/webdav_settings.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 给测试用的内存实现。真实现落在 SQLite 里（见 `webdav_settings.dart`）。
class InMemoryWebDavSettings implements WebDavSettingsStore {
  WebDavSettings? stored;
  int writes = 0;

  @override
  Future<WebDavSettings?> read() async => stored;

  @override
  Future<void> write(WebDavSettings settings) async {
    stored = settings;
    writes++;
  }

  @override
  Future<void> clear() async => stored = null;
}

void main() {
  setUpAll(sqfliteFfiInit);

  group('WebDavSettings.host', () {
    test('写了协议头时取主机名', () {
      const s = WebDavSettings(
          baseUrl: 'https://dav.jianguoyun.com/dav/', username: 'u', password: 'p');
      expect(s.host, 'dav.jianguoyun.com');
    });

    test('**没写协议头**也取得到——用户多半就是那么填的', () {
      // 第一版直接用 Uri.parse，没有协议头时 host 是空的，
      // 描述变成「坚果云 / WebDAV · /sleep-secret」，看不出传到哪儿。
      const s = WebDavSettings(
          baseUrl: 'dav.jianguoyun.com/dav', username: 'u', password: 'p');
      expect(s.host, 'dav.jianguoyun.com');
    });

    test('实在解析不出来时，原样显示总比空着强', () {
      const s = WebDavSettings(baseUrl: '   ', username: 'u', password: 'p');
      expect(s.host, isEmpty);
    });
  });

  group('DatabaseWebDavSettingsStore', () {
    late SessionDatabase db;
    late DatabaseWebDavSettingsStore store;

    setUp(() {
      db = SessionDatabase(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      store = DatabaseWebDavSettingsStore(db);
    });

    tearDown(() => db.close());

    test('没设过时返回 null', () async {
      expect(await store.read(), isNull);
    });

    test('写进去能原样读回来', () async {
      await store.write(const WebDavSettings(
        baseUrl: 'https://dav.jianguoyun.com/dav/',
        username: 'me@example.com',
        password: 'app-pass-1234',
      ));

      final back = await store.read();
      expect(back, isNotNull);
      expect(back!.baseUrl, 'https://dav.jianguoyun.com/dav/');
      expect(back.username, 'me@example.com');
      expect(back.password, 'app-pass-1234');
    });

    test('清掉之后回到 null', () async {
      await store.write(const WebDavSettings(
          baseUrl: 'https://x/dav/', username: 'u', password: 'p'));
      await store.clear();
      expect(await store.read(), isNull);
    });

    test('存坏了当没设过，不抛——它不该拦住整个导出页', () async {
      await db.open();
      await db.writeStringSetting('webdav_settings_v1', '{不是 JSON');
      expect(await store.read(), isNull);
    });

    test('字段缺一个也当没设过', () async {
      await db.open();
      await db.writeStringSetting('webdav_settings_v1', '{"baseUrl":"https://x/"}');
      expect(await store.read(), isNull);
    });

    test('存在**单独的键**上，不混进别的设置', () async {
      // 这条是防「顺手把它塞进某个已有键」的改动：一旦混进去，
      // 改别的设置就可能把连接信息冲掉。
      await store.write(const WebDavSettings(
          baseUrl: 'https://x/dav/', username: 'u', password: 'p'));
      await db.writeStringSetting('export_target', 'some-path');

      expect((await store.read())!.baseUrl, 'https://x/dav/');
    });
  });
}
