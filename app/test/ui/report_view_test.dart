import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/sleep_score.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';
import 'package:sleep_secret/ui/core/theme.dart';
import 'package:sleep_secret/ui/core/widgets/score_gauge.dart';
import 'package:sleep_secret/ui/core/widgets/sound_timeline.dart';
import 'package:sleep_secret/ui/features/report/view_models/report_view_model.dart';
import 'package:sleep_secret/ui/features/report/views/report_view.dart';

import '../helpers/fake_clip_services.dart';

SoundEvent event({
  required SleepCategory label,
  required double start,
  required double duration,
  double confidence = 0.7,
  double snore = 0.0,
  String? clipPath,
}) =>
    SoundEvent(
      label: label,
      startSeconds: start,
      durationSeconds: duration,
      confidence: confidence,
      snoreProbability: snore,
      windowCount: (duration / 3).round(),
      clipPath: clipPath,
    );

RecordingSession buildSession({
  List<SoundEvent>? events,
  SessionStats? stats,
}) =>
    RecordingSession(
      id: 1,
      startedAt: DateTime(2026, 10, 6, 23, 30),
      endedAt: DateTime(2026, 10, 7, 7, 30),
      events: events ??
          [
            event(label: SleepCategory.snore, start: 3600, duration: 180, snore: 0.82),
            event(label: SleepCategory.snore, start: 9000, duration: 60, snore: 0.71),
            event(label: SleepCategory.cough, start: 7200, duration: 12),
            event(label: SleepCategory.vocal, start: 14400, duration: 24),
            event(label: SleepCategory.breathing, start: 2000, duration: 300),
          ],
      stats: stats ??
          const SessionStats(
            analyzedSeconds: 28800,
            windowsTotal: 9600,
            windowsInferred: 3200,
            windowsVadSkipped: 6000,
            windowsLowConfidence: 2900,
            eventCount: 5,
            snoreEventCount: 2,
            snoreSeconds: 240,
            categoryDistribution: {},
          ),
    );

void main() {
  late FakeAudioClipStore clipStore;
  late FakeEventPlayer player;

  setUp(() {
    clipStore = FakeAudioClipStore();
    player = FakeEventPlayer();
  });

  ReportViewModel buildVm(RecordingSession session) => ReportViewModel(
        session: session,
        clipStore: clipStore,
        player: player,
      );

  Widget wrap(RecordingSession session) => MaterialApp(
        theme: buildAppTheme(),
        home: ReportView(viewModel: buildVm(session)),
      );

  /// 报告页很长，默认 800x600 的测试视口装不下；ListView 只构建可见区域，
  /// 屏幕外的分区根本不在 widget 树里，断言会找不到。把视口调高即可。
  Future<void> pumpReport(WidgetTester tester, RecordingSession session) async {
    tester.view.physicalSize = const Size(900, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(session));
    await tester.pumpAndSettle();
  }

  testWidgets('头部展示鼾声指数与关键数字', (tester) async {
    await pumpReport(tester, buildSession());

    // 鼾声指数 = 240 / 28800 * 100 = 0.83%
    expect(find.byType(ScoreGauge), findsOneWidget);
    expect(find.text('0.8'), findsOneWidget);
    expect(find.text('鼾声指数'), findsOneWidget);
    expect(find.text('鼾声总时长'), findsOneWidget);
    expect(find.text('4m'), findsWidgets);
    expect(find.text('声音事件'), findsOneWidget);
  });

  testWidgets('渲染整夜声音时间线', (tester) async {
    await pumpReport(tester, buildSession());

    expect(find.text('整夜声音'), findsOneWidget);
    expect(find.byType(SoundTimeline), findsOneWidget);
    // 出现的大类应当都有图例
    expect(find.text('鼾声'), findsWidgets);
    expect(find.text('其他声音'), findsWidgets);
    expect(find.text('呼吸/环境'), findsWidgets);
  });

  testWidgets('类别分布按总时长排序并直接标注', (tester) async {
    await pumpReport(tester, buildSession());

    expect(find.text('类别分布'), findsOneWidget);
    // 呼吸声 300s 最长，鼾声 240s 次之。
    // 类别名在分布图和下方事件明细里都会出现，所以是多个。
    expect(find.text('呼吸声'), findsWidgets);
    expect(find.text('5m'), findsWidgets); // 300s
  });

  testWidgets('端侧分析卡片展示推理比例', (tester) async {
    await pumpReport(tester, buildSession());

    expect(find.text('端侧分析'), findsOneWidget);
    expect(find.text('9600'), findsOneWidget); // 处理窗口
    expect(find.text('3200'), findsOneWidget); // 送进模型
    expect(find.text('6000'), findsOneWidget); // 跳过
    // 33% 在两处出现：指标块的小字提示，和进度条右侧的标签
    expect(find.text('33%'), findsWidgets); // 3200/9600
    expect(find.textContaining('2900 个窗口模型没把握'), findsOneWidget);
  });

  testWidgets('事件明细列出每个事件', (tester) async {
    await pumpReport(tester, buildSession());

    expect(find.text('事件明细'), findsOneWidget);
    expect(find.text('共 5 条'), findsOneWidget);
    // 睡眠开始 23:30，事件在 3600s 后 -> 00:30
    expect(find.text('00:30'), findsOneWidget);
  });

  testWidgets('没有事件时给出空态而不是崩掉', (tester) async {
    await pumpReport(tester, buildSession(
      events: const [],
      stats: const SessionStats.empty(),
    ));

    expect(find.text('这一晚没有检出声音事件'), findsOneWidget);
    expect(find.text('没有检出声音事件'), findsOneWidget);
    expect(find.byType(SoundTimeline), findsOneWidget);
  });

  group('事件片段试听', () {
    RecordingSession withClips({String? missing}) {
      final s = buildSession(events: [
        event(
          label: SleepCategory.snore,
          start: 100,
          duration: 30,
          snore: 0.8,
          clipPath: 'sess/100000.wav',
        ),
        event(
          label: SleepCategory.snore,
          start: 200,
          duration: 20,
          snore: 0.7,
          clipPath: 'sess/200000.wav',
        ),
        // 没有片段的事件（比如老记录，或用户关掉了片段开关）
        event(label: SleepCategory.cough, start: 300, duration: 12),
      ]);
      clipStore.saved['sess/100000.wav'] = Float32List(10);
      clipStore.saved['sess/200000.wav'] = Float32List(10);
      if (missing != null) {
        clipStore.missingFiles.add(missing);
        clipStore.saved.remove(missing);
      }
      return s;
    }

    testWidgets('只有带片段的事件才显示播放按钮', (tester) async {
      await pumpReport(tester, withClips());

      // 3 个事件里 2 个有片段
      expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(2));
      expect(find.textContaining('其中 2 条可以试听'), findsOneWidget);
    });

    testWidgets('没有片段时不显示播放按钮，也不说能试听', (tester) async {
      await pumpReport(tester, buildSession());

      expect(find.byIcon(Icons.play_circle_outline), findsNothing);
      expect(find.textContaining('可以试听'), findsNothing);
    });

    testWidgets('点击播放会解析路径并交给播放器', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();

      expect(player.playCount, 1);
      expect(player.currentPath, '/fake/clips/sess/100000.wav');
    });

    testWidgets('播放中按钮变成停止', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    });

    testWidgets('点下去立刻进入播放态，不会一直转圈', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();

      // just_audio 的 play() 要等播放结束才 resolve。实现里一旦 await 它，
      // 「正在播放」就永远设不上，界面会一直停在加载态——这个断言就是防它。
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    });

    testWidgets('再点同一个事件会停止播放', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.stop_circle_outlined));
      await tester.pumpAndSettle();

      expect(player.stopCount, greaterThanOrEqualTo(1));
      expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(2));
    });

    testWidgets('点另一条会切过去而不是叠加播放', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.play_circle_outline).last);
      await tester.pumpAndSettle();

      expect(player.playCount, 2);
      expect(player.currentPath, '/fake/clips/sess/200000.wav');
      // 同一时刻只有一条在播
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);
    });

    testWidgets('播放自然结束后按钮回到可播放态', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.stop_circle_outlined), findsOneWidget);

      player.finishNaturally();
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
      expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(2));
    });

    testWidgets('文件已丢失时明确提示，而不是点了没反应', (tester) async {
      await pumpReport(tester, withClips(missing: 'sess/100000.wav'));

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();

      expect(find.text('这段音频已经不在了'), findsOneWidget);
      expect(player.playCount, 0, reason: '拿不到路径就不该交给播放器');
    });
  });

  group('睡眠声音评分', () {
    testWidgets('仪表显示的是评分，且方向是"越高越好"', (tester) async {
      final session = buildSession();
      await pumpReport(tester, session);

      final gauge = tester.widget<ScoreGauge>(find.byType(ScoreGauge));
      final expected = scoreSession(session)!;

      expect(gauge.value, expected.total.toDouble());
      expect(gauge.higherIsBetter, isTrue,
          reason: '鼾声指数越高越差，评分越高越好——方向反了颜色就骗人了');
      expect(find.text('睡眠声音评分'), findsOneWidget);
    });

    testWidgets('展示逐项扣分，用户能自己验算', (tester) async {
      final session = buildSession();
      await pumpReport(tester, session);

      expect(find.text('评分构成'), findsOneWidget);
      expect(find.text('满分 100，逐项扣分'), findsOneWidget);
      for (final label in ['鼾声占比', '鼾声连续性', '干扰频次', '环境噪音']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      // 验算行
      expect(find.text('100 分逐项扣完'), findsOneWidget);
      expect(find.text('= ${scoreSession(session)!.total}'), findsOneWidget);
    });

    testWidgets('原样展示"这不是睡眠质量"的说明', (tester) async {
      await pumpReport(tester, buildSession());

      expect(find.textContaining('不反映你的睡眠分期'), findsOneWidget);
      expect(find.textContaining('整夜安静但没睡好的人'), findsOneWidget);
    });

    testWidgets('录音太短时不给分，并说明原因', (tester) async {
      final short = buildSession(
        stats: const SessionStats(
          analyzedSeconds: 600, // 10 分钟
          windowsTotal: 200,
          windowsInferred: 0,
          windowsVadSkipped: 200,
          windowsLowConfidence: 0,
          eventCount: 0,
          snoreEventCount: 0,
          snoreSeconds: 0,
          categoryDistribution: {},
        ),
      );
      await pumpReport(tester, short);

      expect(scoreSession(short), isNull);
      expect(find.textContaining('不给出评分'), findsOneWidget);
      // 退回显示鼾声指数，并注明为什么
      expect(find.text('鼾声指数'), findsWidgets);
      expect(find.textContaining('录音太短'), findsOneWidget);
    });

    testWidgets('安静的一夜拿到高分', (tester) async {
      final quiet = buildSession(
        events: const [],
        stats: const SessionStats(
          analyzedSeconds: 28800,
          windowsTotal: 9600,
          windowsInferred: 0,
          windowsVadSkipped: 9600,
          windowsLowConfidence: 0,
          eventCount: 0,
          snoreEventCount: 0,
          snoreSeconds: 0,
          categoryDistribution: {},
        ),
      );
      await pumpReport(tester, quiet);

      final gauge = tester.widget<ScoreGauge>(find.byType(ScoreGauge));
      expect(gauge.value, 100);
      expect(find.text('很安静'), findsOneWidget);
    });
  });

  group('formatSpan', () {
    test('小于一小时只显示分钟', () {
      expect(formatSpan(0), '0m');
      expect(formatSpan(90), '1m');
      expect(formatSpan(300), '5m');
    });

    test('超过一小时显示 h 和 m', () {
      expect(formatSpan(3600), '1h 0m');
      expect(formatSpan(5460), '1h 31m');
      expect(formatSpan(28800), '8h 0m');
    });
  });
}
