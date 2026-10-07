
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
    expect(find.byIcon(Icons.mic), findsOneWidget);
    expect(find.text('使用说明'), findsOneWidget);
    // 未录音时不该出现实时统计
    expect(find.text('实时分析'), findsNothing);
  });

  testWidgets('点圆形按钮开始录音', (tester) async {
    final controller = FakeRecordingController();
    final vm = RecordingViewModel(controller: controller);
    await tester.pumpWidget(wrap(vm));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(controller.startCount, 1);
    expect(find.text('录音中'), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
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

    controller.push(const RecordingState(error: '未获得麦克风权限，无法录音'));
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

    await tester.tap(find.byIcon(Icons.mic));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tap(find.byIcon(Icons.stop));
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
