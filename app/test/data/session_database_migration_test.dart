import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/services/session_database.dart';
import 'package:sleep_secret/domain/analysis/apnea_signals.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// v1 的建表语句，复制自加音频片段之前的版本。
///
/// 刻意**不**从生产代码里引用——迁移测试要构造的是"老用户手里那个库"，
/// 引用当前代码就测不出迁移了。
const String _v1Sessions = '''
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at INTEGER NOT NULL,
  ended_at INTEGER,
  analyzed_seconds REAL NOT NULL DEFAULT 0,
  windows_total INTEGER NOT NULL DEFAULT 0,
  windows_inferred INTEGER NOT NULL DEFAULT 0,
  windows_vad_skipped INTEGER NOT NULL DEFAULT 0,
  windows_low_confidence INTEGER NOT NULL DEFAULT 0,
  event_count INTEGER NOT NULL DEFAULT 0,
  snore_event_count INTEGER NOT NULL DEFAULT 0,
  snore_seconds REAL NOT NULL DEFAULT 0
)''';

const String _v1Events = '''
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL,
  label TEXT NOT NULL,
  start_seconds REAL NOT NULL,
  duration_seconds REAL NOT NULL,
  confidence REAL NOT NULL,
  snore_probability REAL NOT NULL,
  window_count INTEGER NOT NULL,
  FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
)''';

/// v2 的建表语句：v1 加上音频片段那一列。
const String _v2Events = '''
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL,
  label TEXT NOT NULL,
  start_seconds REAL NOT NULL,
  duration_seconds REAL NOT NULL,
  confidence REAL NOT NULL,
  snore_probability REAL NOT NULL,
  window_count INTEGER NOT NULL,
  clip_path TEXT,
  FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
)''';

/// v3 的建表语句：v2 加上电平列、加上设置表。
///
/// 同样**不**从生产代码引用——迁移测试要构造的是"老用户手里那个库"。
const String _v3Events = '''
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL,
  label TEXT NOT NULL,
  start_seconds REAL NOT NULL,
  duration_seconds REAL NOT NULL,
  confidence REAL NOT NULL,
  snore_probability REAL NOT NULL,
  window_count INTEGER NOT NULL,
  clip_path TEXT,
  peak_rms REAL,
  FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
)''';

/// v4 的建表语句：v3 的事件表加上 signal 列、会话表加上 signals_collected。
const String _v4Sessions = '''
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at INTEGER NOT NULL,
  ended_at INTEGER,
  analyzed_seconds REAL NOT NULL DEFAULT 0,
  windows_total INTEGER NOT NULL DEFAULT 0,
  windows_inferred INTEGER NOT NULL DEFAULT 0,
  windows_vad_skipped INTEGER NOT NULL DEFAULT 0,
  windows_low_confidence INTEGER NOT NULL DEFAULT 0,
  event_count INTEGER NOT NULL DEFAULT 0,
  snore_event_count INTEGER NOT NULL DEFAULT 0,
  snore_seconds REAL NOT NULL DEFAULT 0,
  signals_collected INTEGER
)''';

const String _v4Events = '''
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL,
  label TEXT NOT NULL,
  start_seconds REAL NOT NULL,
  duration_seconds REAL NOT NULL,
  confidence REAL NOT NULL,
  snore_probability REAL NOT NULL,
  window_count INTEGER NOT NULL,
  clip_path TEXT,
  peak_rms REAL,
  signal TEXT,
  FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
)''';

void main() {
  setUpAll(sqfliteFfiInit);

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sleep_secret_migration');
    dbPath = '${tempDir.path}/sleep_secret.db';
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// 造一个 v1 的库，里面放一条真实记录。
  Future<void> createV1Database() async {
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, _) async {
          await db.execute(_v1Sessions);
          await db.execute(_v1Events);
        },
      ),
    );
    await db.insert('sessions', {
      'started_at': DateTime(2026, 10, 5, 23).millisecondsSinceEpoch,
      'ended_at': DateTime(2026, 10, 6, 7).millisecondsSinceEpoch,
      'analyzed_seconds': 28800.0,
      'windows_total': 9600,
      'windows_inferred': 3200,
      'windows_vad_skipped': 6400,
      'windows_low_confidence': 0,
      'event_count': 2,
      'snore_event_count': 1,
      'snore_seconds': 240.0,
    });
    await db.insert('events', {
      'session_id': 1,
      'label': 'snore',
      'start_seconds': 3600.0,
      'duration_seconds': 240.0,
      'confidence': 0.82,
      'snore_probability': 0.77,
      'window_count': 80,
    });
    await db.insert('events', {
      'session_id': 1,
      'label': 'cough',
      'start_seconds': 7200.0,
      'duration_seconds': 12.0,
      'confidence': 0.5,
      'snore_probability': 0.1,
      'window_count': 4,
    });
    await db.close();
  }

  /// 造一个 v2 的库：有片段列，但**还没有电平列**。
  Future<void> createV2Database() async {
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) async {
          await db.execute(_v1Sessions);
          await db.execute(_v2Events);
        },
      ),
    );
    await db.insert('sessions', {
      'started_at': DateTime(2026, 10, 5, 23).millisecondsSinceEpoch,
      'ended_at': DateTime(2026, 10, 6, 7).millisecondsSinceEpoch,
      'analyzed_seconds': 28800.0,
      'windows_total': 9600,
      'windows_inferred': 3200,
      'windows_vad_skipped': 6400,
      'windows_low_confidence': 0,
      'event_count': 1,
      'snore_event_count': 1,
      'snore_seconds': 240.0,
    });
    await db.insert('events', {
      'session_id': 1,
      'label': 'snore',
      'start_seconds': 3600.0,
      'duration_seconds': 240.0,
      'confidence': 0.82,
      'snore_probability': 0.77,
      'window_count': 80,
      'clip_path': '1791278973396/3600000.wav',
    });
    await db.close();
  }

  /// 造一个 v3 的库：有片段、有电平，但**还没有高危信号**。
  Future<void> createV3Database() async {
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 3,
        onCreate: (db, _) async {
          await db.execute(_v1Sessions);
          await db.execute(_v3Events);
          await db.execute(
            'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        },
      ),
    );
    await db.insert('sessions', {
      'started_at': DateTime(2026, 10, 6, 23).millisecondsSinceEpoch,
      'ended_at': DateTime(2026, 10, 7, 7).millisecondsSinceEpoch,
      'analyzed_seconds': 28800.0,
      'windows_total': 9600,
      'windows_inferred': 9600,
      'windows_vad_skipped': 0,
      'windows_low_confidence': 0,
      'event_count': 1,
      'snore_event_count': 1,
      'snore_seconds': 240.0,
    });
    await db.insert('events', {
      'session_id': 1,
      'label': 'snore',
      'start_seconds': 3600.0,
      'duration_seconds': 240.0,
      'confidence': 0.82,
      'snore_probability': 0.77,
      'window_count': 80,
      'clip_path': '1791278973396/3600000.wav',
      'peak_rms': 0.42,
    });
    await db.close();
  }

  /// 造一个 v4 的库：有信号，但**还没有原始标签计数**。
  Future<void> createV4Database() async {
    final db = await databaseFactoryFfi.openDatabase(
      dbPath,
      options: OpenDatabaseOptions(
        version: 4,
        onCreate: (db, _) async {
          await db.execute(_v4Sessions);
          await db.execute(_v4Events);
          await db.execute(
            'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
          );
        },
      ),
    );
    await db.insert('sessions', {
      'started_at': DateTime(2026, 10, 7, 23).millisecondsSinceEpoch,
      'ended_at': DateTime(2026, 10, 8, 7).millisecondsSinceEpoch,
      'analyzed_seconds': 28800.0,
      'windows_total': 9600,
      'windows_inferred': 9600,
      'windows_vad_skipped': 0,
      'windows_low_confidence': 0,
      'event_count': 1,
      'snore_event_count': 1,
      'snore_seconds': 240.0,
      'signals_collected': 1,
    });
    await db.insert('events', {
      'session_id': 1,
      'label': 'breathing',
      'start_seconds': 3600.0,
      'duration_seconds': 3.0,
      'confidence': 0.9,
      'snore_probability': 0.1,
      'window_count': 1,
      'clip_path': '1791278973396/3600000.wav',
      'peak_rms': 0.42,
      'signal': 'Gasp',
    });
    await db.close();
  }

  group('v4 -> v5 迁移（加原始标签计数）', () {
    test('老库能打开，事件、片段、电平、信号都还在', () async {
      await createV4Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      final full = await db.loadSession((await db.listSessions()).single.id!);

      expect(full!.events, hasLength(1));
      expect(full.events.single.clipPath, '1791278973396/3600000.wav');
      expect(full.events.single.peakRms, closeTo(0.42, 1e-9));
      expect(full.events.single.signal, 'Gasp');
      expect(full.stats.signalsCollected, isTrue);
    });

    test('老记录的原始标签是空表——不是「一种都没有」', () async {
      await createV4Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      final full = await db.loadSession((await db.listSessions()).single.id!);

      // 空表 = 没收集。报告里的「详细视图」会照这个说「升级前的记录不收集它」，
      // 而不是列一张空表让人以为模型整夜什么都没说。
      expect(full!.stats.rawLabelCounts, isEmpty);
      expect(full.stats.rawLabelKindCount, 0);
    });

    test('迁移后新写入的计数能存能读', () async {
      await createV4Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      await db.insertSession(RecordingSession(
        id: null,
        startedAt: DateTime(2026, 10, 8, 23),
        endedAt: DateTime(2026, 10, 9, 7),
        events: const [],
        stats: const SessionStats(
          analyzedSeconds: 28800,
          windowsTotal: 9600,
          windowsInferred: 9600,
          windowsVadSkipped: 0,
          windowsLowConfidence: 0,
          eventCount: 0,
          snoreEventCount: 0,
          snoreSeconds: 0,
          categoryDistribution: {},
          signalsCollected: true,
          rawLabelCounts: {'Snoring': 4120, 'Male speech, man speaking': 430},
        ),
      ));

      // 按开始时间倒序，刚写进去的那条在最前面
      final full = await db.loadSession((await db.listSessions()).first.id!);

      expect(full!.stats.rawLabelCounts,
          {'Snoring': 4120, 'Male speech, man speaking': 430},
          reason: '新列要真的落盘，不能只是建了列没写');
    });

    test('坏 JSON 不会让整条记录读不出来', () async {
      await createV4Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      await db.insertSession(RecordingSession(
        id: null, startedAt: DateTime(2026, 10, 8, 23), endedAt: null,
        events: const [], stats: const SessionStats.empty(),
      ));
      // 直接往那一列里塞一段坏数据，模拟写坏/被截断
      final id = (await db.listSessions()).first.id!;
      await (await db.open()).update('sessions', {'raw_label_counts': '{不是 JSON'},
          where: 'id = ?', whereArgs: [id]);

      final full = await db.loadSession(id);
      expect(full, isNotNull, reason: '核查用的数据读不出来，不该把整晚记录一起毁掉');
      expect(full!.stats.rawLabelCounts, isEmpty);
    });

    test('v1 的老库能一路升到 v5（四步迁移连着跑）', () async {
      await createV1Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      final full = await db.loadSession((await db.listSessions()).single.id!);

      expect(full!.events, hasLength(2), reason: '四步迁移之后事件都该在');
      expect(full.stats.rawLabelCounts, isEmpty);
    });
  });

  group('v3 -> v4 迁移（加高危信号）', () {
    test('老库能打开，事件一条不丢，片段和电平都还在', () async {
      await createV3Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      final full = await db.loadSession((await db.listSessions()).single.id!);

      expect(full!.events, hasLength(1));
      expect(full.events.single.clipPath, '1791278973396/3600000.wav');
      expect(full.events.single.peakRms, closeTo(0.42, 1e-9));
      expect(full.events.single.signal, isNull, reason: 'v3 不收集信号');
    });

    test('老记录读出来是「没查过」，不是「一个都没有」', () async {
      // ⚠️ 这条是重点。两种状态在界面上长得一模一样，含义却正相反：
      // 一个是「查了，没有」，一个是「根本没查」。读错的话，用户会拿一份
      // 空数据的旧报告当作「我一切正常」的证据——那正是这个应用最不该做的事。
      await createV3Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      final full = await db.loadSession((await db.listSessions()).single.id!);

      expect(full!.stats.signalsCollected, isFalse);
      expect(analyzeApneaSignals(full).collected, isFalse);
    });

    test('迁移后新写入的信号事件能带 signal', () async {
      await createV3Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      await db.insertSession(RecordingSession(
        id: null,
        startedAt: DateTime(2026, 10, 7, 23),
        endedAt: DateTime(2026, 10, 8, 7),
        events: const [
          SoundEvent(
            label: SleepCategory.breathing,
            startSeconds: 100,
            durationSeconds: 3,
            confidence: 0.9,
            snoreProbability: 0.1,
            windowCount: 1,
            signal: 'Gasp',
          ),
        ],
        stats: const SessionStats(
          analyzedSeconds: 28800,
          windowsTotal: 9600,
          windowsInferred: 9600,
          windowsVadSkipped: 0,
          windowsLowConfidence: 0,
          eventCount: 1,
          snoreEventCount: 0,
          snoreSeconds: 0,
          categoryDistribution: {},
          signalsCollected: true,
        ),
      ));

      // 按开始时间倒序，刚写进去的那条在最前面
      final full = await db.loadSession((await db.listSessions()).first.id!);

      expect(full!.events.single.signal, 'Gasp',
          reason: '新列要真的落盘，不能只是建了列没写');
      expect(full.stats.signalsCollected, isTrue);
    });

    test('v1 的老库能一路升到 v4（三步迁移连着跑）', () async {
      await createV1Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      final full = await db.loadSession((await db.listSessions()).single.id!);

      expect(full!.events, hasLength(2), reason: '三步迁移之后事件都该在');
      for (final e in full.events) {
        expect(e.clipPath, isNull, reason: 'v1 没有片段');
        expect(e.peakRms, isNull, reason: 'v1 也没有电平');
        expect(e.signal, isNull, reason: 'v1 更没有信号');
      }
      expect(full.stats.signalsCollected, isFalse);
    });
  });

  group('v2 -> v3 迁移（加电平列）', () {
    test('老库能打开，事件一条不丢，片段路径还在', () async {
      await createV2Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      await db.open();
      final sessions = await db.listSessions();
      expect(sessions.length, 1);

      final full = await db.loadSession(sessions.single.id!);
      expect(full!.events.length, 1);
      expect(full.events.single.label, SleepCategory.snore);
      expect(full.events.single.clipPath, '1791278973396/3600000.wav',
          reason: '加新列不该动到已有的列');

      await db.close();
    });

    test('老事件的 peakRms 是 null，不是 0', () async {
      // ⚠️ 这条是重点。0 会在界面上显示成"这一声是 0 分贝"——
      // 而真相是"那时候根本没记电平"。用 0 当"没有"，用户会以为
      // 那一晚安静得不正常。
      await createV2Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      await db.open();
      final sessions = await db.listSessions();
      final full = await db.loadSession(sessions.single.id!);

      expect(full!.events.single.peakRms, isNull);
      expect(full.events.single.hasLevel, isFalse);

      await db.close();
    });

    test('迁移后新写入的事件能带电平', () async {
      await createV2Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      await db.open();
      await db.insertSession(RecordingSession(
        id: null,
        startedAt: DateTime(2026, 10, 6, 23),
        endedAt: DateTime(2026, 10, 7, 7),
        events: const [
          SoundEvent(
            label: SleepCategory.snore,
            startSeconds: 100,
            durationSeconds: 12,
            confidence: 0.8,
            snoreProbability: 0.8,
            windowCount: 4,
            peakRms: 0.31,
          ),
        ],
        stats: SessionStats.empty(),
      ));

      // 按开始时间**倒序**，所以刚写进去的那条在最前面。
      // （第一版写成了 .last，取到的是 v2 那条老记录——被这条测试抓到了。）
      final full = await db.loadSession((await db.listSessions()).first.id!);
      expect(full!.events.single.peakRms, closeTo(0.31, 1e-9),
          reason: '新列要真的落盘，不能只是建了列没写');

      await db.close();
    });

    test('v1 的老库能一路升到 v4（三步迁移连着跑）', () async {
      // 这是最容易断的一条：真实用户可能跳过好几个版本。
      // 每步迁移只处理自己那一段，连着跑不能互相踩。
      await createV1Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      await db.open();
      final sessions = await db.listSessions();
      expect(sessions.length, 1);

      final full = await db.loadSession(sessions.single.id!);
      expect(full!.events.length, 2, reason: 'v1 的两条事件在两步迁移之后都该在');
      for (final e in full.events) {
        expect(e.clipPath, isNull, reason: 'v1 没有片段');
        expect(e.peakRms, isNull, reason: 'v1 也没有电平');
      }

      await db.close();
    });
  });

  group('v1 -> v2 迁移', () {
    test('老库能打开，原有记录一条不丢', () async {
      await createV1Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      final list = await db.listSessions();

      expect(list.length, 1);
      expect(list.single.stats.analyzedSeconds, 28800);
      expect(list.single.stats.snoreSeconds, 240);
      expect(list.single.stats.snoreEventCount, 1);
    });

    test('老事件全部保留，clip_path 为空', () async {
      await createV1Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      final session = await db.loadSession(1);

      expect(session!.events.length, 2);
      expect(session.events.every((e) => e.clipPath == null), isTrue,
          reason: 'v1 没有片段，迁移后应当是"无片段"而不是报错或丢事件');
      expect(session.events.first.label, SleepCategory.snore);
      expect(session.events.first.durationSeconds, 240);
    });

    test('迁移后新写入的会话能带片段', () async {
      await createV1Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      final id = await db.insertSession(RecordingSession(
        id: null,
        startedAt: DateTime(2026, 10, 6, 23),
        endedAt: DateTime(2026, 10, 7, 7),
        events: [
          SoundEvent(
            label: SleepCategory.snore,
            startSeconds: 100,
            durationSeconds: 60,
            confidence: 0.8,
            snoreProbability: 0.75,
            windowCount: 20,
            clipPath: 'sess/100000.wav',
          ),
        ],
        stats: const SessionStats.empty(),
      ));

      final loaded = await db.loadSession(id);
      expect(loaded!.events.single.clipPath, 'sess/100000.wav');
    });

    test('迁移后设置表可用', () async {
      await createV1Database();

      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      // 设置表是 v2 才有的，老库升级后必须也建出来
      expect(await db.readBoolSetting('record_clips', fallback: true), isTrue);
      await db.writeBoolSetting('record_clips', false);
      expect(await db.readBoolSetting('record_clips', fallback: true), isFalse);
    });

    test('重复打开不会重复迁移', () async {
      await createV1Database();

      final first = SessionDatabase(
          factory: databaseFactoryFfi, databasePath: dbPath);
      await first.listSessions();
      await first.close();

      // 再开一次：版本已经是 2，onUpgrade 不该再跑（再跑会因列已存在而报错）
      final second = SessionDatabase(
          factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(second.close);

      expect((await second.listSessions()).length, 1);
      expect(await second.readBoolSetting('record_clips', fallback: true), isTrue);
    });
  });

  group('全新安装（v2 直接建库）', () {
    test('新库结构与迁移后的库一致：能存能读片段', () async {
      final db = SessionDatabase(factory: databaseFactoryFfi, databasePath: dbPath);
      addTearDown(db.close);

      final id = await db.insertSession(RecordingSession(
        id: null,
        startedAt: DateTime(2026, 10, 6, 23),
        endedAt: null,
        events: [
          SoundEvent(
            label: SleepCategory.snore,
            startSeconds: 10,
            durationSeconds: 30,
            confidence: 0.9,
            snoreProbability: 0.9,
            windowCount: 10,
            clipPath: 'a/b.wav',
          ),
        ],
        stats: const SessionStats.empty(),
      ));

      expect((await db.loadSession(id))!.events.single.clipPath, 'a/b.wav');
      expect(await db.readBoolSetting('record_clips', fallback: false), isFalse);
    });
  });
}
