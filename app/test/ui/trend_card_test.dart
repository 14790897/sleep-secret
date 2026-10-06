import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/session_insights.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';
import 'package:sleep_secret/ui/core/theme.dart';
import 'package:sleep_secret/ui/core/widgets/charts.dart';
import 'package:sleep_secret/ui/features/trend/views/trend_card.dart';

RecordingSession night({
  required DateTime startedAt,
  required double snoreIndex,
  double analyzedSeconds = 28800,
  List<SoundEvent> events = const [],
}) =>
    RecordingSession(
      id: 1,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(hours: 8)),
      events: events,
      stats: SessionStats(
        analyzedSeconds: analyzedSeconds,
        windowsTotal: 9600,
        windowsInferred: 3200,
        windowsVadSkipped: 6400,
        windowsLowConfidence: 0,
        eventCount: events.length,
        snoreEventCount: 1,
        // snoreIndex = snoreSeconds / analyzedSeconds * 100
        snoreSeconds: analyzedSeconds * snoreIndex / 100,
        categoryDistribution: const {},
      ),
    );

void main() {
  Future<void> pump(WidgetTester tester, List<RecordingSession> sessions) async {
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: Scaffold(body: SingleChildScrollView(
        child: TrendCard(sessions: sessions),
      )),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('只有一晚时提示还需要一晚', (tester) async {
    await pump(tester, [night(startedAt: DateTime(2026, 10, 6, 23), snoreIndex: 12)]);

    expect(find.text('鼾声指数趋势'), findsOneWidget);
    expect(find.textContaining('再记录一晚'), findsOneWidget);
    expect(find.byType(TrendChart), findsNothing);
  });

  testWidgets('没有记录时整张卡不渲染', (tester) async {
    await pump(tester, const []);

    expect(find.text('鼾声指数趋势'), findsNothing);
  });

  testWidgets('多晚时渲染趋势图与统计', (tester) async {
    await pump(tester, [
      night(startedAt: DateTime(2026, 9, 30, 23), snoreIndex: 25),
      night(startedAt: DateTime(2026, 10, 2, 23), snoreIndex: 20),
      night(startedAt: DateTime(2026, 10, 4, 23), snoreIndex: 15),
      night(startedAt: DateTime(2026, 10, 6, 23), snoreIndex: 6),
    ]);

    expect(find.byType(TrendChart), findsOneWidget);
    expect(find.text('最近 4 晚，虚线是你的平均值 16.5%'), findsOneWidget);
    expect(find.text('平均'), findsOneWidget);
    expect(find.text('最好一晚'), findsOneWidget);
    expect(find.text('最差一晚'), findsOneWidget);
    expect(find.text('25.0'), findsOneWidget); // 最差
    expect(find.text('6.0'), findsOneWidget); // 最好
  });

  testWidgets('变好时给出下降结论', (tester) async {
    await pump(tester, [
      night(startedAt: DateTime(2026, 10, 4, 23), snoreIndex: 22),
      night(startedAt: DateTime(2026, 10, 6, 23), snoreIndex: 8),
    ]);

    expect(find.textContaining('比第一晚少了 14.0 个百分点'), findsOneWidget);
    expect(find.byIcon(Icons.trending_down), findsOneWidget);
  });

  testWidgets('变差时给出上升结论', (tester) async {
    await pump(tester, [
      night(startedAt: DateTime(2026, 10, 4, 23), snoreIndex: 5),
      night(startedAt: DateTime(2026, 10, 6, 23), snoreIndex: 19),
    ]);

    expect(find.textContaining('比第一晚多了 14.0 个百分点'), findsOneWidget);
    expect(find.byIcon(Icons.trending_up), findsOneWidget);
  });

  testWidgets('基本持平时不给方向性结论', (tester) async {
    await pump(tester, [
      night(startedAt: DateTime(2026, 10, 4, 23), snoreIndex: 10),
      night(startedAt: DateTime(2026, 10, 6, 23), snoreIndex: 10.2),
    ]);

    expect(find.text('和第一晚基本持平'), findsOneWidget);
    expect(find.byIcon(Icons.trending_flat), findsOneWidget);
    expect(find.byIcon(Icons.trending_up), findsNothing);
    expect(find.byIcon(Icons.trending_down), findsNothing);
  });

  testWidgets('参考线文案是"你的平均"，不是编造的医学阈值', (tester) async {
    await pump(tester, [
      night(startedAt: DateTime(2026, 10, 4, 23), snoreIndex: 20),
      night(startedAt: DateTime(2026, 10, 6, 23), snoreIndex: 10),
    ]);

    // 副标题已经写明是平均值，图里的线必须一致
    expect(find.textContaining('你的平均值'), findsOneWidget);
  });

  group('空态与边界', () {
    testWidgets('时长为零的会话被排除，不产生假的零点', (tester) async {
      await pump(tester, [
        night(startedAt: DateTime(2026, 10, 4, 23), snoreIndex: 0, analyzedSeconds: 0),
        night(startedAt: DateTime(2026, 10, 5, 23), snoreIndex: 12),
        night(startedAt: DateTime(2026, 10, 6, 23), snoreIndex: 10),
      ]);

      // 排除后剩两晚，仍是趋势图
      expect(find.textContaining('最近 2 晚'), findsOneWidget);
    });

    testWidgets('全部时长为零时退化为提示', (tester) async {
      await pump(tester, [
        night(startedAt: DateTime(2026, 10, 5, 23), snoreIndex: 0, analyzedSeconds: 0),
        night(startedAt: DateTime(2026, 10, 6, 23), snoreIndex: 0, analyzedSeconds: 0),
      ]);

      expect(find.byType(TrendChart), findsNothing);
    });
  });

  group('shortSpan', () {
    test('按量级选单位', () {
      expect(shortSpan(0), '0s');
      expect(shortSpan(45), '45s');
      expect(shortSpan(60), '1m');
      expect(shortSpan(300), '5m');
      expect(shortSpan(3600), '1.0h');
      expect(shortSpan(5400), '1.5h');
    });
  });

  group('HourlyChart / DurationHistogram 空态', () {
    testWidgets('没有桶时显示提示而不是空图', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: const Scaffold(body: HourlyChart(buckets: [])),
      ));
      await tester.pumpAndSettle();

      expect(find.text('没有可统计的声音事件'), findsOneWidget);
    });

    testWidgets('分箱全零时显示没有鼾声', (tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: DurationHistogram(
            bins: [
              for (var i = 0; i < 6; i++)
                DurationBin(label: 'b$i', count: 0, minSeconds: 0, maxSeconds: null),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('这一晚没有检出鼾声'), findsOneWidget);
    });
  });
}
