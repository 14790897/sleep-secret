import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../domain/repositories/archive_controller.dart';
import '../../../../data/repositories/archive_repository.dart';
import '../../../../data/services/webdav_client.dart';
import '../../../../data/services/webdav_settings.dart';
import '../../../../domain/models/ui_message.dart';

/// 导出/导入页的状态。
class ArchiveViewModel extends ChangeNotifier {
  ArchiveViewModel({
    required this._controller,
    WebDavSettingsStore? webDavSettings,
  }) : _webDavStore = webDavSettings {
    _sub = _controller.changes.listen((_) => notifyListeners());
    // 和其它 ViewModel 不同，这里在构造时就加载：界面一打开就要显示
    // 当前配的目录，不能等用户先点一下。
    unawaited(_controller.load());
    unawaited(_loadWebDav());
  }

  final ArchiveController _controller;
  StreamSubscription<void>? _sub;

  /// 为 null 表示这个平台/这套测试没接 WebDAV——那张卡片就不出现。
  final WebDavSettingsStore? _webDavStore;

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

  // ---------------------------------------------------------------- WebDAV

  WebDavSettings? _webDav;
  bool _webDavBusy = false;
  String? _webDavMessage;
  bool _webDavOk = false;

  /// 存着的那份连接信息，用来填表单。
  WebDavSettings? get webDavSettings => _webDav;
  bool get webDavAvailable => _webDavStore != null;
  bool get webDavBusy => _webDavBusy;

  /// 上一次「测试连接」的结果（成功或失败都是给人看的一句话）。
  String? get webDavMessage => _webDavMessage;

  /// 上一次测试是不是成功了。失败时 [webDavMessage] 里是原因。
  bool get webDavOk => _webDavOk;

  /// 当前目标是不是 WebDAV。界面靠它决定显示「Syncing to 坚果云」还是别的。
  bool get usingWebDav =>
      _controller.exportTargetDescription?.contains('WebDAV') ?? false;

  Future<void> _loadWebDav() async {
    final store = _webDavStore;
    if (store == null) return;
    _webDav = await store.read();
    notifyListeners();
  }

  /// 存下连接信息、切成 WebDAV 目标，然后**立刻测一次**。
  ///
  /// 一填完就知道通不通，比让人配好、等明早才发现传不上去强得多。
  ///
  /// ⚠️ 整个流程必须在 try/finally 里：这条链路上有**会抛的地方**
  /// （地址不合法时 `WebDavClient` 的构造函数就抛），而 `_webDavBusy`
  /// 一旦留在 true，界面上的表现是**看着像网络卡住**——按钮一直灰着、
  /// 一直写「正在测试连接…」，其实一个包都没发出去；而且这个 ViewModel
  /// 是 `main.dart` 里建一次活整个进程的，**退出页面再进来也复位不了**，
  /// 用户只能重启应用自救。2026-10-08 真机上就是这样卡住的。
  Future<void> saveAndUseWebDav(WebDavSettings settings) async {
    final store = _webDavStore;
    if (store == null) return;
    _webDavBusy = true;
    _webDavMessage = null;
    _webDavOk = false;
    _error = null;
    notifyListeners();

    try {
      await store.write(settings);
      _webDav = settings;
      await _controller.useWebDavTarget();
      await _testConnection(settings);
    } on WebDavException catch (e) {
      // 这是「地址看起来不对：…」那类**给人看的**话，原样显示即可
      _webDavOk = false;
      _webDavMessage = e.message;
    } catch (e) {
      _webDavOk = false;
      _webDavMessage = '$e';
    } finally {
      _webDavBusy = false;
      notifyListeners();
    }
  }

  Future<void> clearWebDav() async {
    await _webDavStore?.clear();
    _webDav = null;
    _webDavMessage = null;
    _webDavOk = false;
    notifyListeners();
  }

  Future<void> _testConnection(WebDavSettings settings) async {
    final client = WebDavClient(
      baseUrl: settings.baseUrl,
      username: settings.username,
      password: settings.password,
    );
    try {
      // 往根目录问一句「你在吗」：能通、认证也对，就够了。
      // 不建目录、不写文件——测试连接不该在人家网盘里留下东西。
      await client.listFileNames('');
      _webDavOk = true;
      _webDavMessage = null;
    } on WebDavException catch (e) {
      _webDavOk = false;
      _webDavMessage = e.message;
    } catch (e) {
      _webDavOk = false;
      _webDavMessage = '$e';
    } finally {
      client.close();
    }
  }

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
