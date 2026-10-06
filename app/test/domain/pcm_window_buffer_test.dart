import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/pcm_window_buffer.dart';

Float32List ramp(int from, int count) =>
    Float32List.fromList(List.generate(count, (i) => (from + i).toDouble()));

void main() {
  group('PcmWindowBuffer', () {
    test('恰好凑满一个窗口时产出一个窗口', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 10,
        hopSamples: 10,
        sampleRate: 10,
      );

      final windows = buffer.add(ramp(0, 10));

      expect(windows.length, 1);
      expect(windows.first.startSample, 0);
      expect(windows.first.samples.length, 10);
      expect(windows.first.samples.first, 0);
      expect(windows.first.samples.last, 9);
    });

    test('不足一个窗口时不产出，但样本要留住', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 10,
        hopSamples: 10,
        sampleRate: 10,
      );

      expect(buffer.add(ramp(0, 6)), isEmpty);
      expect(buffer.pendingSamples, 6);

      // 补上剩下 4 个，应该凑成一个从 0 开始的窗口
      final windows = buffer.add(ramp(6, 4));
      expect(windows.length, 1);
      expect(windows.first.startSample, 0);
      expect(windows.first.samples.last, 9);
    });

    test('一块数据里凑出多个窗口', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 4,
        hopSamples: 4,
        sampleRate: 4,
      );

      final windows = buffer.add(ramp(0, 12));

      expect(windows.length, 3);
      expect(windows.map((w) => w.startSample), [0, 4, 8]);
    });

    test('窗口跨越多块数据时起始位置正确', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 6,
        hopSamples: 6,
        sampleRate: 6,
      );

      expect(buffer.add(ramp(0, 2)), isEmpty);
      expect(buffer.add(ramp(2, 2)), isEmpty);
      final windows = buffer.add(ramp(4, 2));

      expect(windows.length, 1);
      expect(windows.first.startSample, 0);
      expect(windows.first.samples, [0, 1, 2, 3, 4, 5]);
    });

    test('步长小于窗口时窗口重叠且起点按步长推进', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 4,
        hopSamples: 2,
        sampleRate: 4,
      );

      final windows = buffer.add(ramp(0, 8));

      // 窗口起点：0, 2, 4；每个窗口 4 个样本
      expect(windows.map((w) => w.startSample), [0, 2, 4]);
      expect(windows[0].samples, [0, 1, 2, 3]);
      expect(windows[1].samples, [2, 3, 4, 5]);
      expect(windows[2].samples, [4, 5, 6, 7]);
      // 消费掉 6 个样本，还剩 2 个在缓冲里
      expect(buffer.pendingSamples, 2);
    });

    test('flush 吐出尾部残料', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 10,
        hopSamples: 10,
        sampleRate: 10,
      );
      buffer.add(ramp(0, 4));

      // 缓冲区只有 10 个样本量级，尾部门限也要相应调小
      final tail = buffer.flush(minTailSamples: 1);

      expect(tail, isNotNull);
      expect(tail!.startSample, 0);
      expect(tail.samples.length, 4);
      expect(buffer.pendingSamples, 0);
    });

    test('尾部残料过短时丢弃', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 1000,
        hopSamples: 1000,
        sampleRate: 1000,
      );
      buffer.add(ramp(0, 10));

      expect(buffer.flush(minTailSamples: 100), isNull);
      expect(buffer.pendingSamples, 0);
    });

    test('空缓冲 flush 返回 null', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 10,
        hopSamples: 10,
        sampleRate: 10,
      );
      expect(buffer.flush(), isNull);
    });

    test('reset 清空缓冲与计数', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 10,
        hopSamples: 10,
        sampleRate: 10,
      );
      buffer.add(ramp(0, 15));
      buffer.reset();

      expect(buffer.pendingSamples, 0);
      expect(buffer.totalReceived, 0);
    });

    test('空输入不改变状态', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 10,
        hopSamples: 10,
        sampleRate: 10,
      );
      expect(buffer.add(Float32List(0)), isEmpty);
      expect(buffer.pendingSamples, 0);
    });

    test('步长大于窗口长度属于配置错误，直接抛异常', () {
      expect(
        () => PcmWindowBuffer(windowSamples: 10, hopSamples: 20, sampleRate: 10),
        throwsArgumentError,
      );
    });

    test('窗口长度非正属于配置错误，直接抛异常', () {
      expect(
        () => PcmWindowBuffer(windowSamples: 0, hopSamples: 0, sampleRate: 10),
        throwsArgumentError,
      );
    });

    test('startSeconds 由采样位置换算', () {
      final buffer = PcmWindowBuffer(
        windowSamples: 16000,
        hopSamples: 16000,
        sampleRate: 16000,
      );
      buffer.add(ramp(0, 16000));
      final windows = buffer.add(ramp(16000, 16000));

      expect(windows.length, 1);
      expect(windows.first.startSeconds, closeTo(1.0, 1e-9));
      expect(windows.first.durationSeconds, closeTo(1.0, 1e-9));
    });
  });
}
