import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/pump_app.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/ui_message.dart';
import 'package:sleep_secret/data/repositories/archive_repository.dart';
import 'package:sleep_secret/data/services/webdav_client.dart';
import 'package:sleep_secret/data/services/webdav_settings.dart';
import 'package:sleep_secret/domain/repositories/archive_controller.dart';
import 'package:sleep_secret/ui/features/archive/view_models/archive_view_model.dart';
import 'package:sleep_secret/ui/features/archive/views/archive_view.dart';

/// 数据导出页的界面契约。
///
/// ## 和 archive_service_test 的分工
///
/// 那边问的是「**搬家对不对**」——JSON 编解码、片段复制、去重，
/// 用的是内存目标，一路跑到真目录。
///
/// 这边问的是另一件事：「**用户点了按钮，页面有没有接上、有没有如实显示结果**」。
/// 两边坏起来的样子完全不同（一边是数据错，一边是按钮没反应或数字对不上），
/// 混着测会互相掩盖。
///
/// ⚠️ 这条测试是补出来的。在此之前整页都没被驱动过——
/// 「页面能不能用」是靠 PowerShell 模拟鼠标点像素验的：坐标、窗口焦点、
/// 谁盖在谁上面，每一环都在骗人，点空了也看不出来（截图用的是 PrintWindow，
/// 不受遮挡影响，所以截图**无法**证明点击落到了哪儿）。
class FakeArchiveController implements ArchiveController {
  final _changes = StreamController<void>.broadcast();

  String? _description;
  bool _usable = true;
  bool _manualBusy = false;
  ArchiveOutcome? _last;
  bool _lastWasExport = true;

  /// 下次操作返回什么。默认「导出了 1 晚」。
  ArchiveOutcome nextOutcome = const ArchiveOutcome(sessions: 1);

  /// 让下一次操作抛这个错（验证错误会显示出来，而不是把页面搞崩）。
  Object? failNext;

  int loadCalls = 0;
  int chooseCalls = 0;
  int webDavCalls = 0;
  int clearCalls = 0;
  int exportCalls = 0;
  int importCalls = 0;
  int exportSessionCalls = 0;

  @override
  Future<void> load() async {
    loadCalls++;
    _emit();
  }

  @override
  String? get exportTargetDescription => _description;

  @override
  bool get exportTargetUsable => _usable;

  @override
  bool get busy => _manualBusy;

  @override
  ArchiveOutcome? get lastOutcome => _last;

  @override
  bool get lastWasExport => _lastWasExport;

  @override
  Stream<void> get changes => _changes.stream;

  void _emit() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// 把目录配成「配好了」的状态，用来单独验按钮的可用性。
  void setTarget(String description, {bool usable = true}) {
    _description = description;
    _usable = usable;
    _emit();
  }

  void setBusy(bool value) {
    _manualBusy = value;
    _emit();
  }

  @override
  Future<bool> chooseExportTarget() async {
    chooseCalls++;
    _description = 'C:/同步目录/睡眠';
    _usable = true;
    _emit();
    return true;
  }

  @override
  Future<void> useWebDavTarget() async {
    webDavCalls++;
    _description = '坚果云 / WebDAV · dav.jianguoyun.com/sleep-secret';
    _usable = true;
    _last = null;
  }

  @override
  Future<void> clearExportTarget() async {
    clearCalls++;
    _description = null;
    _usable = false;
    _last = null;
    _emit();
  }

  @override
  Future<ArchiveOutcome> exportAll() {
    exportCalls++;
    return _finish(isExport: true);
  }

  @override
  Future<ArchiveOutcome> exportSession(RecordingSession session) {
    exportSessionCalls++;
    return _finish(isExport: true);
  }

  @override
  Future<ArchiveOutcome> importAll() {
    importCalls++;
    return _finish(isExport: false);
  }

  Future<ArchiveOutcome> _finish({required bool isExport}) async {
    final f = failNext;
    if (f != null) {
      failNext = null;
      throw f;
    }
    _lastWasExport = isExport;
    _last = nextOutcome;
    _emit();
    return _last!;
  }

  @override
  void dispose() => _changes.close();
}

/// 切换 WebDAV 目标时抛错——真机上就是「地址那一栏还是空的」那一次。
class _FailingWebDavController extends FakeArchiveController {
  @override
  Future<void> useWebDavTarget() async {
    throw WebDavException('地址看起来不对：（应当形如 https://dav.jianguoyun.com/dav/）');
  }
}

class _MemoryWebDavStore implements WebDavSettingsStore {
  WebDavSettings? stored;

  @override
  Future<WebDavSettings?> read() async => stored;

  @override
  Future<void> write(WebDavSettings settings) async => stored = settings;

  @override
  Future<void> clear() async => stored = null;
}

void main() {
  late FakeArchiveController controller;

  setUp(() => controller = FakeArchiveController());
  tearDown(() => controller.dispose());

  /// 高度给足，让整页都建出来——ListView 只建可视区域，
  /// 下面那几张卡片不撑开就根本不在树里。
  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(localizedApp(
      home: ArchiveView(viewModel: ArchiveViewModel(controller: controller)),
    ));
    await tester.pumpAndSettle();
  }

  ButtonStyleButton buttonNamed(WidgetTester tester, String label) =>
      tester.widget<ButtonStyleButton>(find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ));

  bool enabled(WidgetTester tester, String label) =>
      buttonNamed(tester, label).onPressed != null;

  group('一打开页面', () {
    testWidgets('主动读一次配置——不能等用户先点一下', (tester) async {
      await pumpPage(tester);
      expect(controller.loadCalls, greaterThan(0),
          reason: '界面一打开就要显示当前配的目录，靠的是构造时那次 load');
    });

    testWidgets('没配过目录 —— 说清楚，并把两个按钮都禁掉', (tester) async {
      await pumpPage(tester);

      expect(find.text('还没选目录'), findsOneWidget);
      expect(find.text('选择目录'), findsOneWidget,
          reason: '没配过时按钮写的是「选择目录」，不是「换一个」');

      expect(enabled(tester, '导出全部'), isFalse);
      expect(enabled(tester, '从目录导入'), isFalse);
    });
  });

  group('目录配置', () {
    testWidgets('配好的目录显示出来，按钮跟着可用', (tester) async {
      controller.setTarget('C:/Users/me/OneDrive/睡眠');
      await pumpPage(tester);

      expect(find.text('C:/Users/me/OneDrive/睡眠'), findsOneWidget);
      expect(find.text('换一个'), findsOneWidget);
      expect(find.text('取消配置'), findsOneWidget);
      expect(enabled(tester, '导出全部'), isTrue);
      expect(enabled(tester, '从目录导入'), isTrue);
    });

    testWidgets('目录失效 —— 明确警告，并且不许点', (tester) async {
      // 网盘目录被删、SAF 授权被系统收回，都会走到这儿。
      // 关键是**按钮要禁掉**：让用户点下去再报错，等于把配置问题
      // 伪装成操作失败。而那两个按钮点下去都不便宜（会搬整晚的音频）。
      controller.setTarget('C:/Users/me/OneDrive/睡眠', usable: false);
      await pumpPage(tester);

      expect(find.textContaining('这个目录现在用不了'), findsOneWidget);
      expect(enabled(tester, '导出全部'), isFalse);
      expect(enabled(tester, '从目录导入'), isFalse);
    });

    testWidgets('点「选择目录」会真的去弹选择器', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('选择目录'));
      await tester.pumpAndSettle();

      expect(controller.chooseCalls, 1);
      expect(find.text('C:/同步目录/睡眠'), findsOneWidget);
      expect(enabled(tester, '导出全部'), isTrue, reason: '配好了就该能点');
    });

    testWidgets('「取消配置」把目录清掉，按钮退回禁用', (tester) async {
      controller.setTarget('C:/Users/me/OneDrive/睡眠');
      await pumpPage(tester);

      await tester.tap(find.text('取消配置'));
      await tester.pumpAndSettle();

      expect(controller.clearCalls, 1);
      expect(find.text('还没选目录'), findsOneWidget);
      expect(enabled(tester, '导出全部'), isFalse);
    });
  });

  group('导出 / 导入', () {
    setUp(() => controller.setTarget('C:/同步目录/睡眠'));

    testWidgets('点「导出全部」走的是 exportAll', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('导出全部'));
      await tester.pumpAndSettle();

      expect(controller.exportCalls, 1);
      expect(controller.importCalls, 0, reason: '别把导入也一起调了');
    });

    testWidgets('点「从目录导入」走的是 importAll', (tester) async {
      await pumpPage(tester);

      await tester.tap(find.text('从目录导入'));
      await tester.pumpAndSettle();

      expect(controller.importCalls, 1);
      expect(controller.exportCalls, 0);
    });

    testWidgets('导出的数字如实显示，包括片段数', (tester) async {
      controller.nextOutcome = const ArchiveOutcome(
        sessions: 3,
        clips: 12,
        clipsMissing: 2,
      );
      await pumpPage(tester);

      await tester.tap(find.text('导出全部'));
      await tester.pumpAndSettle();

      // 三个数字都得出现——界面上少报一个，用户就以为自己备份全了
      expect(find.textContaining('上次导出：导出 3 晚'), findsOneWidget);
      expect(find.textContaining('片段 12 个'), findsOneWidget);
      expect(find.textContaining('2 个片段没找到'), findsOneWidget);
    });

    testWidgets('导入时说「导入」不说「导出」', (tester) async {
      controller.nextOutcome = const ArchiveOutcome(sessions: 1, skipped: 4);
      await pumpPage(tester);

      await tester.tap(find.text('从目录导入'));
      await tester.pumpAndSettle();

      expect(find.textContaining('上次导入：导入 1 晚'), findsOneWidget);
      expect(find.textContaining('跳过 4 晚'), findsOneWidget);
    });

    testWidgets('没有片段时不留「片段 0 个」这种噪音', (tester) async {
      controller.nextOutcome = const ArchiveOutcome(sessions: 1);
      await pumpPage(tester);

      await tester.tap(find.text('导出全部'));
      await tester.pumpAndSettle();

      // 精确比整行——下面「导出的内容」那张卡片里也有「片段」二字，
      // 用 textContaining 会误判成"这一行没被清干净"
      expect(find.text('上次导出：导出 1 晚'), findsOneWidget);
    });

    testWidgets('读不了的文件逐条列出来，用户才知道是哪一晚', (tester) async {
      controller.nextOutcome = const ArchiveOutcome(
        sessions: 1,
        problems: [
          UiMessage(UiMessageKind.archiveUnreadableFile,
              'sessions/1791.json：不是本应用导出的文件'),
        ],
      );
      await pumpPage(tester);

      await tester.tap(find.text('导出全部'));
      await tester.pumpAndSettle();

      expect(find.textContaining('不是本应用导出的文件'), findsOneWidget);
    });

    testWidgets('操作失败 —— 显示错误，页面不崩', (tester) async {
      // 仓库现在抛的是带类型的 ArchiveException，视图模型按类型分支出话术
      controller.failNext = ArchiveException(UiMessageKind.archiveNoTarget);
      await pumpPage(tester);

      await tester.tap(find.text('导出全部'));
      await tester.pumpAndSettle();

      expect(find.text('还没有配置导出目录'), findsOneWidget);
      expect(tester.takeException(), isNull,
          reason: '异常应当在 ViewModel 里被接住，不能冒泡到界面');
    });

    testWidgets('正在搬的时候按钮全部禁用，并转圈', (tester) async {
      await pumpPage(tester);

      controller.setBusy(true);
      // 不能用 pumpAndSettle：转圈是常驻动画，永远等不到"静止"。
      // 两帧：第一帧让 changes 流的事件送达并触发 notifyListeners，
      // 第二帧才把界面重建成禁用态。
      await tester.pump();
      await tester.pump();

      expect(enabled(tester, '导出全部'), isFalse);
      expect(enabled(tester, '从目录导入'), isFalse);
      expect(enabled(tester, '换一个'), isFalse,
          reason: '忙的时候不该还能改目录');
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });
  });

  group('保存并测试连接', () {
    /// 2026-10-08 在真机上撞到的那个 bug。
    ///
    /// 地址那一栏还是空的时候点「保存并测试」：`WebDavClient` 的构造函数
    /// 会因为地址不合法抛异常，而当时 `saveAndUseWebDav` **没有
    /// try/finally** —— 异常直接漏出去，`_webDavBusy` 就永远停在 true。
    ///
    /// 表现是**看起来像网络卡住**：按钮一直灰着、页面一直写着
    /// 「正在测试连接…」，其实一个包都没发出去。
    ///
    /// 更要命的是 `ArchiveViewModel` 在 `main.dart` 里建一次、活整个进程，
    /// **退出这一页再进来也复位不了**——用户唯一的自救手段是重启应用。
    testWidgets('目标切不过去时：说清楚原因，并且让按钮回来', (tester) async {
      final failing = _FailingWebDavController();
      addTearDown(failing.dispose);
      final vm = ArchiveViewModel(
        controller: failing,
        webDavSettings: _MemoryWebDavStore(),
      );

      tester.view.physicalSize = const Size(900, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(localizedApp(home: ArchiveView(viewModel: vm)));
      await tester.pumpAndSettle();

      await vm.saveAndUseWebDav(const WebDavSettings(
        baseUrl: '',
        username: 'u',
        password: 'p',
      ));
      await tester.pumpAndSettle();

      expect(vm.webDavBusy, isFalse,
          reason: '修复前这里永远是 true —— 界面只能靠重启应用恢复');
      expect(vm.webDavMessage, isNotNull, reason: '失败原因不能被吞掉');
      expect(vm.webDavMessage, contains('地址'));
      expect(enabled(tester, '保存并测试'), isTrue,
          reason: '按钮得能再点，否则用户没有任何自救手段');
      expect(find.text('正在测试连接…'), findsNothing);
    });
  });
}
