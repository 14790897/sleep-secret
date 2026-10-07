import 'package:sqflite/sqflite.dart';

import '../../domain/models/recording_session.dart';
import '../../domain/models/sleep_category.dart';
import '../../domain/models/sound_event.dart';

/// 会话持久化。
///
/// 存的是「分析结果」不是原始音频——整夜 16kHz 单声道 PCM 约 920MB，
/// 全存既没必要也放不下。事件的时间戳足以还原时间线。
class SessionDatabase {
  SessionDatabase({DatabaseFactory? factory, this.databasePath})
      : _factory = factory ?? databaseFactory;

  static const int schemaVersion = 3;
  static const String _dbName = 'sleep_secret.db';

  final DatabaseFactory _factory;

  /// 显式指定库文件路径；为 null 时用平台默认位置。
  /// 测试传 `inMemoryDatabasePath`。
  final String? databasePath;

  Database? _db;

  bool get isOpen => _db != null;

  /// 打开数据库。重复调用返回同一个连接。
  Future<Database> open() async {
    if (_db != null) return _db!;
    final path = databasePath ?? '${await _factory.getDatabasesPath()}/$_dbName';
    _db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: _createSchema,
        onUpgrade: _upgradeSchema,
      ),
    );
    return _db!;
  }

  Future<void> _createSchema(Database db, int version) async {
    await db.execute('''
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
      )
    ''');
    await db.execute('''
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
        -- 这个事件里最响那个窗口的 RMS。老记录是 NULL（那时候不记电平）。
        -- 存原始量不存分贝：分贝的参考值是个假设，将来可能会改。
        peak_rms REAL,
        FOREIGN KEY (session_id) REFERENCES sessions (id) ON DELETE CASCADE
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_events_session ON events (session_id, start_seconds)',
    );
    await _createSettingsTable(db);
  }

  /// 应用设置。用数据库存而不是再引一个偏好存储依赖——
  /// 已经有 SQLite 了，一个存储机制比两个好维护。
  Future<void> _createSettingsTable(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''');
  }

  /// 逐版本升级。老用户的库要能平滑升上来，不能要求重装。
  Future<void> _upgradeSchema(Database db, int from, int to) async {
    if (from < 2) {
      // v1 没有音频片段。老记录保留为"无片段"，不影响其他字段。
      await db.execute('ALTER TABLE events ADD COLUMN clip_path TEXT');
    }
    if (from < 3) {
      // v2 不记每个事件的电平。老记录保留为 NULL——界面上要能区分
      // 「这一晚没记电平」和「这一晚很安静」，不能拿 0 当"没有"。
      await db.execute('ALTER TABLE events ADD COLUMN peak_rms REAL');
      await _createSettingsTable(db);
    }
  }

  /// 读一个字符串设置。没设过就返回 null。
  ///
  /// settings 表本来就是 `key TEXT PRIMARY KEY, value TEXT`——值一直是文本，
  /// 所以加字符串类型的设置**不用改表、也不用升 schema 版本**。
  Future<String?> readStringSetting(String key) async {
    final db = await open();
    final rows = await db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['value'] as String?;
  }

  /// 写一个字符串设置。传 null 表示**删掉这一项**（比如用户取消配置导出目录）。
  Future<void> writeStringSetting(String key, String? value) async {
    final db = await open();
    if (value == null) {
      await db.delete('settings', where: 'key = ?', whereArgs: [key]);
      return;
    }
    await db.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<bool> readBoolSetting(String key, {required bool fallback}) async {
    final raw = await readStringSetting(key);
    return raw == null ? fallback : raw == 'true';
  }

  Future<void> writeBoolSetting(String key, bool value) =>
      writeStringSetting(key, value ? 'true' : 'false');

  /// 写入一个会话及其全部事件，返回新会话 id。整个过程在一个事务里，
  /// 避免只写进一半导致会话与事件对不上。
  Future<int> insertSession(RecordingSession session) async {
    final db = await open();
    return db.transaction((txn) async {
      final id = await txn.insert('sessions', {
        'started_at': session.startedAt.millisecondsSinceEpoch,
        'ended_at': session.endedAt?.millisecondsSinceEpoch,
        'analyzed_seconds': session.stats.analyzedSeconds,
        'windows_total': session.stats.windowsTotal,
        'windows_inferred': session.stats.windowsInferred,
        'windows_vad_skipped': session.stats.windowsVadSkipped,
        'windows_low_confidence': session.stats.windowsLowConfidence,
        'event_count': session.stats.eventCount,
        'snore_event_count': session.stats.snoreEventCount,
        'snore_seconds': session.stats.snoreSeconds,
      });

      for (final event in session.events) {
        await txn.insert('events', {
          'session_id': id,
          'label': event.label.name,
          'start_seconds': event.startSeconds,
          'duration_seconds': event.durationSeconds,
          'confidence': event.confidence,
          'snore_probability': event.snoreProbability,
          'window_count': event.windowCount,
          'clip_path': event.clipPath,
          'peak_rms': event.peakRms,
        });
      }
      return id;
    });
  }

  /// 按开始时间倒序列出全部会话（不含事件，用于列表页）。
  Future<List<RecordingSession>> listSessions() async {
    final db = await open();
    final rows = await db.query('sessions', orderBy: 'started_at DESC');
    return rows.map(_sessionFromRow).toList(growable: false);
  }

  /// 读取单个会话，附带全部事件。
  Future<RecordingSession?> loadSession(int id) async {
    final db = await open();
    final rows = await db.query(
      'sessions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final eventRows = await db.query(
      'events',
      where: 'session_id = ?',
      whereArgs: [id],
      orderBy: 'start_seconds ASC',
    );
    return _sessionFromRow(
      rows.first,
      events: eventRows.map(_eventFromRow).toList(growable: false),
    );
  }

  Future<void> deleteSession(int id) async {
    final db = await open();
    // 外键 ON DELETE CASCADE 会一并清掉 events。
    await db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  /// 某个会话名下的原始事件行数。
  ///
  /// 用于校验级联删除与数据完整性——[loadSession] 走的是会话查询，
  /// 万一 events 表里留下孤儿行它是看不见的。
  Future<int> countEventRows(int sessionId) async {
    final db = await open();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM events WHERE session_id = ?',
      [sessionId],
    );
    return (rows.first['n'] as int?) ?? 0;
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }

  RecordingSession _sessionFromRow(
    Map<String, Object?> row, {
    List<SoundEvent> events = const [],
  }) {
    final startedAt =
        DateTime.fromMillisecondsSinceEpoch(row['started_at']! as int);
    final endedRaw = row['ended_at'] as int?;

    return RecordingSession(
      id: row['id'] as int?,
      startedAt: startedAt,
      endedAt:
          endedRaw == null ? null : DateTime.fromMillisecondsSinceEpoch(endedRaw),
      events: events,
      stats: SessionStats(
        analyzedSeconds: (row['analyzed_seconds'] as num).toDouble(),
        windowsTotal: row['windows_total']! as int,
        windowsInferred: row['windows_inferred']! as int,
        windowsVadSkipped: row['windows_vad_skipped']! as int,
        windowsLowConfidence: row['windows_low_confidence']! as int,
        eventCount: row['event_count']! as int,
        snoreEventCount: row['snore_event_count']! as int,
        snoreSeconds: (row['snore_seconds'] as num).toDouble(),
        // 类别分布不落库：它是平均概率，体积大且对"看历史"价值有限，
        // 需要时应重跑分析。
        categoryDistribution: const {},
      ),
    );
  }

  SoundEvent _eventFromRow(Map<String, Object?> row) => SoundEvent(
        label: _categoryFromName(row['label']! as String),
        startSeconds: (row['start_seconds'] as num).toDouble(),
        durationSeconds: (row['duration_seconds'] as num).toDouble(),
        confidence: (row['confidence'] as num).toDouble(),
        snoreProbability: (row['snore_probability'] as num).toDouble(),
        windowCount: row['window_count']! as int,
        clipPath: row['clip_path'] as String?,
        peakRms: row['peak_rms'] as double?,
      );

  /// 存的是枚举名而不是中文标签——中文改了不影响历史数据可读性。
  static SleepCategory _categoryFromName(String name) {
    for (final category in SleepCategory.values) {
      if (category.name == name) return category;
    }
    throw FormatException('未知的睡眠类别: $name');
  }
}
