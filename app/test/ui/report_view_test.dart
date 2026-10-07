import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/sleep_score.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';
import 'package:sleep_secret/ui/core/theme.dart';
import 'package:sleep_secret/ui/core/widgets/score_gauge.dart';
import 'package:sleep_secret/ui/core/widgets/section_card.dart';
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

  /// 把查找限定在某一张开区里。
  ///
  /// 自从「鼾声录音」卡出现之后，同一个片段会在**两处**各有一行——
  /// 全局 `find.byIcon(play)` 会数出双份，断言就分不清是"多了一行"
  /// 还是"卡片重复渲染了"。凡是有数量含义的断言都该说清楚在哪儿数。
  Finder inSection(String title, Finder matching) => find.descendant(
        of: find.ancestor(
          of: find.text(title),
          matching: find.byType(SectionCard),
        ),
        matching: matching,
      );

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
    // 去掉置信度门控之后，这些窗口**也会产生事件**，所以文案必须说清楚，
    // 不能再写"不计入事件"
    expect(find.textContaining('2900 个窗口模型把握不大'), findsOneWidget);
    expect(find.textContaining('照常计入事件'), findsOneWidget);
  });

  testWidgets('事件明细列出每个事件', (tester) async {
    await pumpReport(tester, buildSession());

    expect(find.text('事件明细'), findsOneWidget);
    expect(find.text('共 5 条'), findsOneWidget);
    // 睡眠开始 23:30，事件在 3600s 后 -> 00:30
    expect(find.text('00:30'), findsOneWidget);
  });

  testWidgets('事件明细露出把握程度，而不是只写类别', (tester) async {
    // 去掉置信度门控之后，「0.93 的鼾声」和「0.21 的鼾声」会同时出现在列表里。
    // 不显示把握程度的话两者长得一模一样——而后者其实是模型在两个
    // 几乎相同的分数里挑了一个。这正是"把门槛换成展示"的核心。
    //
    // 标记线（0.25）刻意等于旧门槛，所以**被标出来的条目，
    // 正好就是旧门槛当年会直接丢掉的那些**——一眼能看出它藏掉了什么。
    await pumpReport(tester, buildSession(events: [
      event(
          label: SleepCategory.snore,
          start: 3600,
          duration: 180,
          confidence: 0.93,
          snore: 0.93),
      event(
          label: SleepCategory.snore,
          start: 9000,
          duration: 60,
          confidence: 0.21,
          snore: 0.21),
    ]));

    expect(find.text('93%'), findsOneWidget);
    expect(find.text('21%'), findsOneWidget);

    // 把握不大的那个要用警示色标出来，不能和确定的长得一样
    final low = tester.widget<Text>(find.text('21%'));
    final high = tester.widget<Text>(find.text('93%'));
    expect(low.style?.color, isNot(high.style?.color),
        reason: '「没把握」和「确定」必须在视觉上分得开，'
            '否则用户没法判断哪条能信');
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
      expect(inSection('事件明细', find.byIcon(Icons.play_circle_outline)),
          findsNWidgets(2));
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

      expect(inSection('事件明细', find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);
    });

    testWidgets('点下去立刻进入播放态，不会一直转圈', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();

      // just_audio 的 play() 要等播放结束才 resolve。实现里一旦 await 它，
      // 「正在播放」就永远设不上，界面会一直停在加载态——这个断言就是防它。
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(inSection('事件明细', find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);
    });

    testWidgets('再点同一个事件会停止播放', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(inSection('事件明细', find.byIcon(Icons.stop_circle_outlined)));
      await tester.pumpAndSettle();

      expect(player.stopCount, greaterThanOrEqualTo(1));
      expect(inSection('事件明细', find.byIcon(Icons.play_circle_outline)),
          findsNWidgets(2));
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
      expect(inSection('事件明细', find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);
    });

    testWidgets('播放自然结束后按钮回到可播放态', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();
      expect(inSection('事件明细', find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);

      player.finishNaturally();
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
      expect(inSection('事件明细', find.byIcon(Icons.play_circle_outline)),
          findsNWidgets(2));
    });

    testWidgets('文件已丢失时明确提示，而不是点了没反应', (tester) async {
      await pumpReport(tester, withClips(missing: 'sess/100000.wav'));

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();

      // 两张卡都会显示这条——播放状态是共用的，点播放的地方不能"没反应"
      expect(find.text('这段音频已经不在了'), findsNWidgets(2));
      expect(player.playCount, 0, reason: '拿不到路径就不该交给播放器');
    });
  });

  group('鼾声录音卡', () {
    /// 一晚：2 段带录音的鼾声，夹在呼吸声、咳嗽、环境噪音中间。
    /// 这就是真实的样子——81 条事件里只有 9 条有音频。
    RecordingSession mixed() {
      clipStore.saved['sess/100000.wav'] = Float32List(10);
      clipStore.saved['sess/200000.wav'] = Float32List(10);
      return buildSession(events: [
        event(
            label: SleepCategory.snore,
            start: 100,
            duration: 30,
            snore: 0.8,
            clipPath: 'sess/100000.wav'),
        event(label: SleepCategory.breathing, start: 150, duration: 300),
        event(label: SleepCategory.cough, start: 300, duration: 12),
        event(
            label: SleepCategory.snore,
            start: 200,
            duration: 20,
            snore: 0.7,
            clipPath: 'sess/200000.wav'),
        event(label: SleepCategory.ambient, start: 500, duration: 40),
      ]);
    }

    testWidgets('带录音的片段集中在一张卡里，没有录音的类别不在里面', (tester) async {
      await pumpReport(tester, mixed());

      expect(inSection('鼾声录音', find.byIcon(Icons.play_circle_outline)),
          findsNWidgets(2),
          reason: '呼吸声、咳嗽、环境噪音都不该出现——它们没有录音，'
              '而这张卡存在的理由就是播放键夹在它们中间找不到');
    });

    testWidgets('段数和总时长直接写出来，不用自己数', (tester) async {
      await pumpReport(tester, mixed());

      // 30 + 20 = 50 秒。整句精确比——「共 2 段」这几个字在
      // 「鼾声段时长」卡里也有，containing 会撞上。
      expect(find.text('共 2 段 · 50 秒，点一下试听'), findsOneWidget);
    });

    testWidgets('只有一段时也按秒显示——不能写成「0m」', (tester) async {
      clipStore.saved['sess/100000.wav'] = Float32List(10);
      await pumpReport(tester, buildSession(events: [
        event(
            label: SleepCategory.snore,
            start: 100,
            duration: 45,
            snore: 0.8,
            clipPath: 'sess/100000.wav'),
      ]));

      // formatSpan 只到分钟，直接用它的话这一段会显示成「0m」
      expect(find.text('共 1 段 · 45 秒，点一下试听'), findsOneWidget);
    });

    testWidgets('排在「事件明细」前面', (tester) async {
      // 这张卡存在的意义就是**不用翻**。放到最后一张等于没做。
      await pumpReport(tester, mixed());

      final clips = tester.getTopLeft(find.text('鼾声录音')).dy;
      final details = tester.getTopLeft(find.text('事件明细')).dy;
      expect(clips, lessThan(details),
          reason: '鼾声录音排在 y=$clips，事件明细排在 y=$details');
    });

    testWidgets('和「事件明细」共享播放状态', (tester) async {
      await pumpReport(tester, mixed());

      await tester.tap(
          inSection('鼾声录音', find.byIcon(Icons.play_circle_outline)).first);
      await tester.pumpAndSettle();

      // 两处认的是**同一个事件下标**，所以在任一处点了播，
      // 另一处也要跟着变——不然会出现两个播放键同时亮着
      expect(inSection('鼾声录音', find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);
      expect(inSection('事件明细', find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);
    });

    testWidgets('没打鼾的一晚，整张卡不出现', (tester) async {
      await pumpReport(tester, buildSession(events: [
        event(label: SleepCategory.breathing, start: 100, duration: 300),
      ]));

      expect(find.text('鼾声录音'), findsNothing,
          reason: '不打鼾还占一张卡，就是往报告里塞噪音');
    });

    testWidgets('打了鼾却一段录音都没有 —— 说清楚为什么', (tester) async {
      // 用户把「保留鼾声片段」关了，或者那是关闭之前的记录。
      // 不给理由的话，「怎么没有」会变成一个谜。
      await pumpReport(tester, buildSession(events: [
        event(label: SleepCategory.snore, start: 100, duration: 30, snore: 0.8),
      ]));

      expect(find.text('鼾声录音'), findsOneWidget);
      expect(find.textContaining('没有留下录音'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline), findsNothing);
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

  group('录音质量诊断', () {
    testWidgets('一切正常时不出这张卡，免得凭空制造焦虑', (tester) async {
      await pumpReport(tester, buildSession());
      expect(find.text('录音质量'), findsNothing);
    });

    testWidgets('整晚没触发分析时，明确说这不是"我没打鼾"', (tester) async {
      await pumpReport(
        tester,
        buildSession(
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
        ),
      );

      expect(find.text('录音质量'), findsOneWidget);
      expect(find.text('整晚几乎没有触发分析'), findsOneWidget);
      // 光说"没触发"没用，得告诉用户去查什么
      expect(find.textContaining('挡住'), findsWidgets);
    });

    testWidgets('鼾声占比异常高时给出最可能的原因', (tester) async {
      await pumpReport(
        tester,
        buildSession(
          stats: const SessionStats(
            analyzedSeconds: 28800,
            windowsTotal: 9600,
            windowsInferred: 9000,
            windowsVadSkipped: 600,
            windowsLowConfidence: 200,
            eventCount: 3,
            snoreEventCount: 3,
            snoreSeconds: 18720, // 65%
            categoryDistribution: {},
          ),
        ),
      );

      expect(find.textContaining('鼾声占比异常高'), findsOneWidget);
      expect(find.textContaining('风扇'), findsWidgets);
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
