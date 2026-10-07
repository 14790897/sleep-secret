import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sleep_secret/data/services/archive_service.dart';
import 'package:sleep_secret/data/services/directory_export_target.dart';
import 'package:sleep_secret/data/services/file_audio_clip_store.dart';
import 'package:sleep_secret/data/services/session_database.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';

import '../helpers/fake_export_target.dart';

const _sessionStart = 1791278973396; // 2026-10-07 00:23 的毫秒数

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory temp;
  late FileAudioClipStore clips;
  late SessionDatabase db;
  late ArchiveService archive;
  late InMemoryExportTarget target;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('archive_test');
    clips = FileAudioClipStore(baseDirectory: temp);
    db = SessionDatabase(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    archive = ArchiveService(database: db, clipStore: clips);
    target = InMemoryExportTarget();
  });

  tearDown(() async {
    await db.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  /// 清空全部会话。SessionDatabase 只有按 id 删，没有删全部。
  Future<void> wipeSessions() async {
    for (final s in await db.listSessions()) {
      await db.deleteSession(s.id!);
    }
  }

  /// 造一晚：一个带片段的鼾声事件 + 一个不带片段的噪音事件。
  Future<RecordingSession> seedNight() async {
    final startedAt = DateTime.fromMillisecondsSinceEpoch(_sessionStart);
    final clipPath = await clips.save(
      sessionStartedAt: startedAt,
      startSeconds: 273,
      samples: Float32List.fromList(List.filled(16000, 0.3)),
      sampleRate: 16000,
    );

    return RecordingSession(
      id: null,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(hours: 7, minutes: 37)),
      events: [
        SoundEvent(
          label: SleepCategory.snore,
          startSeconds: 273,
          durationSeconds: 12,
          confidence: 0.46,
          snoreProbability: 0.46,
          windowCount: 4,
          clipPath: clipPath,
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
  }

  group('导出', () {
    test('写出一晚的 JSON 和一个片段文件', () async {
      await db.open();
      await db.insertSession(await seedNight());

      final r = await archive.export(target);

      expect(r.sessions, 1);
      expect(r.clips, 1);
      expect(r.clipsMissing, 0);
      expect(r.isClean, isTrue, reason: '不该有问题：${r.problems}');

      // 文件名就是会话开始毫秒数——它同时是去重键和片段目录名
      expect(target.jsonAt('sessions/$_sessionStart.json'), isNotNull);

      // 片段按 clipPath 原样放过去，路径不重写
      final clipKeys =
          target.files.keys.where((k) => k.startsWith('clips/')).toList();
      expect(clipKeys.single, 'clips/$_sessionStart/273000.wav');
    });

    test('没有片段的事件不会凭空造文件', () async {
      await db.open();
      await db.insertSession(await seedNight());

      await archive.export(target);

      final clipKeys =
          target.files.keys.where((k) => k.startsWith('clips/')).toList();
      expect(clipKeys.length, 1, reason: '只有鼾声那条有片段');
    });

    test('只导指定的那一晚，不把别的重写一遍', () async {
      // 自动导出走这条。用 exportAll 的话，每录一晚都会把之前每一晚的
      // 片段重新搬一遍——时间越久越慢，网盘也得重传没变过的文件。
      await db.open();
      final night = await seedNight();
      await db.insertSession(night);
      await db.insertSession(RecordingSession(
        id: null,
        startedAt: DateTime.fromMillisecondsSinceEpoch(_sessionStart + 86400000),
        endedAt: DateTime.fromMillisecondsSinceEpoch(_sessionStart + 86400000),
        events: const [],
        stats: const SessionStats.empty(),
      ));

      final r = await archive.export(target, sessions: [night]);

      expect(r.sessions, 1);
      expect(await target.listFiles('sessions'), ['$_sessionStart.json']);
    });

    test('写失败只记问题，不中途崩掉', () async {
      await db.open();
      await db.insertSession(await seedNight());
      target.failWrites = true;

      final r = await archive.export(target);

      expect(r.sessions, 0);
      expect(r.isClean, isFalse);
      expect(r.problems, isNotEmpty);
    });
  });

  group('导入', () {
    /// 导出到 target，再把本地数据清空，模拟"换了一台设备"。
    Future<void> exportThenWipe() async {
      await db.open();
      await db.insertSession(await seedNight());
      await archive.export(target);
      await clips.deleteAll();
      await wipeSessions();
      await db.close();
      db = SessionDatabase(
        factory: databaseFactoryFfi,
        databasePath: inMemoryDatabasePath,
      );
      archive = ArchiveService(database: db, clipStore: clips);
    }

    test('会话和片段都回来了', () async {
      await exportThenWipe();

      final r = await archive.import(target);

      expect(r.sessions, 1);
      expect(r.clips, 1);
      expect(r.problems, isEmpty, reason: '${r.problems}');

      final sessions = await db.listSessions();
      expect(sessions.length, 1);
      expect(sessions.single.startedAt.millisecondsSinceEpoch, _sessionStart);

      final full = await db.loadSession(sessions.single.id!);
      expect(full!.events.length, 2);
      expect(full.events.first.label, SleepCategory.snore);
    });

    test('片段的相对路径原样保留，并且真的能取到文件', () async {
      await exportThenWipe();

      await archive.import(target);

      final sessions = await db.listSessions();
      final full = await db.loadSession(sessions.single.id!);
      final clipPath = full!.events
          .firstWhere((e) => e.clipPath != null)
          .clipPath!;

      expect(clipPath, '$_sessionStart/273000.wav',
          reason: '路径必须原样保留——数据库里存的就是它');

      // 关键：不只是路径对，文件也要真的在
      final abs = await clips.resolve(clipPath);
      expect(abs, isNotNull, reason: '导入的片段应当真的落到了本地');
      expect(await File(abs!).length(), greaterThan(44));
    });

    test('重复导入不会产生第二份', () async {
      await exportThenWipe();
      await archive.import(target);

      final second = await archive.import(target);

      expect(second.sessions, 0);
      expect(second.skipped, 1, reason: '同一个开始时刻，应当被跳过');
      expect((await db.listSessions()).length, 1,
          reason: 'started_at 没有唯一约束，不去重就会越导越多');
    });

    test('坏文件跳过，不挡住其余', () async {
      await db.open();
      await db.insertSession(await seedNight());
      await archive.export(target);
      // 混进一个不是我们的文件
      target.put('sessions/9999999999999.json', '{"app":"别的应用"}');

      await clips.deleteAll();
      await wipeSessions();

      final r = await archive.import(target);

      expect(r.sessions, 1, reason: '好的那个照样导进来');
      expect(r.skipped, 1);
      expect(r.problems.single, contains('读不了'));
    });

    test('目标目录是空的 —— 不报错，什么都不导', () async {
      final r = await archive.import(target);
      expect(r.sessions, 0);
      expect(r.problems, isEmpty);
    });
  });

  group('用真实的目录目标跑一遍', () {
    // ⚠️ 上面那些用的都是内存目标——**不要目录、不建目录**，
    // 所以"父目录不存在"这类问题它永远碰不到。
    // 而真实的 DirectoryExportTarget 一开始就撞过：clips/<会话毫秒>/
    // 是每次导出新会话时第一次出现的目录，不建就 PathNotFoundException。
    // 这条用真目录跑，把那一类问题盖住。
    test('导出到真的目录，再导回来', () async {
      final exportRoot = Directory('${temp.path}/导出到这里');
      final real = DirectoryExportTarget(exportRoot.path);

      await db.open();
      await db.insertSession(await seedNight());

      final out = await archive.export(real);
      expect(out.sessions, 1);
      expect(out.clips, 1);
      expect(out.problems, isEmpty, reason: '${out.problems}');

      // 文件真的在磁盘上，而且结构对
      expect(await File('${exportRoot.path}/sessions/$_sessionStart.json').exists(),
          isTrue);
      expect(
          await File('${exportRoot.path}/clips/$_sessionStart/273000.wav').exists(),
          isTrue);

      // 清空本地，再从真目录导回来
      await clips.deleteAll();
      await wipeSessions();

      final back = await archive.import(real);
      expect(back.sessions, 1);
      expect(back.clips, 1);

      final full =
          await db.loadSession((await db.listSessions()).single.id!);
      final clipPath =
          full!.events.firstWhere((e) => e.clipPath != null).clipPath!;
      expect(await clips.resolve(clipPath), isNotNull,
          reason: '导回来的片段要真的能取到');
    });

    test('导出到只读的地方 —— 记问题，不崩', () async {
      // 用一个不存在且建不出来的路径模拟"写入失败"
      final bad = DirectoryExportTarget(
          '${temp.path}/不存在的父目录\u0000/子目录');
      await db.open();
      await db.insertSession(await seedNight());

      final out = await archive.export(bad);
      expect(out.sessions, 0);
      expect(out.isClean, isFalse);
    });
  });

  group('导出再导入，数据要对得上', () {
    test('事件的每一个字段都原样回来', () async {
      await db.open();
      await db.insertSession(await seedNight());

      await archive.export(target);

      final sessions = await db.listSessions();
      final before = await db.loadSession(sessions.single.id!);

      await clips.deleteAll();
      await wipeSessions();
      await archive.import(target);

      final after =
          await db.loadSession((await db.listSessions()).single.id!);

      expect(after!.events.length, before!.events.length);
      for (var i = 0; i < before.events.length; i++) {
        expect(after.events[i].label, before.events[i].label);
        expect(after.events[i].startSeconds, before.events[i].startSeconds);
        expect(after.events[i].durationSeconds,
            before.events[i].durationSeconds);
        expect(after.events[i].confidence, before.events[i].confidence);
        expect(after.events[i].snoreProbability,
            before.events[i].snoreProbability);
      }
      expect(after.stats.analyzedSeconds, before.stats.analyzedSeconds);
      expect(after.stats.snoreSeconds, before.stats.snoreSeconds);
    });
  });
}
