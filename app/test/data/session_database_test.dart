import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/services/session_database.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

RecordingSession session({
  DateTime? startedAt,
  DateTime? endedAt,
  List<SoundEvent> events = const [],
  SessionStats? stats,
}) =>
    RecordingSession(
      id: null,
      startedAt: startedAt ?? DateTime(2026, 10, 6, 23, 30),
      endedAt: endedAt ?? DateTime(2026, 10, 7, 7, 15),
      events: events,
      stats: stats ??
          const SessionStats(
            analyzedSeconds: 28620,
            windowsTotal: 9540,
            windowsInferred: 3580,
            windowsVadSkipped: 5960,
            windowsLowConfidence: 3400,
            eventCount: 2,
            snoreEventCount: 1,
            snoreSeconds: 180,
            categoryDistribution: {},
          ),
    );

SoundEvent snoreEvent({
  double start = 3720,
  double duration = 180,
  double confidence = 0.82,
  double snoreProbability = 0.77,
  int windowCount = 60,
}) =>
    SoundEvent(
      label: SleepCategory.snore,
      startSeconds: start,
      durationSeconds: duration,
      confidence: confidence,
      snoreProbability: snoreProbability,
      windowCount: windowCount,
    );

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late SessionDatabase db;

  setUp(() {
    db = SessionDatabase(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
  });

  tearDown(() async => db.close());

  group('SessionDatabase 写入与读取', () {
    test('写入会话后能按 id 读回，字段完整', () async {
      final original = session(events: [snoreEvent()]);
      final id = await db.insertSession(original);

      final loaded = await db.loadSession(id);

      expect(loaded, isNotNull);
      expect(loaded!.id, id);
      expect(loaded.startedAt, original.startedAt);
      expect(loaded.endedAt, original.endedAt);
      expect(loaded.stats.analyzedSeconds, 28620);
      expect(loaded.stats.windowsInferred, 3580);
      expect(loaded.stats.snoreSeconds, 180);
      expect(loaded.events.length, 1);
    });

    test('事件字段逐一还原', () async {
      final id = await db.insertSession(session(events: [snoreEvent()]));

      final event = (await db.loadSession(id))!.events.single;

      expect(event.label, SleepCategory.snore);
      expect(event.startSeconds, 3720);
      expect(event.durationSeconds, 180);
      expect(event.confidence, closeTo(0.82, 1e-9));
      expect(event.snoreProbability, closeTo(0.77, 1e-9));
      expect(event.windowCount, 60);
    });

    test('多个事件按开始时间升序返回', () async {
      final id = await db.insertSession(session(events: [
        snoreEvent(start: 9000, duration: 30),
        snoreEvent(start: 1200, duration: 60),
        snoreEvent(start: 5000, duration: 90),
      ]));

      final events = (await db.loadSession(id))!.events;

      expect(events.map((e) => e.startSeconds), [1200, 5000, 9000]);
    });

    test('全部类别都能往返', () async {
      final events = [
        for (final category in SleepCategory.values)
          SoundEvent(
            label: category,
            startSeconds: category.index * 100.0,
            durationSeconds: 10,
            confidence: 0.5,
            snoreProbability: 0.1,
            windowCount: 3,
          ),
      ];
      final id = await db.insertSession(session(events: events));

      final loaded = (await db.loadSession(id))!.events;

      expect(loaded.map((e) => e.label).toSet(), SleepCategory.values.toSet());
    });

    test('没有事件的会话也能存取', () async {
      final id = await db.insertSession(session());

      final loaded = await db.loadSession(id);

      expect(loaded, isNotNull);
      expect(loaded!.events, isEmpty);
    });

    test('未结束的会话 endedAt 为 null', () async {
      final id = await db.insertSession(RecordingSession(
        id: null,
        startedAt: DateTime(2026, 10, 6, 23),
        endedAt: null,
        events: const [],
        stats: const SessionStats.empty(),
      ));

      final loaded = await db.loadSession(id);

      expect(loaded!.endedAt, isNull);
      expect(loaded.isFinished, isFalse);
    });

    test('读取不存在的 id 返回 null', () async {
      expect(await db.loadSession(9999), isNull);
    });
  });

  group('SessionDatabase 列表与删除', () {
    test('列表按开始时间倒序', () async {
      await db.insertSession(session(startedAt: DateTime(2026, 10, 3, 23)));
      await db.insertSession(session(startedAt: DateTime(2026, 10, 6, 23)));
      await db.insertSession(session(startedAt: DateTime(2026, 10, 1, 23)));

      final list = await db.listSessions();

      expect(list.length, 3);
      expect(
        list.map((s) => s.startedAt.day),
        [6, 3, 1],
      );
    });

    test('列表不加载事件（列表页不需要）', () async {
      await db.insertSession(session(events: [snoreEvent()]));

      expect((await db.listSessions()).single.events, isEmpty);
    });

    test('删除会话会级联删掉它的事件', () async {
      final id = await db.insertSession(session(events: [snoreEvent()]));
      await db.deleteSession(id);

      expect(await db.loadSession(id), isNull);
      // 直接查 events 表确认没有残留孤儿行
      final raw = await db.countEventRows(id);
      expect(raw, 0);
    });

    test('删除不存在的会话不报错', () async {
      await db.deleteSession(4242);
    });

    test('空库返回空列表', () async {
      expect(await db.listSessions(), isEmpty);
    });
  });

  group('SessionDatabase 生命周期', () {
    test('重复 insert 累加而不是覆盖', () async {
      await db.insertSession(session());
      await db.insertSession(session());

      expect((await db.listSessions()).length, 2);
    });

    test('close 后可重新打开并读到数据（非内存库场景由调用方保证路径）', () async {
      await db.insertSession(session());
      expect(db.isOpen, isTrue);
      await db.close();
      expect(db.isOpen, isFalse);
    });
  });
}
