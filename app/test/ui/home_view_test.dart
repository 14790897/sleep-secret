import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../helpers/pump_app.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/ui/features/home/views/home_view.dart';
import 'package:sleep_secret/ui/features/recording/view_models/recording_view_model.dart';
import 'package:sleep_secret/ui/features/report/view_models/report_view_model.dart';

import '../helpers/fake_clip_services.dart';
import '../helpers/fake_recording_controller.dart';
import '../helpers/fake_services.dart';

RecordingSession night({
  required int id,
  required DateTime startedAt,
  double snoreSeconds = 240,
  int snoreCount = 3,
}) =>
    RecordingSession(
      id: id,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(hours: 8)),
      events: const [],
      stats: SessionStats(
        analyzedSeconds: 28000,
        windowsTotal: 9333,
        windowsInferred: 3500,
        windowsVadSkipped: 5833,
        windowsLowConfidence: 3100,
        eventCount: 10,
        snoreEventCount: snoreCount,
        snoreSeconds: snoreSeconds,
        categoryDistribution: const {},
      ),
    );

void main() {
  late FakeRecordingController controller;
  late RecordingViewModel recordingVm;

  setUp(() {
    controller = FakeRecordingController();
    recordingVm = RecordingViewModel(controller: controller);
  });

  tearDown(() => recordingVm.dispose());

  /// 报告列表页面比较长（趋势卡 + 历史列表），默认 800x600 视口装不下；
  /// ListView 只构建可见区域，屏幕外的卡片不在 widget 树里。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Widget build() => localizedApp(
        home: HomeView(
          localeController: FakeLocaleController(),
          recordingViewModel: recordingVm,
          reportViewModelFactory: (session) => ReportViewModel(
            session: session,
            clipStore: FakeAudioClipStore(),
            player: FakeEventPlayer(),
          ),
        ),
      );

  testWidgets(
      '首次构建不抛异常——initState 里不能在 build 阶段 notifyListeners',
      (tester) async {
    // 这个断言是防回归的。HomeView 用 IndexedStack 一次构建三个页面，
    // 报告页的 initState 会在 App 冷启动时跑到；如果它直接调 loadSessions()，
    // 就会在 build 期间触发 notifyListeners，Flutter 会断言失败。
    //
    // 之前的 widget 测试只单独测了 RecordingView，没测过 HomeView，
    // 所以这个 bug 一路漏到了真机 e2e 才被抓到。
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('三个页签都能切换', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    expect(find.text('点一下开始'), findsOneWidget);

    await tester.tap(find.text('报告'));
    await tester.pumpAndSettle();
    expect(find.text('睡眠报告'), findsWidgets);

    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(find.text('这个应用做什么'), findsOneWidget);

    await tester.tap(find.text('睡眠'));
    await tester.pumpAndSettle();
    expect(find.text('点一下开始'), findsOneWidget);
  });

  testWidgets('报告页签在启动后就拉过一次数据', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    // 首帧之后才拉，但确实拉了
    expect(controller.listCount, greaterThanOrEqualTo(1));
  });

  testWidgets('没有记录时报告页给空态', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();

    await tester.tap(find.text('报告'));
    await tester.pumpAndSettle();

    expect(find.text('还没有睡眠报告'), findsOneWidget);
  });

  testWidgets('有记录时列出历史，并展示趋势卡', (tester) async {
    useTallViewport(tester);
    controller.sessions = [
      night(id: 1, startedAt: DateTime(2026, 10, 6, 23), snoreSeconds: 240),
      night(id: 2, startedAt: DateTime(2026, 10, 5, 23), snoreSeconds: 600),
    ];

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    await tester.tap(find.text('报告'));
    await tester.pumpAndSettle();

    expect(find.text('历史记录'), findsOneWidget);
    expect(find.textContaining('10月6日'), findsOneWidget);
    expect(find.textContaining('10月5日'), findsOneWidget);
    // 两晚以上要出趋势图
    expect(find.text('鼾声指数趋势'), findsOneWidget);
  });

  /// 打开「关于」页，并把视口调高。
  ///
  /// ⚠️ 视口一定要调：关于页很长，而 `ListView` **只构建可见区域**——
  /// 默认 800x600 下底部那行版本号根本不在树里，
  /// 于是「找不到」和「没渲染」分不开，断言就变成了在测浏览器而不是测代码。
  Future<void> pumpAbout(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 3400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
  }

  testWidgets('拿不到版本号时这一行不出现，也不报错', (tester) async {
    // ⚠️ **这条必须跑在上面那条前面。** `PackageInfo` 的 mock 是**静态**的，
    // 一旦被 setMockInitialValues 设过就留在那里，没法清掉——
    // 放到后面的话它测的就是被 mock 过的路径，等于没测。
    //
    // 平台通道失败在真机上不是不可能（定制 ROM）。版本号是补充信息，
    // 不是这一页的内容——为它显示一行错误只会让人以为应用坏了。
    await pumpAbout(tester);

    expect(find.byKey(HomeKeys.version), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('关于页底部显示版本号，而且是**系统里那个**', (tester) async {
    // 真机/真桌面上这一行来自 PackageInfo（读的是系统里已经装好的那个包），
    // 测试环境没有平台通道，所以喂一组假的。
    //
    // **这正是要测的路径**：显示的是系统给的那个版本，不是代码里某个常量。
    // 写死常量的话发版时一定会漂——semantic-release 是自动改 pubspec.yaml 的，
    // 人根本不经过那行代码。
    PackageInfo.setMockInitialValues(
      appName: 'Sleep Secret',
      packageName: 'com.sleepsecret.sleep_secret',
      version: '9.9.9',
      buildNumber: '99999',
      buildSignature: '',
    );

    await pumpAbout(tester);

    expect(find.byKey(HomeKeys.version), findsOneWidget);
    expect(find.text('版本 9.9.9 · build 99999'), findsOneWidget,
        reason: '显示的必须是 PackageInfo 给的那一版');
  });

  testWidgets('关于页的片段开关能改状态', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();

    expect(find.text('保留鼾声与呼吸信号片段'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(controller.clipRecording, isFalse);
    expect(find.text('不保留任何音频'), findsOneWidget);
  });
}
