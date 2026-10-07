import 'dart:io';

import '../../domain/analysis/export_codec.dart';
import '../../domain/models/recording_session.dart';
import '../../domain/repositories/archive_controller.dart' show ArchiveOutcome;
import '../../domain/repositories/audio_clip_store.dart';
import '../../domain/repositories/export_target.dart';
import 'session_database.dart';

/// 把会话导出到 [ExportTarget]、或从它导入。
///
/// 目录结构（相对目标根）：
///
/// ```
/// sessions/<会话开始毫秒>.json      一晚一个文件
/// clips/<会话开始毫秒>/<起始毫秒>.wav
/// ```
///
/// **文件名就是会话开始时刻的毫秒数**，它同时是：
/// - 导入时的**去重键**（本地已有同一个毫秒数就跳过）
/// - 本地片段目录的名字（`clips/<毫秒>/`）
///
/// 所以路径能 1:1 对应过去，导出导入都不用重写任何相对路径。
class ArchiveService {
  ArchiveService({
    required this._database,
    required this._clipStore,
  });

  final SessionDatabase _database;
  final AudioClipStore _clipStore;

  static const String _sessionsDir = 'sessions';
  static const String _clipsDir = 'clips';

  /// 导出。[sessions] 为 null 时导出全部（自己从库里读，含事件）。
  Future<ArchiveOutcome> export(
    ExportTarget target, {
    List<RecordingSession>? sessions,
  }) async {
    await _database.open();

    final list = sessions ?? await _loadAll();
    await target.ensureDirectory(_sessionsDir);
    await target.ensureDirectory(_clipsDir);

    var written = 0;
    var clips = 0;
    var missing = 0;
    final problems = <String>[];

    for (final session in list) {
      final key = session.startedAt.millisecondsSinceEpoch;

      // 片段先搬：万一中途失败，JSON 也已经写出去了，
      // 那条记录会指向一个不存在的片段——报告里会显示成"片段丢失"，
      // 比"记录整个没有"更容易发现。
      for (final event in session.events) {
        final rel = event.clipPath;
        if (rel == null) continue;
        final abs = await _clipStore.resolve(rel);
        if (abs == null) {
          missing++;
          continue;
        }
        try {
          await target.copyIn(abs, '$_clipsDir/$rel');
          clips++;
        } catch (e) {
          problems.add('片段 ${event.clipPath} 写入失败：$e');
          missing++;
        }
      }

      try {
        await target.writeText('$_sessionsDir/$key.json', encodeSession(session));
        written++;
      } catch (e) {
        problems.add('会话 $key 写入失败：$e');
      }
    }

    return ArchiveOutcome(
      sessions: written,
      clips: clips,
      clipsMissing: missing,
      problems: problems,
    );
  }

  /// 从 [target] 导入。本地已有的（按开始时刻判断）跳过，不重复导。
  ///
  /// 去重**必须按开始时刻**：数据库在插入时自己分配 id，所以原来那个 id
  /// 进不来也留不下；而 `started_at` 没有唯一约束，不去重就会每次导入都多一份。
  Future<ArchiveOutcome> import(ExportTarget target) async {
    await _database.open();

    final existing = {
      for (final s in await _database.listSessions())
        s.startedAt.millisecondsSinceEpoch,
    };

    final files = await target.listFiles(_sessionsDir);
    final temp = await Directory.systemTemp.createTemp('sleep_secret_import');

    var imported = 0;
    var skipped = 0;
    var clips = 0;
    var missing = 0;
    final problems = <String>[];

    try {
      for (final name in files) {
        if (!name.endsWith('.json')) continue;

        final content = await target.readText('$_sessionsDir/$name');
        if (content == null) {
          skipped++;
          continue;
        }

        final RecordingSession session;
        try {
          session = decodeSession(content);
        } on FormatException catch (e) {
          // 坏文件**跳过并记下来**，不要让一个文件挡住其余的
          skipped++;
          problems.add('$name 读不了：${e.message}');
          continue;
        }

        final key = session.startedAt.millisecondsSinceEpoch;
        if (existing.contains(key)) {
          skipped++;
          continue;
        }

        for (final event in session.events) {
          final rel = event.clipPath;
          if (rel == null) continue;
          // 临时文件名只取末段，避免 rel 里带子目录时路径不存在
          final tmp = '${temp.path}/${rel.split('/').last}';
          try {
            if (!await target.copyOut('$_clipsDir/$rel', tmp)) {
              missing++;
              continue;
            }
            if (await _clipStore.adopt(relativePath: rel, localPath: tmp)) {
              clips++;
            } else {
              missing++;
            }
          } catch (e) {
            problems.add('片段 $rel 导入失败：$e');
            missing++;
          } finally {
            final f = File(tmp);
            if (await f.exists()) await f.delete();
          }
        }

        await _database.insertSession(session);
        existing.add(key);
        imported++;
      }
    } finally {
      if (await temp.exists()) await temp.delete(recursive: true);
    }

    return ArchiveOutcome(
      sessions: imported,
      skipped: skipped,
      clips: clips,
      clipsMissing: missing,
      problems: problems,
    );
  }

  /// 读全部会话——`listSessions` 不带事件，导出必须逐个补上。
  Future<List<RecordingSession>> _loadAll() async {
    final out = <RecordingSession>[];
    for (final summary in await _database.listSessions()) {
      final full = await _database.loadSession(summary.id!);
      if (full != null) out.add(full);
    }
    return out;
  }
}
