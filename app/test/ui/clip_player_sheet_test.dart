import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/fake_clip_services.dart';
import '../helpers/pump_app.dart';
import 'package:sleep_secret/data/services/wav_encoder.dart';
import 'package:sleep_secret/ui/core/widgets/clip_waveform.dart';
import 'package:sleep_secret/ui/features/report/views/clip_player_sheet.dart';

/// 片段播放面板：波形、进度、以及**真实时长**。
///
/// ## 为什么这个面板值得单独测
///
/// 它要解决的是一个具体的误会：报告列表里那个数字是**事件**时长（可以到
/// 几分钟），而片段被 `maxClipSeconds` 封顶成 20 秒。用户看到「43 秒」
/// 却发现只响几秒，会以为播放器坏了。面板上写的是 `0:07 / 0:20`，
/// 末尾还补一句「全长 43 秒，这是末尾 20 秒的摘录」——误会就没地方生了。
///
/// 所以这里断言的重点是：**面板上的时长来自文件本身**，不是外面传进来的。
void main() {
  late Directory tmp;
  late FakeEventPlayer player;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clip_player_test');
    player = FakeEventPlayer();
  });

  tearDown(() {
    player.dispose();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 写一段真的 WAV 出来——面板是从文件读时长和波形的，
  /// 拿假路径测不出任何东西。
  String writeWav(double seconds, {double amplitude = 0.5}) {
    final rate = 16000;
    final n = (seconds * rate).round();
    final samples = Float32List(n);
    for (var i = 0; i < n; i++) {
      // 用一个慢正弦，保证波形有起伏（不然抽出来是一条直线，断言没意义）
      samples[i] = amplitude * math.sin(2 * math.pi * 2.5 * i / rate);
    }
    final file = File('${tmp.path}/clip.wav');
    file.writeAsBytesSync(encodeWavPcm16(samples, sampleRate: rate));
    return file.path;
  }

  Future<void> pumpSheet(
    WidgetTester tester, {
    required String path,
    double eventSeconds = 20,
  }) async {
    // ⚠️ 必须 runAsync：面板要读**真文件**，而 testWidgets 的假时钟不推进
    // 真实 I/O——直接用 pumpAndSettle 会一直等到超时。
    await tester.runAsync(() async {
      await tester.pumpWidget(localizedApp(
        home: Scaffold(
          body: ClipPlayerSheet(
            player: player,
            clipPath: path,
            title: '03:09 · 鼾声',
            eventSeconds: eventSeconds,
          ),
        ),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pump();
  }

  group('waveformPeaks', () {
    test('空输入返回空表，不抛', () {
      expect(waveformPeaks(Float32List(0)), isEmpty);
    });

    test('每一桶取的是**极值**，不是平均值', () {
      // 前半段静音、后半段满幅：取平均的话后半段会被前一半稀释
      final samples = Float32List(20);
      for (var i = 10; i < 20; i++) {
        samples[i] = 1.0;
      }
      final peaks = waveformPeaks(samples, buckets: 2);

      expect(peaks.length, 2);
      expect(peaks[0].max, 0.0);
      // 平均值会是 0.5，极值才是 1.0
      expect(peaks[1].max, 1.0);
    });

    test('采样点比桶还少时也要给出等量的桶', () {
      final peaks = waveformPeaks(Float32List(3), buckets: 8);
      expect(peaks.length, 8);
    });

    test('越界的采样点被夹回 [-1, 1]——不然会画到框外面', () {
      final samples = Float32List.fromList([2.0, -3.0]);
      final peaks = waveformPeaks(samples, buckets: 2);
      expect(peaks[0].max, 1.0);
      expect(peaks[1].min, -1.0);
    });
  });

  group('播放面板', () {
    testWidgets('时长写的是文件自己的长度，不是外面传进来的事件时长', (tester) async {
      await pumpSheet(tester, path: writeWav(3), eventSeconds: 183);

      // 文件 3 秒 → 进度行右边必须是 0:03
      expect(find.text('0:00 / 0:03'), findsOneWidget);
      // 而事件那 183 秒绝不能出现在进度行里（它会出现在下面的说明里，
      // 那是另一回事——那句话说的正是"音频只有末尾一小段"）
      expect(find.text('0:00 / 3:03'), findsNothing);
    });

    testWidgets('事件明显更长时，说明这是末尾的摘录', (tester) async {
      await pumpSheet(tester, path: writeWav(3), eventSeconds: 183);

      expect(find.textContaining('全长 183 秒'), findsOneWidget);
      expect(find.textContaining('末尾'), findsOneWidget);
    });

    testWidgets('事件本来就短时不啰嗦这一句', (tester) async {
      await pumpSheet(tester, path: writeWav(3), eventSeconds: 4);

      expect(find.textContaining('全长'), findsNothing);
    });

    testWidgets('波形画出来了', (tester) async {
      await pumpSheet(tester, path: writeWav(2));

      final waveform = tester.widget<ClipWaveform>(find.byType(ClipWaveform));
      expect(waveform.peaks, isNotEmpty);
      expect(waveform.peaks.length, 160);
    });

    testWidgets('拖波形会 seek 到对应位置', (tester) async {
      await pumpSheet(tester, path: writeWav(10));

      final box = tester.getRect(find.byType(ClipWaveform));
      // 从中间拖到大约 3/4 处
      await tester.dragFrom(
        box.centerLeft + const Offset(4, 0),
        Offset(box.width * 0.75, 0),
      );
      await tester.pump();

      expect(player.seekCount, greaterThan(0));
      final seconds = player.lastSeek!.inMilliseconds / 1000;
      expect(seconds, greaterThan(6)); // 10 秒的 3/4
      expect(seconds, lessThan(10));
    });

    testWidgets('拖的时候先只动播放头，松手才 seek', (tester) async {
      await pumpSheet(tester, path: writeWav(10));

      final box = tester.getRect(find.byType(ClipWaveform));
      final gesture = await tester.startGesture(box.centerLeft + const Offset(4, 4));
      await gesture.moveBy(Offset(box.width * 0.5, 0));
      await tester.pump();

      // 还按着：一次都不该 seek，否则播放器会被反复重新起播
      expect(player.seekCount, 0);

      await gesture.up();
      await tester.pump();
      expect(player.seekCount, 1);
    });

    testWidgets('播放中按下按钮是暂停，再按是继续', (tester) async {
      await pumpSheet(tester, path: writeWav(5));

      // 起播是列表那边做的，这里只让假播放器进入"正在播"的状态。
      // 不能 await：假播放器模仿 just_audio，play() 要等播放结束才 resolve。
      unawaited(player.play('whatever.wav'));
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.pause), findsOneWidget);

      await tester.tap(find.byIcon(Icons.pause));
      await tester.pump();
      expect(player.pauseCount, 1);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);

      await tester.tap(find.byIcon(Icons.play_arrow));
      await tester.pump();
      expect(player.resumeCount, 1);
    });

    testWidgets('读不出来时说清楚，而不是画一条平线', (tester) async {
      await pumpSheet(tester, path: '${tmp.path}/does-not-exist.wav');

      expect(find.byType(ClipWaveform), findsNothing);
      expect(find.textContaining('读不出来'), findsOneWidget);
    });
  });
}
