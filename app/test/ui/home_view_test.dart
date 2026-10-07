import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

  testWidgets('关于页的片段开关能改状态', (tester) async {
    await tester.pumpWidget(build());
    await tester.pumpAndSettle();
    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();

    expect(find.text('保留鼾声片段'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(controller.clipRecording, isFalse);
    expect(find.text('不保留任何音频'), findsOneWidget);
  });
}
