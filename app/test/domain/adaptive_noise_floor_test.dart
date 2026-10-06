import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/adaptive_noise_floor.dart';

/// 和 AnalysisConfig 的默认值保持一致，这样测试验证的就是实际会跑的那套参数。
AdaptiveNoiseFloor build({
  double fallback = 0.01,
  int historyWindows = 400,
  double percentile = 0.2,
  int minSamples = 60,
  double multiplier = 3.0,
}) =>
    AdaptiveNoiseFloor(
      historyWindows: historyWindows,
      percentile: percentile,
      minSamples: minSamples,
      multiplier: multiplier,
      lowerBound: fallback / 4,
      upperBound: fallback * 2,
      fallbackThreshold: fallback,
    );

/// 喂 [count] 个相同电平的窗口。
void feed(AdaptiveNoiseFloor v, double rms, int count) {
  for (var i = 0; i < count; i++) {
    v.add(rms);
  }
}

void main() {
  group('样本不足时用固定值', () {
    test('一个样本都没有时就是 fallback', () {
      final v = build();
      expect(v.threshold, closeTo(0.01, 1e-9));
      expect(v.floor, isNull, reason: '样本不够时不该声称估出了噪声底');
    });

    test('差一个样本也还是 fallback', () {
      final v = build(minSamples: 60);
      feed(v, 0.001, 59);
      expect(v.threshold, closeTo(0.01, 1e-9));
      expect(v.floor, isNull);
    });

    test('刚好够了就开始自适应', () {
      final v = build(minSamples: 60);
      feed(v, 0.001, 60);
      expect(v.floor, isNotNull);
      expect(v.threshold, closeTo(0.003, 1e-6),
          reason: '0.001 × 3 = 0.003，在上下界之内');
    });
  });

  group('安静的房间把阈值降下来', () {
    test('这正是不做自适应时会漏掉的情况', () {
      // 真机实测某安静房间的环境电平就是 0.00097 量级，
      // 而固定阈值是 0.01 —— 几乎贴着。自适应把它降到 0.003。
      final v = build();
      feed(v, 0.0009, 200);
      expect(v.threshold, closeTo(0.0027, 1e-6));
      expect(v.threshold, lessThan(0.01));
    });

    test('但不会低于下界', () {
      final v = build();
      feed(v, 0.00001, 200); // 极安静
      expect(v.threshold, closeTo(0.0025, 1e-9),
          reason: '下界是 fallback/4，再安静也不能无限降——'
              '否则底噪的抖动会被当成声音');
    });
  });

  group('吵的房间把阈值抬上去，但有上限', () {
    test('持续空调声', () {
      final v = build();
      feed(v, 0.006, 200);
      expect(v.threshold, closeTo(0.018, 1e-6)); // 0.006 × 3
    });

    test('再吵也不会超过上界', () {
      final v = build();
      feed(v, 0.5, 200); // 荒谬的响度
      expect(v.threshold, closeTo(0.02, 1e-9),
          reason: '上界存在的意义：阈值失控抬高等于把门控变成'
              '"永远不推理"，而报告上只会显示 0 个事件，看不出是坏了');
    });
  });

  group('分位数不被打鼾带偏', () {
    test('打鼾占 30% 时，噪声底仍落在安静那部分', () {
      final v = build();
      // 安静段取 0.002：×3 = 0.006，在上下界之内，能真正看出分位数的作用。
      // 取更小的值会被下界夹住，测出来是边界而不是逻辑。
      feed(v, 0.002, 140); // 70% 安静
      feed(v, 0.25, 60); // 30% 鼾声

      expect(v.threshold, closeTo(0.006, 1e-6),
          reason: '取分位数而不是均值，就是为了这个——'
              '均值是 (140×0.002 + 60×0.25)/200 = 0.076，×3 早就顶到上界 0.02 了，'
              '阈值跟着鼾声涨，越打鼾越检测不到');
    });

    test('打鼾占 90% 时阈值会被推到上限 —— 这是自适应的固有代价', () {
      final v = build();
      feed(v, 0.0008, 20); // 只有 10% 安静
      feed(v, 0.25, 180);
      expect(v.threshold, closeTo(0.02, 1e-9),
          reason: '低分位数也落在鼾声里了。上界限制它最多涨到 2 倍，'
              '不至于彻底失效——但这种情况本身就是自适应解决不了的');
    });
  });

  group('历史窗口', () {
    test('超出容量后丢掉最旧的，不会把早期的安静永久锁住', () {
      final v = build(historyWindows: 100, minSamples: 10);
      feed(v, 0.002, 100);
      expect(v.threshold, closeTo(0.006, 1e-6));

      feed(v, 0.004, 100); // 之后房间变吵（比如开了风扇）
      expect(v.threshold, closeTo(0.012, 1e-6),
          reason: '历史窗口有限，环境变了阈值要跟得上');
      expect(v.sampleCount, 100, reason: '容量固定，不随喂入次数增长');
    });

    test('安静到极限时停在下界，不会一路降下去', () {
      // 下界存在的意义：底噪本身有抖动，阈值太低会把抖动当成声音，
      // 于是整晚每个窗口都送进模型——费电，而且会产出一堆噪声事件。
      final v = build();
      feed(v, 0.000001, 200);
      expect(v.threshold, closeTo(0.0025, 1e-9),
          reason: '下界 = fallback/4 = 0.0025');
    });

    test('reset 之后回到 fallback', () {
      final v = build();
      feed(v, 0.0005, 200);
      expect(v.threshold, lessThan(0.01));

      v.reset();

      expect(v.threshold, closeTo(0.01, 1e-9));
      expect(v.sampleCount, 0);
      expect(v.floor, isNull);
    });
  });
}
