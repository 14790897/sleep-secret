import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/pump_app.dart';
import 'package:sleep_secret/data/models/sleep_class_map.dart';
import 'package:sleep_secret/domain/analysis/sleep_score.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';
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
  double? peakRms,
  String? signal,
}) =>
    SoundEvent(
      label: label,
      startSeconds: start,
      durationSeconds: duration,
      confidence: confidence,
      snoreProbability: snore,
      windowCount: (duration / 3).round(),
      clipPath: clipPath,
      peakRms: peakRms,
      signal: signal,
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

  ReportViewModel buildVm(RecordingSession session, {SleepClassMap? classMap}) =>
      ReportViewModel(
        session: session,
        clipStore: clipStore,
        player: player,
        classMap: classMap,
      );

  Widget wrap(RecordingSession session,
          {SleepClassMap? classMap, Locale locale = const Locale('zh')}) =>
      localizedApp(
        home: ReportView(viewModel: buildVm(session, classMap: classMap)),
        locale: locale,
      );

  /// 报告页很长，默认 800x600 的测试视口装不下；ListView 只构建可见区域，
  /// 屏幕外的分区根本不在 widget 树里，断言会找不到。把视口调高即可。
  Future<void> pumpReport(
    WidgetTester tester,
    RecordingSession session, {
    SleepClassMap? classMap,
  }) async {
    tester.view.physicalSize = const Size(900, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(wrap(session, classMap: classMap));
    await tester.pumpAndSettle();
  }

  /// 把查找限定在某一张卡里。
  ///
  /// 用 **key** 而不是卡片标题。同一段片段现在两处各有一行，全局找会数出
  /// 双份，得说清楚在哪儿数；而按标题文字找的话，改一次文案所有断言就散架，
  /// 失败信息还看不出是"文案改了"还是"卡片真没了"。
  ///
  /// 见 `ReportKeys` 里「定位用 key、文案用 text」那段。
  Finder inCard(ValueKey<String> card, Finder matching) =>
      find.descendant(of: find.byKey(card), matching: matching);

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
      expect(inCard(ReportKeys.eventDetail, find.byIcon(Icons.play_circle_outline)),
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

      expect(inCard(ReportKeys.eventDetail, find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);
    });

    testWidgets('点下去立刻进入播放态，不会一直转圈', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();

      // just_audio 的 play() 要等播放结束才 resolve。实现里一旦 await 它，
      // 「正在播放」就永远设不上，界面会一直停在加载态——这个断言就是防它。
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(inCard(ReportKeys.eventDetail, find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);
    });

    testWidgets('再点同一个事件会停止播放', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();
      await tester.tap(inCard(ReportKeys.eventDetail, find.byIcon(Icons.stop_circle_outlined)));
      await tester.pumpAndSettle();

      expect(player.stopCount, greaterThanOrEqualTo(1));
      expect(inCard(ReportKeys.eventDetail, find.byIcon(Icons.play_circle_outline)),
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
      expect(inCard(ReportKeys.eventDetail, find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);
    });

    testWidgets('播放自然结束后按钮回到可播放态', (tester) async {
      await pumpReport(tester, withClips());

      await tester.tap(find.byIcon(Icons.play_circle_outline).first);
      await tester.pumpAndSettle();
      expect(inCard(ReportKeys.eventDetail, find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);

      player.finishNaturally();
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.stop_circle_outlined), findsNothing);
      expect(inCard(ReportKeys.eventDetail, find.byIcon(Icons.play_circle_outline)),
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

      expect(inCard(ReportKeys.snoreClips, find.byIcon(Icons.play_circle_outline)),
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

      // 比的是卡片本身的位置，不是标题文字的位置——顺序是结构问题
      final clips = tester.getTopLeft(find.byKey(ReportKeys.snoreClips)).dy;
      final details = tester.getTopLeft(find.byKey(ReportKeys.eventDetail)).dy;
      expect(clips, lessThan(details),
          reason: '鼾声录音排在 y=$clips，事件明细排在 y=$details');
    });

    testWidgets('和「事件明细」共享播放状态', (tester) async {
      await pumpReport(tester, mixed());

      await tester.tap(
          inCard(ReportKeys.snoreClips, find.byIcon(Icons.play_circle_outline)).first);
      await tester.pumpAndSettle();

      // 两处认的是**同一个事件下标**，所以在任一处点了播，
      // 另一处也要跟着变——不然会出现两个播放键同时亮着
      expect(inCard(ReportKeys.snoreClips, find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);
      expect(inCard(ReportKeys.eventDetail, find.byIcon(Icons.stop_circle_outlined)),
          findsOneWidget);
    });

    testWidgets('没打鼾的一晚，整张卡不出现', (tester) async {
      await pumpReport(tester, buildSession(events: [
        event(label: SleepCategory.breathing, start: 100, duration: 300),
      ]));

      // 断的是「卡不在」，所以用 key；标题文字在不在是另一回事
      expect(find.byKey(ReportKeys.snoreClips), findsNothing,
          reason: '不打鼾还占一张卡，就是往报告里塞噪音');
    });

    testWidgets('打了鼾却一段录音都没有 —— 说清楚为什么', (tester) async {
      // 用户把「保留鼾声片段」关了，或者那是关闭之前的记录。
      // 不给理由的话，「怎么没有」会变成一个谜。
      await pumpReport(tester, buildSession(events: [
        event(label: SleepCategory.snore, start: 100, duration: 30, snore: 0.8),
      ]));

      expect(find.byKey(ReportKeys.snoreClips), findsOneWidget);
      expect(find.text('鼾声录音'), findsOneWidget,
          reason: '标题该是用户看得懂的话，这条是**文案**断言');
      expect(find.textContaining('没有留下录音'), findsOneWidget);
      expect(find.byIcon(Icons.play_circle_outline), findsNothing);
    });
  });

  group('每条鼾声的分贝', () {
    testWidgets('有电平的显示「约」多少分贝', (tester) async {
      await pumpReport(tester, buildSession(events: [
        event(
          label: SleepCategory.snore,
          start: 100,
          duration: 12,
          snore: 0.8,
          peakRms: 0.3, // 约 84 分贝
        ),
      ]));

      expect(find.text('~84dB'), findsOneWidget,
          reason: '**必须带波浪号**：那是「约」的意思，不带会读成测量值。'
              '手机麦克风没有校准，这个数误差有 ±10 分贝');
    });

    testWidgets('老记录没有电平 —— 什么都不显示，也不显示 ~0dB', (tester) async {
      // ⚠️ 这条是重点。0 分贝是「极其安静」，而真相是「那时候没记电平」。
      // 用 0 顶上去比不显示更糟——它会让人以为那一夜安静得不正常。
      await pumpReport(tester, buildSession(events: [
        event(label: SleepCategory.snore, start: 100, duration: 12, snore: 0.8),
      ]));

      expect(find.textContaining('dB'), findsNothing);
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


  group('疑似呼吸暂停的信号卡', () {
    /// 造一晚：普通鼾声 + 指定的几个高危信号。
    RecordingSession signalsSession(
      List<({String signal, double start})> signals, {
      bool collected = true,
    }) {
      // 片段要真的"存在"于假存储里，否则 resolve 返回 null，播放键点了没反应
      clipStore.saved['sess/3600000.wav'] = Float32List(10);
      for (final s in signals) {
        clipStore.saved['sess/${s.start.round()}000.wav'] = Float32List(10);
      }
      return buildSession(
          events: [
            event(
              label: SleepCategory.snore,
              start: 3600,
              duration: 180,
              snore: 0.8,
              clipPath: 'sess/3600000.wav',
            ),
            for (final s in signals)
              event(
                label: SleepCategory.breathing,
                start: s.start,
                duration: 3,
                confidence: 0.9,
                signal: s.signal,
                clipPath: 'sess/${s.start.round()}000.wav',
              ),
          ],
          stats: SessionStats(
            analyzedSeconds: 28800,
            windowsTotal: 9600,
            windowsInferred: 9600,
            windowsVadSkipped: 0,
            windowsLowConfidence: 0,
            eventCount: 1 + signals.length,
            snoreEventCount: 1,
            snoreSeconds: 180,
            categoryDistribution: const {},
            signalsCollected: collected,
          ),
        );
    }

    testWidgets('认出来了就一条一条列出来，名字写的是具体那一声', (tester) async {
      await pumpReport(tester, signalsSession([
        (signal: 'Gasp', start: 1000),
        (signal: 'Gasp', start: 2000),
        (signal: 'Gasp', start: 3000),
      ]));

      final card = ReportKeys.apneaSignals;
      expect(inCard(card, find.text('疑似呼吸暂停的信号')), findsOneWidget);
      expect(inCard(card, find.textContaining('整夜共 3 次')), findsOneWidget);
      // 显示的是「倒吸气」「哮鸣」，不是大类名「呼吸声」
      expect(inCard(card, find.text('倒吸气')), findsNWidgets(3));
      expect(inCard(card, find.text('呼吸声')), findsNothing);
    });

    testWidgets('每一条都有播放键', (tester) async {
      await pumpReport(tester, signalsSession([
        (signal: 'Gasp', start: 1000),
        (signal: 'Gasp', start: 2000),
      ]));

      // 信号事件的第 1、2 条（第 0 条是默认的鼾声）
      expect(find.byKey(ReportKeys.signalRow(1)), findsOneWidget);
      expect(find.byKey(ReportKeys.signalRow(2)), findsOneWidget);

      final play = find.descendant(
        of: find.byKey(ReportKeys.signalRow(1)),
        matching: find.byIcon(Icons.play_circle_outline),
      );
      expect(play, findsOneWidget);

      await tester.tap(play);
      await tester.pumpAndSettle();
      // 点下去真的要放那一段——而且放的是**这一条**的那一段
      expect(player.playCount, 1);
      expect(player.currentPath, '/fake/clips/sess/1000000.wav');
    });

    testWidgets('一条都没认出来时，说清楚在盯着哪几样', (tester) async {
      await pumpReport(tester, signalsSession(const []));

      final card = ReportKeys.apneaSignals;
      expect(inCard(card, find.textContaining('整夜没有认出')), findsOneWidget);
      // 「这几样」必须写明白，否则用户拿这份东西当「查过了，没问题」
      // 断言整句而不是只找「倒吸气」——底下那段说明里也有这个词
      expect(
        inCard(card, find.textContaining('整夜没有认出这些声音：倒吸气')),
        findsOneWidget,
      );
    });

    testWidgets('老记录说「没收集」，不说「没有」', (tester) async {
      await pumpReport(tester, signalsSession(const [], collected: false));

      final card = ReportKeys.apneaSignals;
      expect(inCard(card, find.textContaining('没有收集这类信号')), findsOneWidget);
      expect(inCard(card, find.textContaining('整夜没有认出')), findsNothing,
          reason: '没查过就不能说查了没有');
    });

    testWidgets('信号事件不进「鼾声录音」卡——那张卡说的不是这件事', (tester) async {
      await pumpReport(tester, signalsSession([
        (signal: 'Gasp', start: 1000),
      ]));

      // 鼾声那一张仍然只有默认的那一段鼾声
      expect(find.byKey(ReportKeys.clipRow(0)), findsOneWidget);
      final snoreCard = find.byKey(ReportKeys.snoreClips);
      expect(
        find.descendant(of: snoreCard, matching: find.text('倒吸气')),
        findsNothing,
      );
    });

    testWidgets('没有分析的记录不出这张卡', (tester) async {
      await pumpReport(
        tester,
        buildSession(
          events: const [],
          stats: const SessionStats(
            analyzedSeconds: 0,
            windowsTotal: 0,
            windowsInferred: 0,
            windowsVadSkipped: 0,
            windowsLowConfidence: 0,
            eventCount: 0,
            snoreEventCount: 0,
            snoreSeconds: 0,
            categoryDistribution: {},
          ),
        ),
      );

      expect(find.text('疑似呼吸暂停的信号'), findsNothing);
    });
  });


  group('详细视图（原始 AudioSet 标签）', () {
    /// 一张刻意留了两个**没映射**索引的映射表。
    ///
    /// 未映射那一列是这个视图最该看见的东西——它说明有些声音在分类体系外面，
    /// 而它们在报告别的地方一次都不会出现。没有未映射的样本就测不到它。
    SleepClassMap tinyMap() => SleepClassMap.fromJson({
          'model': 'test-model',
          'num_classes': 11,
          'categories': {
            'snore': [0],
            'breathing': [1],
            'cough': [2],
            'sneeze': [3],
            'vocal': [4],
            'movement': [5],
            'ambient': [6],
            'deviceNoise': [7],
            'silence': [10],
          },
          'core_snore': [0],
          'id2label': {
            '0': 'Snoring',
            '1': 'Gasp',
            '2': 'Cough',
            '3': 'Sneeze',
            '4': 'Speech',
            '5': 'Rustle',
            '6': 'Rain',
            '7': 'Mechanical fan',
            '8': 'Thunder', // 未映射
            '9': 'Alarm', // 未映射
            '10': 'Silence',
          },
        });

    RecordingSession labelled(Map<String, int> counts) => buildSession(
          stats: SessionStats(
            analyzedSeconds: 28800,
            windowsTotal: 9600,
            windowsInferred: 9600,
            windowsVadSkipped: 0,
            windowsLowConfidence: 0,
            eventCount: 1,
            snoreEventCount: 1,
            snoreSeconds: 180,
            categoryDistribution: const {},
            signalsCollected: true,
            rawLabelCounts: counts,
          ),
        );

    /// 展开那张表。**它默认是收起的**，所以断言行内容之前必须先点一下标题。
    ///
    /// 点的是标题文字——可点区域只挂在标题那一行上（`SectionCard.onTap`）。
    /// 整张卡都点的话，用户读正文时随手一碰就收回去了。
    Future<void> expand(WidgetTester tester) async {
      await tester.tap(find.text('详细视图'));
      await tester.pumpAndSettle();
    }

    testWidgets('默认收起：摘要和「未映射」留在外面，标签行不铺出来', (tester) async {
      await pumpReport(
        tester,
        labelled({'Snoring': 100, 'Thunder': 30}),
        classMap: tinyMap(),
      );

      final card = ReportKeys.rawLabels;
      // 摘要和「未映射」那句是**扫一眼就该看见的**，藏起来等于这张卡白做
      expect(inCard(card, find.textContaining('共 2 种标签')), findsOneWidget);
      expect(inCard(card, find.textContaining('没有归进任何大类')), findsOneWidget);
      // 但标签行不在
      expect(inCard(card, find.text('Snoring')), findsNothing);
      expect(inCard(card, find.textContaining('点标题展开')), findsOneWidget);
    });

    testWidgets('展开后中文对照跟着出来', (tester) async {
      await pumpReport(
        tester,
        labelled({'Mechanical fan': 100, 'Thunder': 30}),
        classMap: tinyMap(),
      );

      final card = ReportKeys.rawLabels;
      await expand(tester);

      // ⚠️ 挑的这两个标签**中文和大类名不重名**。用 `Snoring` 的话，
      // 它的中文是「鼾声」，而它归的大类也叫「鼾声」——一行里出现两次，
      // `findsOneWidget` 会红，而那不是 bug 是断言写得不严谨。
      expect(inCard(card, find.text('Mechanical fan')), findsOneWidget);
      expect(inCard(card, find.text('机械风扇')), findsOneWidget);
      expect(inCard(card, find.text('雷声')), findsOneWidget);
      expect(inCard(card, find.textContaining('点标题展开')), findsNothing);
    });

    testWidgets('英文界面下不显示中文对照——标签本来就是英文', (tester) async {
      // 那张表**只有中文**，英文界面里显示它反而是噪音。
      tester.view.physicalSize = const Size(900, 4200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(wrap(
        labelled({'Snoring': 100}),
        classMap: tinyMap(),
        locale: const Locale('en'),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Detailed view'));
      await tester.pumpAndSettle();

      expect(find.text('Snoring'), findsWidgets);
      expect(find.text('鼾声'), findsNothing);
    });

    testWidgets('按次数从多到少列，带百分比和大类对照', (tester) async {
      await pumpReport(
        tester,
        labelled({'Snoring': 100, 'Gasp': 50, 'Thunder': 30, 'Alarm': 20}),
        classMap: tinyMap(),
      );
      await expand(tester);

      final card = ReportKeys.rawLabels;
      expect(inCard(card, find.text('详细视图')), findsOneWidget);
      expect(inCard(card, find.textContaining('共 4 种标签')), findsOneWidget);
      expect(inCard(card, find.textContaining('200 个分析窗口')), findsOneWidget);

      expect(inCard(card, find.text('Snoring')), findsOneWidget);
      expect(inCard(card, find.text('鼾声')), findsOneWidget);
      expect(inCard(card, find.text('50.0%')), findsOneWidget);
      expect(inCard(card, find.text('10.0%')), findsOneWidget);
    });

    testWidgets('未映射的标签标出来，并且说明有几样', (tester) async {
      await pumpReport(
        tester,
        labelled({'Snoring': 100, 'Thunder': 30, 'Alarm': 20}),
        classMap: tinyMap(),
      );
      await expand(tester);

      final card = ReportKeys.rawLabels;
      // Thunder / Alarm 都不在映射表里
      expect(inCard(card, find.text('未映射')), findsNWidgets(2));
      expect(inCard(card, find.textContaining('其中 2 种没有归进任何大类')),
          findsOneWidget);
    });

    testWidgets('全是已映射的标签时，不提未映射', (tester) async {
      await pumpReport(tester, labelled({'Snoring': 100, 'Gasp': 50}),
          classMap: tinyMap());
      await expand(tester);

      expect(inCard(ReportKeys.rawLabels, find.text('未映射')), findsNothing);
    });

    testWidgets('拿不到映射表时列标签，但**不标「未映射」**', (tester) async {
      // 映射表是可选注入的——它拿不到不该让整张卡消失，
      // 更不该让报告打不开。核查信息缺失是缺信息，不是崩溃。
      await pumpReport(tester, labelled({'Snoring': 100, 'Thunder': 30}));
      await expand(tester);

      final card = ReportKeys.rawLabels;
      expect(inCard(card, find.text('Snoring')), findsOneWidget);
      expect(inCard(card, find.text('Thunder')), findsOneWidget);

      // ⚠️ 这几条是重点。第一版把「没有映射表」和「未映射」画成了同一个样子：
      // 拿不到表时整个列表全标成「未映射」，顶上还说「其中 N 种没有归进任何
      // 大类」——那是**假消息**。刚装好的 App 就是这样（映射表原来跟着模型
      // 懒加载，没录过音就还没读），报告页上一条真话都没有。
      expect(inCard(card, find.text('未映射')), findsNothing);
      expect(inCard(card, find.textContaining('没有归进任何大类')), findsNothing);
    });

    testWidgets('老记录（没有计数）明说是没收集，不列空表', (tester) async {
      await pumpReport(tester, buildSession());

      final card = ReportKeys.rawLabels;
      expect(inCard(card, find.textContaining('升级前的记录不收集它')),
          findsOneWidget);
    });

    testWidgets('压在统计后面、但在「事件明细」之前', (tester) async {
      // 两个方向都要卡住：往前会让它挡住正常阅读；往后要滚过一整屏
      // 原始事件（一夜上百行）才够得着，那就不叫「方便核查」了。
      await pumpReport(tester, labelled({'Snoring': 100}), classMap: tinyMap());

      final raw = tester.getTopLeft(find.byKey(ReportKeys.rawLabels)).dy;
      final detail = tester.getTopLeft(find.byKey(ReportKeys.eventDetail)).dy;
      expect(raw, greaterThan(0));
      expect(raw, lessThan(detail), reason: '详细视图应当排在「事件明细」之前');
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
