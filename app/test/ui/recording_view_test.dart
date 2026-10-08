
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/pump_app.dart';
import 'package:sleep_secret/domain/models/recording_state.dart';
import 'package:sleep_secret/ui/features/recording/view_models/recording_view_model.dart';
import 'package:sleep_secret/ui/features/recording/views/recording_view.dart';

import '../helpers/fake_recording_controller.dart';

void main() {
  Widget wrap(RecordingViewModel vm) =>
      localizedApp(home: RecordingView(viewModel: vm));

  testWidgets('未录音时展示大按钮与使用说明', (tester) async {
    final vm = RecordingViewModel(controller: FakeRecordingController());
    await tester.pumpWidget(wrap(vm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('点一下开始'), findsOneWidget);
    expect(find.text('整夜录音、本地分析，早上给出报告'), findsOneWidget);
    expect(find.byKey(RecordingKeys.heroButton), findsOneWidget);
    expect(find.text('使用说明'), findsOneWidget);
    // 未录音时不该出现实时统计
    expect(find.text('实时分析'), findsNothing);
  });

  testWidgets('月亮在动——待机时也在缓慢呼吸', (tester) async {
    // 这条**故意开着 ticker**（localizedApp 默认关掉，否则 pumpAndSettle 会超时）。
    // 它守的是"动效没被人顺手删掉"——那是个很容易发生的回归：
    // 动画不影响任何别的断言，删了不会有测试红。
    final vm = RecordingViewModel(controller: FakeRecordingController());
    addTearDown(vm.dispose);

    await tester.pumpWidget(
        localizedApp(animate: true, home: RecordingView(viewModel: vm)));
    await tester.pump();

    expect(tester.hasRunningAnimations, isTrue,
        reason: '待机时月亮也该在呼吸——没有任何动画在跑，说明动效被删了');
  });

  testWidgets('点圆形按钮开始录音', (tester) async {
    final controller = FakeRecordingController();
    final vm = RecordingViewModel(controller: controller);
    await tester.pumpWidget(wrap(vm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(RecordingKeys.heroButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(controller.startCount, 1);
    expect(find.text('录音中'), findsOneWidget);
    // 原先这里还断言 `find.byIcon(Icons.stop)`——按钮换成自绘的月亮之后
    // 那个图标没了。状态本身已经由上面那行文案证明了，不必再断言长相:
    // 长相归截图看，测试管行为。
    expect(find.text('实时分析'), findsOneWidget);
    expect(find.textContaining('再次点击结束并保存'), findsOneWidget);
  });

  testWidgets('录音中展示实时统计与推理比例', (tester) async {
    final controller = FakeRecordingController();
    final vm = RecordingViewModel(controller: controller);
    await tester.pumpWidget(wrap(vm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    controller.push(const RecordingState(
      isRecording: true,
      elapsed: Duration(minutes: 42),
      windowsProcessed: 100,
      windowsInferred: 30,
      eventCount: 5,
      snoreEventCount: 2,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('100'), findsOneWidget); // 处理窗口
    expect(find.text('30'), findsOneWidget); // 送进模型
    expect(find.text('70'), findsOneWidget); // 跳过
    expect(find.text('30%'), findsOneWidget);
    expect(find.textContaining('鼾声 2 段'), findsOneWidget);
  });

  testWidgets('能量门控关着时，实时分析的副标题不说"安静片段会被跳过"', (tester) async {
    // 这一句错过一次：门控默认是关的（`AnalysisConfig.vadEnabled = false`），
    // 副标题却一直写"安静片段会被直接跳过，不送进模型"，而同一屏的电平卡
    // 正说着"所有声音都会送进模型分析"——两句话在同一个屏幕上互相打架。
    final controller = FakeRecordingController();
    final vm = RecordingViewModel(controller: controller);
    addTearDown(vm.dispose);
    await tester.pumpWidget(wrap(vm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    // vadThreshold 为 null 就是"门控关着"的信号，也是电平卡用的那个判据
    controller.push(const RecordingState(
      isRecording: true,
      windowsProcessed: 100,
      windowsInferred: 100,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('每一段都会送进模型，安静的也不跳过'), findsOneWidget);
    expect(find.text('安静片段会被直接跳过，不送进模型'), findsNothing,
        reason: '门控关着，没有任何片段被跳过');
    // 同一屏上的电平卡说的是同一件事——这两句必须同进同退
    expect(find.textContaining('所有声音都会送进模型分析'), findsOneWidget);
  });

  testWidgets('能量门控开着时，实时分析的副标题说安静片段会被跳过', (tester) async {
    final controller = FakeRecordingController();
    final vm = RecordingViewModel(controller: controller);
    addTearDown(vm.dispose);
    await tester.pumpWidget(wrap(vm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    controller.push(const RecordingState(
      isRecording: true,
      windowsProcessed: 100,
      windowsInferred: 30,
      vadThreshold: 0.01,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('安静片段会被直接跳过，不送进模型'), findsOneWidget);
    expect(find.text('每一段都会送进模型，安静的也不跳过'), findsNothing);
    expect(find.textContaining('红线是识别门槛'), findsOneWidget);
  });

  testWidgets('有推理失败时给出告警', (tester) async {
    final controller = FakeRecordingController();
    final vm = RecordingViewModel(controller: controller);
    await tester.pumpWidget(wrap(vm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    controller.push(const RecordingState(
      isRecording: true,
      windowsProcessed: 10,
      windowsInferred: 4,
      inferenceErrors: 3,
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.textContaining('3 个窗口推理失败'), findsOneWidget);
  });

  testWidgets('错误信息以横幅展示', (tester) async {
    final controller = FakeRecordingController();
    final vm = RecordingViewModel(controller: controller);
    await tester.pumpWidget(wrap(vm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    controller.push(
        const RecordingState(error: RecordingError(RecordingErrorKind.micDenied)));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(find.text('未获得麦克风权限，无法录音'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber), findsOneWidget);
  });

  testWidgets('再点一次结束录音', (tester) async {
    final controller = FakeRecordingController();
    final vm = RecordingViewModel(controller: controller);
    await tester.pumpWidget(wrap(vm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byKey(RecordingKeys.heroButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.byKey(RecordingKeys.heroButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(controller.stopCount, 1);
    expect(find.text('点一下开始'), findsOneWidget);
    expect(find.text('实时分析'), findsNothing);
  });

  group('时间格式化', () {
    test('formatDuration 输出 H:MM:SS', () {
      expect(formatDuration(Duration.zero), '0:00:00');
      expect(formatDuration(const Duration(seconds: 5)), '0:00:05');
      expect(formatDuration(const Duration(minutes: 7, seconds: 3)), '0:07:03');
      expect(
        formatDuration(const Duration(hours: 8, minutes: 15, seconds: 42)),
        '8:15:42',
      );
    });

    test('超过 24 小时不回绕', () {
      expect(formatDuration(const Duration(hours: 30)), '30:00:00');
    });

    test('formatClock 输出 MM:SS', () {
      expect(formatClock(0), '00:00');
      expect(formatClock(65), '01:05');
      expect(formatClock(3725), '62:05');
    });
  });
}
