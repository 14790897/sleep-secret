import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/services/file_audio_clip_store.dart';
import 'package:sleep_secret/data/services/wav_decoder_service.dart';

void main() {
  late Directory tempDir;
  late FileAudioClipStore store;

  final night = DateTime(2026, 10, 6, 23, 12);

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('sleep_secret_clips');
    store = FileAudioClipStore(baseDirectory: tempDir);
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  Float32List ramp(int count, {double amp = 0.5}) => Float32List.fromList(
        List.generate(count, (i) => amp * ((i % 20) - 10) / 10),
      );

  group('保存与读取', () {
    test('保存后能解析出真实存在的文件', () async {
      final path = await store.save(
        sessionStartedAt: night,
        startSeconds: 3720.5,
        samples: ramp(16000),
        sampleRate: 16000,
      );

      expect(path, isNotNull);
      expect(store.failureCount, 0);

      final absolute = await store.resolve(path!);
      expect(absolute, isNotNull);
      expect(File(absolute!).existsSync(), isTrue);
    });

    test('写出的文件是能被解码的合法 WAV', () async {
      final samples = ramp(8000, amp: 0.8);
      final path = await store.save(
        sessionStartedAt: night,
        startSeconds: 100,
        samples: samples,
        sampleRate: 16000,
      );

      final absolute = (await store.resolve(path!))!;
      final bytes = await File(absolute).readAsBytes();
      final decoded = const WavDecoderService().decode(bytes);

      expect(decoded.sampleRate, 16000);
      expect(decoded.samples.length, samples.length);
      expect(decoded.durationSeconds, closeTo(0.5, 1e-6));
    });

    test('文件按会话分组存放', () async {
      final path = await store.save(
        sessionStartedAt: night,
        startSeconds: 60,
        samples: ramp(100),
        sampleRate: 16000,
      );

      // <会话开始毫秒>/<起始毫秒>.wav —— 用开始时刻做目录名，
      // 删除时只靠会话记录里的 startedAt 就能定位
      expect(path, '${night.millisecondsSinceEpoch}/60000.wav');
    });

    test('同一会话的多个片段各存各的文件', () async {
      final a = await store.save(
        sessionStartedAt: night,
        startSeconds: 10,
        samples: ramp(100),
        sampleRate: 16000,
      );
      final b = await store.save(
        sessionStartedAt: night,
        startSeconds: 20,
        samples: ramp(100),
        sampleRate: 16000,
      );

      expect(a, isNot(b));
      expect(await store.resolve(a!), isNot(await store.resolve(b!)));
    });

    test('空音频不写文件', () async {
      final path = await store.save(
        sessionStartedAt: night,
        startSeconds: 0,
        samples: Float32List(0),
        sampleRate: 16000,
      );

      expect(path, isNull);
      expect(store.failureCount, 0, reason: '空输入不是失败');
    });
  });

  group('解析失败的情况', () {
    test('文件不存在时返回 null', () async {
      expect(await store.resolve('nothing/here.wav'), isNull);
    });

    test('路径被删掉后返回 null', () async {
      final path = await store.save(
        sessionStartedAt: night,
        startSeconds: 5,
        samples: ramp(100),
        sampleRate: 16000,
      );
      final absolute = (await store.resolve(path!))!;
      await File(absolute).delete();

      expect(await store.resolve(path), isNull);
    });
  });

  group('删除', () {
    test('删会话只清掉那一晚的片段', () async {
      final other = DateTime(2026, 10, 5, 23);
      final a = await store.save(
        sessionStartedAt: night,
        startSeconds: 1,
        samples: ramp(100),
        sampleRate: 16000,
      );
      final b = await store.save(
        sessionStartedAt: other,
        startSeconds: 1,
        samples: ramp(100),
        sampleRate: 16000,
      );

      await store.deleteSession(night);

      expect(await store.resolve(a!), isNull);
      expect(await store.resolve(b!), isNotNull, reason: '别把别的晚上一起删了');
    });

    test('会话本来就没有片段时不报错', () async {
      await store.deleteSession(DateTime(2020, 1, 1));
    });

    test('deleteAll 清空整个目录', () async {
      await store.save(
        sessionStartedAt: night,
        startSeconds: 1,
        samples: ramp(100),
        sampleRate: 16000,
      );
      await store.save(
        sessionStartedAt: DateTime(2026, 10, 5, 23),
        startSeconds: 1,
        samples: ramp(100),
        sampleRate: 16000,
      );

      await store.deleteAll();

      expect(await store.totalBytes(), 0);
    });
  });

  group('占用统计', () {
    test('统计所有片段的总字节数', () async {
      // 16000 点 = 1 秒 16-bit 单声道 = 32000 字节数据 + 44 字节头
      await store.save(
        sessionStartedAt: night,
        startSeconds: 1,
        samples: ramp(16000),
        sampleRate: 16000,
      );
      await store.save(
        sessionStartedAt: night,
        startSeconds: 2,
        samples: ramp(16000),
        sampleRate: 16000,
      );

      expect(await store.totalBytes(), 2 * (32000 + 44));
    });

    test('没有片段时为 0', () async {
      expect(await store.totalBytes(), 0);
    });
  });
}
