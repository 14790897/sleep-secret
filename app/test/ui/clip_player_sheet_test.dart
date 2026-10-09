import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter_test/flutter_test.dart';
import '../helpers/fake_clip_services.dart';
import '../helpers/pump_app.dart';
import 'package:sleep_secret/data/services/wav_decoder_service.dart';
import 'package:sleep_secret/data/services/wav_encoder.dart';
import 'package:sleep_secret/ui/core/theme.dart';
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

    test('安静素材也要画得出形状——按峰值归一化', () {
      // 真实卧室录音的峰值就在这个量级（实测 snore_01.wav = 0.058）
      final samples = Float32List(2000);
      for (var i = 0; i < 2000; i++) {
        samples[i] = 0.05 * math.sin(2 * math.pi * 8 * i / 2000);
      }
      final raw = waveformPeaks(samples, buckets: 20);
      expect(raw.first.max.abs(), lessThan(0.1), reason: '前提：素材本身就很轻');

      final top = normalizePeaks(raw).map((p) => p.max.abs()).reduce(math.max);
      expect(top, closeTo(1.0, 0.001),
          reason: '不归一化的话，0.05 的素材在 76px 高的面板上只有 4px——'
              '看上去就是一条直线。用户报的就是这个');
    });

    test('真静音不放大——别把底噪画成一片森林', () {
      const peaks = [
        (min: -0.001, max: 0.001),
        (min: -0.002, max: 0.002),
      ];
      expect(normalizePeaks(peaks), peaks);
    });

    testWidgets('真实素材的波形要占满高度（并留一张预览图给人看）', (tester) async {
      // ⚠️ 这条是冲着"波形是一条直线"那个 bug 来的。它跑的是**仓库里那段真实
      // 鼾声**（峰值实测 0.058——真实卧室录音就在这个量级），不是我自己造的
      // 种子数据。上一轮我在模拟器上看到波形很漂亮，就是因为那份种子数据
      // 振幅有 0.28，把这个问题盖住了。
      final audio = const WavDecoderService().decode(
        File('assets/testdata/real/snore_01.wav').readAsBytesSync(),
      );
      final peaks = waveformPeaks(audio.samples);

      // 取两侧绝对值的较大者：真实波形不对称（这段的负峰比正峰大），
      // 归一化除的是两者中更大的那个，所以只有它才会顶到满格。
      final top = normalizePeaks(peaks)
          .map((p) => math.max(p.max.abs(), p.min.abs()))
          .reduce(math.max);
      expect(top, closeTo(1.0, 0.001),
          reason: '归一化之后最高的那根柱子该顶到满格；'
              '只有三四像素高的话，用户看到的就是一条直线');

      // 顺手渲一张出来，方便肉眼确认（build/ 不进版本库）
      final key = GlobalKey();
      await tester.pumpWidget(localizedApp(
        home: Scaffold(
          backgroundColor: AppColors.surface,
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 640,
                child: ClipWaveform(
                  peaks: peaks,
                  progress: 0.35,
                  onSeek: (_) {},
                ),
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ImageByteFormat.png);
        File('build/waveform_preview.png')
            .writeAsBytesSync(data!.buffer.asUint8List());
      });
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

    testWidgets('事件明显更长时，说明音频比事件短', (tester) async {
      await pumpSheet(tester, path: writeWav(3), eventSeconds: 183);

      expect(find.textContaining('全长 183 秒'), findsOneWidget);
      // ⚠️ 措辞不能说「末尾」：片段正常就是整段，只有触到单段上限才会短，
      // 而那种情况留下的是**开头**。
      expect(find.textContaining('末尾'), findsNothing);
      expect(find.textContaining('保留了其中'), findsOneWidget);
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
