import 'dart:convert';

import '../models/recording_session.dart';
import '../models/sleep_category.dart';
import '../models/sound_event.dart';

/// 导出文件的**格式**。改这里要同时改 [kArchiveFormat]，让旧文件读得出来。
///
/// 一晚一个文件，文件名就是会话开始时刻的毫秒数——
/// 这个数同时是**去重键**（导入时用它判断这一晚是不是已经有了）
/// 和**片段目录名**（本地片段就存在 `clips/<毫秒>/` 下），
/// 所以导出时路径能 1:1 映射过去，不用重写任何相对路径。
const int kArchiveFormat = 1;
const String kArchiveApp = 'sleep-secret';

/// 一晚的会话 -> JSON 字符串。
///
/// ⚠️ 类别名用 `SleepCategory.name`（`snore` / `ambient`），
/// **不要用 `.label`**——那是给人看的中文，改文案会让历史文件全部读不出来。
/// 数据库那边也是这个规矩（见 `session_database.dart` 里读类别的注释）。
String encodeSession(RecordingSession session) {
  final json = <String, Object?>{
    'format': kArchiveFormat,
    'app': kArchiveApp,
    'session': {
      'startedAt': session.startedAt.millisecondsSinceEpoch,
      'endedAt': session.endedAt?.millisecondsSinceEpoch,
      'stats': _encodeStats(session.stats),
      'events': session.events.map(_encodeEvent).toList(growable: false),
    },
  };
  // 缩进两格：这些文件人也会打开看，可读性比体积重要
  return const JsonEncoder.withIndent('  ').convert(json);
}

/// 从 JSON 字符串读回一晚。
///
/// 坏文件抛 [FormatException]——**调用方要能区分「这个文件不是我们的」
/// 和「读的时候出错了」**，前者该跳过，后者该报给用户。
RecordingSession decodeSession(String content) {
  final decoded = jsonDecode(content);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('顶层不是 JSON 对象');
  }
  if (decoded['app'] != kArchiveApp) {
    throw FormatException('不是本应用的导出文件（app=${decoded['app']}）');
  }
  final format = decoded['format'];
  if (format is! int || format > kArchiveFormat) {
    throw FormatException('导出格式版本 $format 比本版本（$kArchiveFormat）新，读不了');
  }

  final s = decoded['session'];
  if (s is! Map<String, dynamic>) {
    throw const FormatException('缺少 session');
  }

  final startedAt = _int(s['startedAt'], 'startedAt');
  final endedAt = s['endedAt'];

  return RecordingSession(
    // 导入时不保留原 id——insertSession 本来也不写 id，
    // 数据库会自己分配，不存在主键冲突。
    id: null,
    startedAt: DateTime.fromMillisecondsSinceEpoch(startedAt),
    endedAt: endedAt == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(_int(endedAt, 'endedAt')),
    events: _decodeEvents(s['events']),
    stats: _decodeStats(s['stats']),
  );
}

// ------------------------------------------------------------------ 内部

Map<String, Object?> _encodeStats(SessionStats stats) => {
      'analyzedSeconds': stats.analyzedSeconds,
      'windowsTotal': stats.windowsTotal,
      'windowsInferred': stats.windowsInferred,
      'windowsVadSkipped': stats.windowsVadSkipped,
      'windowsLowConfidence': stats.windowsLowConfidence,
      'eventCount': stats.eventCount,
      'snoreEventCount': stats.snoreEventCount,
      'snoreSeconds': stats.snoreSeconds,
      // 这一项**数据库里不存**（读回来恒为空表），导出带上是为了让 JSON
      // 本身是一份完整的数据快照；导入时读不出来，会退回空表。
      'categoryDistribution': {
        for (final e in stats.categoryDistribution.entries) e.key.name: e.value,
      },
    };

Map<String, Object?> _encodeEvent(SoundEvent e) => {
      'label': e.label.name,
      'startSeconds': e.startSeconds,
      'durationSeconds': e.durationSeconds,
      'confidence': e.confidence,
      'snoreProbability': e.snoreProbability,
      'windowCount': e.windowCount,
      // 相对片段根目录的路径，导入时原样用
      'clipPath': e.clipPath,
      // 存原始 RMS 不存分贝——参考值是个假设，改它不该让历史文件读不出来
      'peakRms': e.peakRms,
    };

List<SoundEvent> _decodeEvents(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) throw const FormatException('events 不是数组');
  return [
    for (final item in raw)
      if (item is Map<String, dynamic>)
        SoundEvent(
          label: _category(item['label']),
          startSeconds: _double(item['startSeconds'], 'startSeconds'),
          durationSeconds: _double(item['durationSeconds'], 'durationSeconds'),
          confidence: _double(item['confidence'], 'confidence'),
          snoreProbability: _double(item['snoreProbability'], 'snoreProbability'),
          windowCount: _int(item['windowCount'], 'windowCount'),
          clipPath: item['clipPath'] as String?,
          // 老文件里没有这一项，读出来是 null——那是没记，不是 0
          peakRms: (item['peakRms'] as num?)?.toDouble(),
        ),
  ];
}

SessionStats _decodeStats(Object? raw) {
  if (raw is! Map<String, dynamic>) {
    throw const FormatException('缺少 stats');
  }
  return SessionStats(
    analyzedSeconds: _double(raw['analyzedSeconds'], 'analyzedSeconds'),
    windowsTotal: _int(raw['windowsTotal'], 'windowsTotal'),
    windowsInferred: _int(raw['windowsInferred'], 'windowsInferred'),
    windowsVadSkipped: _int(raw['windowsVadSkipped'], 'windowsVadSkipped'),
    windowsLowConfidence: _int(raw['windowsLowConfidence'], 'windowsLowConfidence'),
    eventCount: _int(raw['eventCount'], 'eventCount'),
    snoreEventCount: _int(raw['snoreEventCount'], 'snoreEventCount'),
    snoreSeconds: _double(raw['snoreSeconds'], 'snoreSeconds'),
    categoryDistribution: const {},
  );
}

/// 按 `.name` 找类别。找不到时抛异常而不是猜一个——
/// 猜的话会把一个未知类别悄悄变成别的，那是数据损坏。
SleepCategory _category(Object? raw) {
  if (raw is! String) throw FormatException('类别不是字符串（$raw）');
  for (final c in SleepCategory.values) {
    if (c.name == raw) return c;
  }
  throw FormatException('未知类别 $raw');
}

int _int(Object? v, String field) {
  if (v is int) return v;
  if (v is num) return v.round();
  throw FormatException('$field 不是数字（$v）');
}

double _double(Object? v, String field) {
  if (v is num) return v.toDouble();
  throw FormatException('$field 不是数字（$v）');
}
