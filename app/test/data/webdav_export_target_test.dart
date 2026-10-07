import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/services/archive_service.dart';
import 'package:sleep_secret/data/services/file_audio_clip_store.dart';
import 'package:sleep_secret/data/services/session_database.dart';
import 'package:sleep_secret/data/services/webdav_client.dart';
import 'package:sleep_secret/data/services/webdav_export_target.dart';
import 'package:sleep_secret/data/services/webdav_settings.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_webdav_server.dart';

/// **最重要的一条**：同一套导出逻辑，跑在 WebDAV 上。
///
/// 加这个功能的时候打的包票是「WebDAV 只是第三种 `ExportTarget`，
/// 导出/导入的逻辑一个字都不用改」。这句话得**证明**，不能只是声称——
/// 所以这里不测 `WebDavExportTarget` 的各个方法，而是把整个
/// [ArchiveService] 架在它上面跑一遍：真服务器（进程里的）、真数据库、
/// 真 WAV 文件，只有服务器是假的。
void main() {
  setUpAll(sqfliteFfiInit);

  late FakeWebDavServer server;
  late WebDavClient client;
  late WebDavExportTarget target;
  late Directory temp;
  late FileAudioClipStore clips;
  late SessionDatabase db;

  setUp(() async {
    server = await FakeWebDavServer.start(expectedAuth: 'me@example.com:app-pass');
    client = WebDavClient(
      baseUrl: server.baseUrl,
      username: 'me@example.com',
      password: 'app-pass',
    );
    target = WebDavExportTarget(
      client: client,
      settings: const WebDavSettings(
        baseUrl: 'dav.jianguoyun.com/dav/',
        username: 'me@example.com',
        password: 'app-pass',
      ),
    );

    temp = await Directory.systemTemp.createTemp('webdav_archive');
    clips = FileAudioClipStore(baseDirectory: temp);
    db = SessionDatabase(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
  });

  tearDown(() async {
    client.close();
    await server.stop();
    await db.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// 造一晚：一条带片段的鼾声 + 一条环境声。
  Future<RecordingSession> seedNight(ArchiveService archive) async {
    final clip = await clips.save(
      sessionStartedAt: DateTime(2026, 10, 7, 0, 23),
      startSeconds: 273,
      samples: Float32List(16000),
      sampleRate: 16000,
    );
    final session = RecordingSession(
      id: null,
      startedAt: DateTime(2026, 10, 7, 0, 23),
      endedAt: DateTime(2026, 10, 7, 8, 0),
      events: [
        SoundEvent(
          label: SleepCategory.snore,
          startSeconds: 273,
          durationSeconds: 12,
          confidence: 0.46,
          snoreProbability: 0.46,
          windowCount: 4,
          clipPath: clip,
        ),
        const SoundEvent(
          label: SleepCategory.ambient,
          startSeconds: 300,
          durationSeconds: 21,
          confidence: 0.31,
          snoreProbability: 0.01,
          windowCount: 7,
        ),
      ],
      stats: const SessionStats(
        analyzedSeconds: 27450,
        windowsTotal: 9151,
        windowsInferred: 9151,
        windowsVadSkipped: 0,
        windowsLowConfidence: 492,
        eventCount: 2,
        snoreEventCount: 1,
        snoreSeconds: 12,
        categoryDistribution: {},
      ),
    );
    await db.insertSession(session);
    return session;
  }

  group('整套导出逻辑跑在 WebDAV 上', () {
    test('导出去的能在**另一台设备**上导回来，事件和片段都在', () async {
      final archive = ArchiveService(database: db, clipStore: clips);
      final night = await seedNight(archive);

      final exported = await archive.export(target);
      expect(exported.sessions, 1);
      expect(exported.clips, 1, reason: '那段鼾声的片段也该传上去');

      // 换一台"设备"：新的库、新的片段目录。
      //
      // ⚠️ **必须是不同的库文件**。第一版这里也用 `inMemoryDatabasePath`，
      // 而 sqflite 按路径缓存连接——两个 SessionDatabase 拿到的是**同一个库**，
      // 于是导入时按开始时间去重，把这一晚当成"已经有了"跳过了。
      // 表现是「导入 0 条、跳过 1 条、没有任何错误」，很容易当成 WebDAV 的 bug。
      final otherTemp = await Directory.systemTemp.createTemp('webdav_other');
      addTearDown(() => otherTemp.delete(recursive: true));
      final otherDb = SessionDatabase(
        factory: databaseFactoryFfi,
        databasePath: '${otherTemp.path}/other.db',
      );
      addTearDown(otherDb.close);
      final otherClips = FileAudioClipStore(baseDirectory: otherTemp);
      final otherArchive = ArchiveService(database: otherDb, clipStore: otherClips);

      final imported = await otherArchive.import(target);
      expect(imported.sessions, 1);

      final back = (await otherDb.listSessions()).single;
      expect(back.startedAt, night.startedAt);

      // ⚠️ 事件要用 loadSession 拿。listSessions 是给列表页用的，
      // **不带事件**——在它上面断言事件数会得到 0，而那不是 bug。
      final loaded = await otherDb.loadSession(back.id!);
      expect(loaded!.events.length, 2);

      final snore = loaded.events.firstWhere((e) => e.isSnore);
      expect(snore.clipPath, isNotNull);
      // 片段真的能还原成文件——不只是路径字符串传过来了
      final resolved = await otherClips.resolve(snore.clipPath!);
      expect(resolved, isNotNull);
      expect(await File(resolved!).length(), greaterThan(44));
    });

    test('再导一次不会塞两份——按开始时间去重', () async {
      final archive = ArchiveService(database: db, clipStore: clips);
      await seedNight(archive);

      await archive.export(target);
      await archive.export(target);
      expect(
        server.files.keys.where((k) => k.endsWith('.json')).length,
        1,
        reason: '同一晚在服务器上只该有一个 json',
      );

      final again = await archive.import(target);
      expect(again.sessions, 0); // 本地已经有了
      expect(again.skipped, 1);
    });

    test('东西都收在 sleep-secret/ 里，不搅乱用户的网盘根目录', () async {
      final archive = ArchiveService(database: db, clipStore: clips);
      await seedNight(archive);
      await archive.export(target);

      expect(server.files.keys, isNotEmpty);
      for (final path in server.files.keys) {
        expect(path, startsWith('sleep-secret/'), reason: path);
      }
    });

    test('服务器上什么都没有时，导入不会炸——第一次用就是这样', () async {
      final archive = ArchiveService(database: db, clipStore: clips);
      await db.open();

      final outcome = await archive.import(target);
      expect(outcome.sessions, 0);
    });
  });

  group('WebDavExportTarget 自己', () {
    test('描述里带着主机名和目录，用户能认出来', () {
      expect(target.description, contains('dav.jianguoyun.com'));
      expect(target.description, contains('sleep-secret'));
    });

    test('serialized 只有类型、没有凭据', () {
      // 这个串会进 SQLite 的设置表——密码不能跟着进去
      expect(target.serialized, 'webdav');
      expect(target.serialized, isNot(contains('app-pass')));
      expect(target.serialized, isNot(contains('example.com')));
    });

    test('isUsable 不发网络请求——它会在导出页加载时被调到', () async {
      final before = server.requests.length;
      await target.isUsable();
      expect(server.requests.length, before,
          reason: '可用性检查应当是本地的，网络好不好由同步去发现');
    });

    test('读一个不存在的文件返回 null，不是抛异常', () async {
      expect(await target.readText('没有这个.json'), isNull);
    });

    test('listFiles 返回排好序的文件名', () async {
      await target.writeText('b.json', '{}');
      await target.writeText('a.json', '{}');
      expect(await target.listFiles(''), ['a.json', 'b.json']);
    });
  });
}
