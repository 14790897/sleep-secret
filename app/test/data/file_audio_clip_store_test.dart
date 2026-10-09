import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/services/file_audio_clip_store.dart';
import 'package:sleep_secret/data/services/wav_decoder_service.dart';
import 'package:sleep_secret/domain/analysis/night_analysis_engine.dart';

import '../helpers/fake_sleep_analyzer.dart';

/// 真写盘那条路（[FileAudioClipStore.begin] → append → finish）。
///
/// ⚠️ 这组测试是补出来的。在此之前，流式写入**只被假 store 测过**——
/// 假 store 把采样点攒在内存里，`finish` 时直接扔进 map，根本不碰文件。
/// 于是"文件写出来能不能解回来"这件事完全没人验，直到用户装上 2.16.0
/// 打开播放面板，看到**一条直线**（解码出 0 个采样点才会这样）。
void main() {
  late Directory tmp;
  late FileAudioClipStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('clip_store_test');
    store = FileAudioClipStore(baseDirectory: tmp);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Float32List tone(int sampleCount, {double amplitude = 0.5}) {
    final out = Float32List(sampleCount);
    for (var i = 0; i < sampleCount; i++) {
      out[i] = amplitude * math.sin(2 * math.pi * 220 * i / 16000);
    }
    return out;
  }

  test('流式写完的文件，解码回来要有全部采样点', () async {
    const rate = 16000;
    const seconds = 2;
    final started = DateTime(2026, 10, 9, 1);

    final writer = await store.begin(
      sessionStartedAt: started,
      startSeconds: 0,
      sampleRate: rate,
    );
    expect(writer, isNotNull, reason: '开不了文件的话整段就没了');

    // 按窗口追加
    for (var w = 0; w < seconds; w++) {
      await writer!.append(tone(rate));
    }
    final path = await writer!.finish();
    expect(path, isNotNull);

    final resolved = await store.resolve(path!);
    expect(resolved, isNotNull);

    final decoded = const WavDecoderService().decode(
      await File(resolved!).readAsBytes(),
    );

    expect(decoded.sampleRate, rate);
    expect(decoded.samples.length, rate * seconds,
        reason: '头部没回填对的话，解码器会读成 0 个采样点——'
            '播放面板上就是一条直线');
  });

  test('中途 release 的文件不该留下（更不该留下半个）', () async {
    final started = DateTime(2026, 10, 9, 2);
    final writer = await store.begin(
      sessionStartedAt: started,
      startSeconds: 0,
      sampleRate: 16000,
    );
    await writer!.append(tone(1600));
    await writer.release();

    final dir = Directory('${tmp.path}/clips/${started.millisecondsSinceEpoch}');
    final leftovers = dir.existsSync()
        ? dir.listSync().map((e) => e.path.split(Platform.pathSeparator).last)
        : <String>[];
    expect(leftovers, isEmpty, reason: '不是鼾声的那一段不该在盘上留任何东西');
  });

  test('一个采样点都没有时 finish 返回 null，不留空文件', () async {
    final started = DateTime(2026, 10, 9, 3);
    final writer = await store.begin(
      sessionStartedAt: started,
      startSeconds: 0,
      sampleRate: 16000,
    );
    expect(await writer!.finish(), isNull);
  });

  test('真实鼾声走完整条管线，写出来的片段里有真波形', () async {
    // 用仓库里那段真实鼾声当输入。⚠️ 这条测试是冲着"播放面板上是一条直线"
    // 去的：那条直线意味着解码出来全是 0（或者小到画不出来）。管线和渲染
    // 都可能造成它，而**只有从真音频走完整条路**才分得清是谁。
    final fixtureBytes =
        File('assets/testdata/real/snore_01.wav').readAsBytesSync();
    final fixture = const WavDecoderService().decode(fixtureBytes);
    expect(fixture.samples, isNotEmpty);

    // ⚠️ fixture 只有 5 秒，而事件最短要 6 秒（AnalysisConfig.minEventSeconds）
    // ——直接喂它一个事件都不会成立。接够长再喂。
    final repeats = 4;
    final input = Float32List(fixture.samples.length * repeats);
    for (var r = 0; r < repeats; r++) {
      input.setRange(
        r * fixture.samples.length,
        (r + 1) * fixture.samples.length,
        fixture.samples,
      );
    }

    final engine = NightAnalysisEngine(
      analyzer: FakeSleepAnalyzer(), // 默认判成鼾声
      clipStore: store,
    );
    engine.start(DateTime(2026, 10, 9, 1));

    // 分块喂，贴近真实录音的节奏（录音插件一次给一小块）
    const chunk = 2048;
    for (var i = 0; i < input.length; i += chunk) {
      final end = math.min(i + chunk, input.length);
      await engine.feedSamples(Float32List.sublistView(input, i, end));
    }

    final outcome = await engine.finish();
    expect(outcome.events, isNotEmpty);

    final clipPath = outcome.events.first.clipPath;
    expect(clipPath, isNotNull, reason: '整段鼾声都该留下片段');

    final resolved = await store.resolve(clipPath!);
    final clip = const WavDecoderService().decode(
      File(resolved!).readAsBytesSync(),
    );

    double peak(Float32List s) =>
        s.fold(0.0, (m, v) => v.abs() > m ? v.abs() : m);

    expect(peak(clip.samples), greaterThan(0.05),
        reason: '片段里全是接近 0 的采样点的话，播放面板上就是一条直线');
    expect(peak(clip.samples), closeTo(peak(input), 0.1),
        reason: '写盘的音频要和源音频一个量级');

    // 整段都留：至少覆盖输入的长度减去窗口那点尾巴
    expect(clip.samples.length / 16000,
        greaterThan(input.length / 16000 - 5));
  });
}
