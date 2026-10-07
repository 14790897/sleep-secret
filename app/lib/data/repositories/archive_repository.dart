import 'dart:async';

import '../../domain/models/recording_session.dart';
import '../../domain/models/ui_message.dart';
import '../../domain/repositories/archive_controller.dart';
import '../../domain/repositories/export_target.dart';
import '../services/archive_service.dart';
import '../services/session_database.dart';
import '../services/webdav_export_target.dart';

/// 导出/导入的编排：配置存哪、目标还能不能用、正在忙不忙。
///
/// 真正的搬运逻辑在 [ArchiveService] 里（那一层不碰平台 API，可以在电脑上测）；
/// 这里只负责把「用户配置的目标」和「搬运」接起来。
class ArchiveRepository implements ArchiveController {
  ArchiveRepository({
    required this._service,
    required this._database,
    required this._picker,
  });

  static const String _kExportTarget = 'export_target';

  /// 没传上去的那几晚（会话 id，逗号分隔）。
  ///
  /// 自动导出失败时**不能就这么算了**：整夜录音是插着电放在床头跑的，
  /// 网盘那会儿掉线、或者手机在省电模式下掐了网络，都是常事。
  /// 记下来，下次打开 App 再试一次。
  static const String _kPendingUploads = 'pending_uploads';

  final ArchiveService _service;
  final SessionDatabase _database;
  final ExportTargetPicker _picker;

  final _changes = StreamController<void>.broadcast();

  String? _serialized;
  String? _description;
  bool _usable = false;
  bool _loaded = false;
  bool _busy = false;
  ArchiveOutcome? _last;
  bool _lastWasExport = true;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  String? get exportTargetDescription => _description;

  @override
  bool get exportTargetUsable => _usable;

  @override
  ArchiveOutcome? get lastOutcome => _last;

  @override
  bool get lastWasExport => _lastWasExport;

  @override
  bool get busy => _busy;

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  @override
  Future<void> load() async {
    await _database.open();
    if (!_loaded) {
      _loaded = true;
      _serialized = await _database.readStringSetting(_kExportTarget);
    }
    // 可用性**每次都重查**，不能只查第一次。
    // 用户在应用开着的时候把网盘目录删了/改名了是很常见的，
    // 只查一次的话页面会一直显示「可用」，直到他点下去才报错。
    await _refreshUsable();
    _emit();
  }

  /// 还原目标并检查它还能不能用。SAF 的授权可能被用户在系统设置里撤销了，
  /// 或者那个目录被删了——这时候要如实显示「失效」，而不是等用户点了按钮才报错。
  Future<void> _refreshUsable() async {
    final s = _serialized;
    if (s == null) {
      _description = null;
      _usable = false;
      return;
    }
    final target = await _picker.restore(s);
    if (target == null) {
      // 还原不出来，但**不删配置**——用户可能只是暂时拔了 SD 卡，
      // 或者授权被系统回收了还能重新给。让用户自己决定要不要清掉。
      _description = null;
      _usable = false;
      return;
    }
    _description = target.description;
    _usable = await target.isUsable();
  }

  @override
  Future<bool> chooseExportTarget() async {
    final picked = await _picker.pick();
    if (picked == null) return false; // 用户取消

    _serialized = picked.serialized;
    _description = picked.description;
    _usable = await picked.isUsable();

    await _database.open();
    await _database.writeStringSetting(_kExportTarget, _serialized);

    // 换了目录，上次的结果就不代表现在了
    _last = null;
    _emit();
    return true;
  }

  @override
  Future<void> useWebDavTarget() async {
    _serialized = WebDavExportTarget.serializedTag;
    // description 得走一次 restore 才拿得到（它要读凭据拼主机名）
    final target = await _picker.restore(_serialized!);
    _description = target?.description;
    _usable = target != null;
    _last = null;

    await _database.open();
    await _database.writeStringSetting(_kExportTarget, _serialized);
    _emit();
  }

  @override
  Future<void> clearExportTarget() async {
    _serialized = null;
    _description = null;
    _usable = false;
    _last = null;
    await _database.open();
    await _database.writeStringSetting(_kExportTarget, null);
    _emit();
  }

  /// 这一晚没导出成功，记下来下次再试。
  ///
  /// 没有 id 的会话（还没落库）直接忽略——落库之后才有稳定的标识。
  Future<void> queueRetry(RecordingSession session) async {
    final id = session.id;
    if (id == null) return;
    await _database.open();
    final ids = await _pendingIds()..add('$id');
    await _database.writeStringSetting(_kPendingUploads, ids.join(','));
  }

  /// 把之前失败的再试一遍。启动时调一次。
  ///
  /// 成功的从队列里删掉；**还在失败的留着**——不设次数上限，
  /// 因为失败的原因多半是网络，而网络总会好。
  Future<int> flushRetries() async {
    await _database.open();
    final ids = await _pendingIds();
    if (ids.isEmpty) return 0;

    await load();
    if (_serialized == null) return 0; // 目标被清掉了，队列留着别丢

    var done = 0;
    for (final raw in ids.toList()) {
      final id = int.tryParse(raw);
      if (id == null) {
        ids.remove(raw);
        continue;
      }
      final session = await _database.loadSession(id);
      if (session == null) {
        ids.remove(raw); // 那一晚被删了，别再挂着
        continue;
      }
      try {
        await _run(isExport: true, only: [session]);
        ids.remove(raw);
        done++;
      } catch (_) {
        // 还是不行，留着下次
      }
    }
    await _database.writeStringSetting(
        _kPendingUploads, ids.isEmpty ? null : ids.join(','));
    if (done > 0) _emit();
    return done;
  }

  Future<Set<String>> _pendingIds() async {
    final raw = await _database.readStringSetting(_kPendingUploads) ?? '';
    return raw.split(',').where((s) => s.trim().isNotEmpty).toSet();
  }

  @override
  Future<ArchiveOutcome> exportAll() => _run(isExport: true);

  @override
  Future<ArchiveOutcome> exportSession(RecordingSession session) =>
      _run(isExport: true, only: [session]);

  @override
  Future<ArchiveOutcome> importAll() => _run(isExport: false);

  Future<ArchiveOutcome> _run({
    required bool isExport,
    List<RecordingSession>? only,
  }) async {
    if (_busy) {
      // 并发点两次会让导入的去重判断失效（第二次读到的是第一次还没写完的状态），
      // 结果就是同一晚进来两份。
      throw ArchiveException(UiMessageKind.archiveBusy);
    }

    await load();
    final s = _serialized;
    if (s == null) {
      throw ArchiveException(UiMessageKind.archiveNoTarget);
    }

    final target = await _picker.restore(s);
    if (target == null || !await target.isUsable()) {
      _usable = false;
      _emit();
      throw ArchiveException(UiMessageKind.archiveTargetUnusable);
    }

    _busy = true;
    _lastWasExport = isExport;
    _emit();
    try {
      _last = isExport
          ? await _service.export(target, sessions: only)
          : await _service.import(target);
      return _last!;
    } finally {
      _busy = false;
      _emit();
    }
  }

  @override
  void dispose() {
    _changes.close();
  }
}

/// 导出/导入流程里**用户能自己解决**的问题。
///
/// 用专门的类型而不是 `StateError`：这些是要显示给用户看的，
/// 需要带上是"哪一种"（见 [UiMessage]），而 `StateError` 只有一条字符串。
class ArchiveException implements Exception {
  ArchiveException(UiMessageKind kind, [String? detail])
      : message = UiMessage(kind, detail);

  final UiMessage message;

  @override
  String toString() => 'ArchiveException(${message.kind.name})';
}
