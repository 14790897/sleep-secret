import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../domain/repositories/archive_controller.dart';
import '../../../../data/repositories/archive_repository.dart';
import '../../../../domain/models/ui_message.dart';

/// 导出/导入页的状态。
class ArchiveViewModel extends ChangeNotifier {
  ArchiveViewModel({required this._controller}) {
    _sub = _controller.changes.listen((_) => notifyListeners());
    // 和其它 ViewModel 不同，这里在构造时就加载：界面一打开就要显示
    // 当前配的目录，不能等用户先点一下。
    unawaited(_controller.load());
  }

  final ArchiveController _controller;
  StreamSubscription<void>? _sub;

  /// 上一次操作给出的错误，给用户看。操作成功或重新选择目录后清掉。
  UiMessage? _error;
  UiMessage? get error => _error;

  String? get targetDescription => _controller.exportTargetDescription;
  bool get hasTarget => _controller.exportTargetDescription != null;
  bool get targetUsable => _controller.exportTargetUsable;
  bool get busy => _controller.busy;
  ArchiveOutcome? get lastOutcome => _controller.lastOutcome;
  bool get lastWasExport => _controller.lastWasExport;

  /// 配了目录、但目录现在用不了（授权被撤销、或目录被删了）。
  bool get targetBroken => hasTarget && !targetUsable;

  Future<void> chooseTarget() async {
    _error = null;
    try {
      await _controller.chooseExportTarget();
    } catch (e) {
      _error = UiMessage(UiMessageKind.archivePickFailed, '$e');
    }
    notifyListeners();
  }

  Future<void> clearTarget() async {
    _error = null;
    await _controller.clearExportTarget();
    notifyListeners();
  }

  Future<void> exportAll() => _run(_controller.exportAll);

  Future<void> importAll() => _run(_controller.importAll);

  Future<void> _run(Future<ArchiveOutcome> Function() op) async {
    _error = null;
    notifyListeners();
    try {
      await op();
    } on ArchiveException catch (e) {
      // 这几条是"用户能自己解决"的，它们自己带着该说哪种话
      _error = e.message;
    } catch (e) {
      _error = UiMessage(UiMessageKind.archiveOperationFailed, '$e');
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
