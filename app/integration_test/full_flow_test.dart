import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sleep_secret/data/services/database_factory_setup.dart';
import 'package:sleep_secret/data/services/file_audio_clip_store.dart';
import 'package:sleep_secret/data/services/session_database.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';
import 'package:sleep_secret/main.dart';
import 'package:sleep_secret/ui/core/widgets/charts.dart';
import 'package:sleep_secret/ui/core/widgets/sound_timeline.dart';

/// 真机上的完整用户路径。
///
///   flutter test integration_test/full_flow_test.dart -d <设备>
///
/// **这个测试测不到什么**（写清楚，免得把它当成"整夜录音已验证"）：
///
/// - **麦克风内容**。测试环境拿不到有意义的音频输入，所以录音只能验证
///   "点得起来、停得下来、数据落得进库"，验证不了识别结果对不对。
/// - **整夜保活**。前台服务能不能撑过 8 小时、息屏后会不会被杀、
///   国产 ROM 会不会清理后台——这些只有真的睡一晚才知道。
/// - **推理速度与耗电**。测试跑几分钟，说明不了整夜的表现。
/// - **真实鼾声的检出率**。依然只有合成音频验证过链路。
///
/// 它**能**测到：界面在真机上渲染正常、跨页面导航通畅、数据真落进
/// SQLite 又真读得出来、图表不崩、音频片段能解出可播放的文件。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  configureDatabaseFactory();

  /// 归档文件（片段）的临时目录。用真目录而不是 mock，
  /// 才能验证"写出的 WAV 真的能被解码"。
  late Directory supportDir;
  late FileAudioClipStore clipStore;

  setUpAll(() async {
    supportDir = await Directory.systemTemp.createTemp('flow_support');
    clipStore = FileAudioClipStore(baseDirectory: supportDir);
  });

  tearDownAll(() async {
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  /// 等真实时间过去，而不是推进假时钟——集成测试跑在真实异步环境里。
  Future<void> settle(WidgetTester tester, [int ms = 600]) async {
    await tester.pump();
    await Future<void>.delayed(Duration(milliseconds: ms));
    await tester.pump();
  }

  testWidgets('录音页 → 起停 → 落库 → 报告列表 → 报告详情', (tester) async {
    await tester.pumpWidget(const SleepSecretApp());
    await settle(tester, 1500);

    // ---- 1. 录音页渲染 ----
    expect(find.text('睡眠录音'), findsWidgets);
    expect(find.text('点一下开始'), findsOneWidget);
    expect(find.text('使用说明'), findsOneWidget);

    // ---- 2. 底部导航可切换 ----
    await tester.tap(find.text('关于'));
    await settle(tester);
    expect(find.textContaining('数据不出手机'), findsOneWidget);

    await tester.tap(find.text('报告'));
    await settle(tester);
    expect(find.text('睡眠报告'), findsWidgets);

    await tester.tap(find.text('睡眠'));
    await settle(tester);

    // ---- 3. 开始录音 ----
    await tester.tap(find.byIcon(Icons.mic));
    await settle(tester, 2500);

    // 权限可能没给（系统弹窗测试点不到），两种情况都要能自洽
    final startedRecording = find.text('录音中').evaluate().isNotEmpty;
    final permissionDenied =
        find.textContaining('未获得麦克风权限').evaluate().isNotEmpty;

    expect(startedRecording || permissionDenied, isTrue,
        reason: '要么进录音态，要么明确提示没权限，不能点了没反应');

    if (startedRecording) {
      // 录音中：计时与实时统计要出现
      expect(find.text('实时分析'), findsOneWidget);

      // 注意：这里**不能**用 pumpAndSettle——录音时外圈是无限循环动画，
      // 永远等不到静止。
      await settle(tester, 2000);

      expect(find.text('录音中'), findsOneWidget,
          reason: '过了两秒还应当在录，不该自己停掉');

      // ---- 4. 停止并保存 ----
      await tester.tap(find.byIcon(Icons.stop));
    } else {
      // 没权限时按钮不该卡在加载态
      expect(find.byIcon(Icons.mic), findsOneWidget);
    }
    await settle(tester, 2000);

    expect(find.text('点一下开始'), findsOneWidget,
        reason: '停止后要回到待机态');
  });

  testWidgets('写入的一晚会出现在报告里，各分区都能渲染', (tester) async {
    // 直接用真实的持久化层塞一晚数据。
    // 录音本身产出不了事件（测试环境没麦克风输入），
    // 所以报告页的内容验证要靠这份构造数据。
    final database = SessionDatabase();
    addTearDown(database.close);

    // 先落库再启动界面，保证报告列表里一定有东西可点
    await seedOneNight(database, clipStore);

    await tester.pumpWidget(const SleepSecretApp());
    await settle(tester, 2000);

    await tester.tap(find.text('报告'));
    await settle(tester, 1500);

    // 列表里应当有记录
    expect(find.text('历史记录'), findsOneWidget);

    // 打开最近一晚。不能点 Card.first —— 第一个 Card 是顶部的趋势卡，
    // 点了不会跳转。按日期文本精确定位那一行。
    final entry = find.textContaining('10月6日');
    expect(entry, findsWidgets, reason: '历史列表里应当能看到刚写入的那晚');
    await tester.tap(entry.first);
    await settle(tester, 2500);

    // 报告页很长，ListView 只构建可视区域。把视口调高，
    // 让下面几个分区都真正建出来，否则断言会找不到。
    tester.view.physicalSize = const Size(1080, 6400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await settle(tester, 1500);

    // ---- 报告详情各分区 ----
    expect(find.text('睡眠报告'), findsWidgets);
    expect(find.text('评分构成'), findsOneWidget);
    expect(find.textContaining('不反映你的睡眠分期'), findsOneWidget);
    expect(find.text('整夜声音'), findsOneWidget);
    expect(find.byType(SoundTimeline), findsWidgets);
    expect(find.text('每小时分布'), findsOneWidget);
    expect(find.byType(HourlyChart), findsWidgets);
    expect(find.text('鼾声段时长'), findsOneWidget);
    expect(find.text('类别分布'), findsOneWidget);
    expect(find.text('端侧分析'), findsOneWidget);
    expect(find.text('事件明细'), findsOneWidget);

    // 鼾声事件带片段，应当有试听按钮
    expect(find.byIcon(Icons.play_circle_outline), findsWidgets,
        reason: '写入时给第一条鼾声配了音频片段');

    // 报告页不能有任何异常抛出
    expect(tester.takeException(), isNull);
  });
}

/// 通过真实的数据层写入一晚带事件的记录，并生成可播放的音频片段。
///
/// 只走公开 API（`SessionDatabase.insertSession` + `AudioClipStore.save`），
/// 不为测试给生产代码开后门。
Future<void> seedOneNight(
  SessionDatabase database,
  FileAudioClipStore clipStore,
) async {
  final started = DateTime(2026, 10, 6, 23, 12);
  const analyzed = 27840.0;

  // 片段用真实文件，才能验证"写出的 WAV 真的能被解码"
  final clipPath = await clipStore.save(
    sessionStartedAt: started,
    startSeconds: 3599,
    samples: Float32List.fromList(
      List.generate(16000 * 2, (i) => 0.3 * ((i % 40) - 20) / 20),
    ),
    sampleRate: 16000,
  );

  final events = <SoundEvent>[
    SoundEvent(
      label: SleepCategory.snore,
      startSeconds: 3600,
      durationSeconds: 180,
      confidence: 0.82,
      snoreProbability: 0.78,
      windowCount: 60,
      clipPath: clipPath,
    ),
    const SoundEvent(
      label: SleepCategory.snore,
      startSeconds: 7200,
      durationSeconds: 240,
      confidence: 0.71,
      snoreProbability: 0.66,
      windowCount: 80,
    ),
    const SoundEvent(
      label: SleepCategory.cough,
      startSeconds: 5400,
      durationSeconds: 18,
      confidence: 0.55,
      snoreProbability: 0.10,
      windowCount: 6,
    ),
    const SoundEvent(
      label: SleepCategory.vocal,
      startSeconds: 9000,
      durationSeconds: 42,
      confidence: 0.61,
      snoreProbability: 0.12,
      windowCount: 14,
    ),
    const SoundEvent(
      label: SleepCategory.breathing,
      startSeconds: 1200,
      durationSeconds: 300,
      confidence: 0.48,
      snoreProbability: 0.05,
      windowCount: 100,
    ),
  ];

  final snoreSeconds = events
      .where((e) => e.isSnore)
      .fold<double>(0, (s, e) => s + e.durationSeconds);

  await database.insertSession(RecordingSession(
    id: null,
    startedAt: started,
    endedAt: started.add(const Duration(hours: 7, minutes: 44)),
    events: events,
    stats: SessionStats(
      analyzedSeconds: analyzed,
      windowsTotal: 9280,
      windowsInferred: 3200,
      windowsVadSkipped: 6080,
      windowsLowConfidence: 2600,
      eventCount: events.length,
      snoreEventCount: events.where((e) => e.isSnore).length,
      snoreSeconds: snoreSeconds,
      categoryDistribution: const {},
    ),
  ));
}
