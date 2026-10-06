import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/pcm_ring_buffer.dart';

Float32List seq(int from, int count) =>
    Float32List.fromList(List.generate(count, (i) => (from + i).toDouble()));

void main() {
  group('PcmRingBuffer 基本读写', () {
    test('未写满时按绝对位置取片段', () {
      final ring = PcmRingBuffer(capacitySamples: 100);
      ring.write(seq(0, 50));

      final out = ring.slice(10, 20);

      expect(out, isNotNull);
      expect(out!.length, 10);
      expect(out.first, 10);
      expect(out.last, 19);
    });

    test('写入量不足时记录最新位置', () {
      final ring = PcmRingBuffer(capacitySamples: 100);
      ring.write(seq(0, 30));

      expect(ring.newestSample, 30);
      expect(ring.oldestSample, 0);
      expect(ring.length, 30);
    });

    test('空缓冲取任何片段都返回 null', () {
      final ring = PcmRingBuffer(capacitySamples: 100);
      expect(ring.slice(0, 10), isNull);
      expect(ring.isEmpty, isTrue);
    });

    test('区间为空或反向时返回 null', () {
      final ring = PcmRingBuffer(capacitySamples: 100);
      ring.write(seq(0, 50));

      expect(ring.slice(20, 20), isNull);
      expect(ring.slice(30, 10), isNull);
    });
  });

  group('PcmRingBuffer 环绕覆盖', () {
    test('写满后覆盖最旧的数据', () {
      final ring = PcmRingBuffer(capacitySamples: 10);
      ring.write(seq(0, 10));
      ring.write(seq(10, 10)); // 覆盖 0..9

      expect(ring.oldestSample, 10);
      expect(ring.newestSample, 20);
      expect(ring.length, 10);

      final out = ring.slice(10, 20);
      expect(out, isNotNull);
      expect(out!.first, 10);
      expect(out.last, 19);
    });

    test('跨越环绕点取片段仍然连续', () {
      final ring = PcmRingBuffer(capacitySamples: 10);
      // 写 15 个，覆盖 0..4，保留 5..14
      ring.write(seq(0, 15));

      final out = ring.slice(5, 15);

      expect(out, isNotNull);
      expect(out!.length, 10);
      // 必须是连续的 5,6,...,14，不能因为环形下标回绕而错位
      expect(out, List.generate(10, (i) => (5 + i).toDouble()));
    });

    test('起点已被覆盖时返回 null，不返回截断的音频', () {
      final ring = PcmRingBuffer(capacitySamples: 10);
      ring.write(seq(0, 20)); // 只保留 10..19

      expect(ring.slice(5, 15), isNull,
          reason: '缺了开头就宁可不给，给一段截断的比没有更误导');
    });

    test('终点超出已写入范围时返回 null', () {
      final ring = PcmRingBuffer(capacitySamples: 100);
      ring.write(seq(0, 20));

      expect(ring.slice(10, 25), isNull);
    });

    test('一次写入超过容量时只保留末尾', () {
      final ring = PcmRingBuffer(capacitySamples: 10);
      ring.write(seq(0, 25));

      expect(ring.newestSample, 25);
      expect(ring.oldestSample, 15);

      final out = ring.slice(15, 25);
      expect(out, isNotNull);
      expect(out!.first, 15);
      expect(out.last, 24);
    });
  });

  group('PcmRingBuffer 分块写入', () {
    test('多次小块写入与一次性写入结果一致', () {
      final whole = PcmRingBuffer(capacitySamples: 100);
      whole.write(seq(0, 60));

      final chunked = PcmRingBuffer(capacitySamples: 100);
      for (var i = 0; i < 60; i += 7) {
        final end = (i + 7) > 60 ? 60 : i + 7;
        chunked.write(seq(i, end - i));
      }

      expect(chunked.newestSample, whole.newestSample);
      final a = whole.slice(0, 60)!;
      final b = chunked.slice(0, 60)!;
      expect(b, a);
    });

    test('空块不改变状态', () {
      final ring = PcmRingBuffer(capacitySamples: 10);
      ring.write(Float32List(0));

      expect(ring.isEmpty, isTrue);
      expect(ring.newestSample, 0);
    });
  });

  group('PcmRingBuffer 生命周期', () {
    test('clear 清空位置与数据', () {
      final ring = PcmRingBuffer(capacitySamples: 10);
      ring.write(seq(0, 20));
      ring.clear();

      expect(ring.isEmpty, isTrue);
      expect(ring.newestSample, 0);
      expect(ring.oldestSample, 0);
      expect(ring.slice(0, 5), isNull);
    });

    test('clear 之后绝对序号从零重新开始', () {
      final ring = PcmRingBuffer(capacitySamples: 10);
      ring.write(seq(0, 20));
      ring.clear();
      ring.write(seq(100, 5));

      // clear 重置了计数，所以新数据占的是 0..4 而不是 100..104
      expect(ring.newestSample, 5);
      final out = ring.slice(0, 5);
      expect(out, isNotNull);
      expect(out!.first, 100);
      expect(out.last, 104);
    });
  });
}
