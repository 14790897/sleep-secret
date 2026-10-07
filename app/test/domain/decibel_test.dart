import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/decibel.dart';

/// 分贝换算的回归测试。
///
/// ## 这里测的是什么，不是什么
///
/// **测的是换算本身**：RMS 到 dBFS 是纯数学，有确定的答案，错了就是错了。
///
/// **测不了的是"这个数准不准"**——`estimatedDbSpl` 的绝对值取决于一个
/// 假设（满量程约等于 1 Pa），而那个假设对具体某台手机不一定成立。
/// 所以下面那些绝对值断言的作用**不是**"证明它准"，而是：
///
/// - 钉住量级。哪天有人改了参考值，安静房间从 34 dB 变成 84 dB，
///   这里会红——那是个需要有人看一眼的改动。
/// - 钉住**单调性**。这才是不依赖参考值的性质：声音变大，分贝必须变大。
///   它错了的话，界面上的分贝条会朝反方向走。
void main() {
  group('dbFs —— 这个是准的', () {
    test('满量程是 0 dB', () {
      expect(dbFs(1.0), closeTo(0, 1e-9));
    });

    test('减半是约 -6 dB', () {
      // 20*log10(0.5) = -6.0206
      expect(dbFs(0.5), closeTo(-6.0206, 1e-3));
    });

    test('十倍是 -20 dB', () {
      expect(dbFs(0.1), closeTo(-20, 1e-9));
    });

    test('0 和负数不会算出负无穷', () {
      // log10(0) 是负无穷。不挡住的话界面上会显示 -Infinity
      expect(dbFs(0), kSilenceDbFs);
      expect(dbFs(-0.5), kSilenceDbFs);
    });

    test('极小的值夹在下限，不产生没意义的数字', () {
      expect(dbFs(1e-12), kSilenceDbFs);
      expect(dbFs(1e-9), greaterThanOrEqualTo(kSilenceDbFs));
    });
  });

  group('estimatedDbSpl —— 估算，只钉量级', () {
    test('安静房间是三十几分贝', () {
      // 真实安静房间约 30~40 dB SPL。对不上说明参考值被改坏了。
      expect(estimatedDbSpl(0.001), closeTo(34, 1.5));
    });

    test('大声鼾声是八十几分贝', () {
      // 大声打鼾 60~90 dB SPL
      expect(estimatedDbSpl(0.3), closeTo(83.5, 1.5));
    });

    test('取整之后是整数，且不会出负数', () {
      expect(estimatedDbSplRounded(0.3), 84);
      expect(estimatedDbSplRounded(0), 0,
          reason: '静音时应当是 0 而不是负数——界面上没有负分贝这回事');
    });

    test('单调：声音变大，分贝一定不会变小', () {
      // 这条**不依赖任何参考值**，是真正重要的那条性质。
      // 它错了的话，界面上的分贝条会朝反方向走。
      //
      // ⚠️ 是**不递减**，不是严格递增：最底下几个值会被 `kSilenceDbFs`
      // 夹平（那是为了挡住 log10(0) 的负无穷）。第一版这里写成了严格递增，
      // 被这条下限打脸了——那正是"测试比作者想得更清楚"的时候。
      const samples = [0.0, 1e-6, 0.0001, 0.001, 0.01, 0.1, 0.5, 1.0];
      for (var i = 1; i < samples.length; i++) {
        expect(estimatedDbSpl(samples[i]),
            greaterThanOrEqualTo(estimatedDbSpl(samples[i - 1])),
            reason: 'RMS ${samples[i]} 比 ${samples[i - 1]} 大，分贝却更小');
      }
    });

    test('但下限之上必须是严格递增的', () {
      // 上面那条放宽到"不递减"之后，得单独守住"真的在变"——
      // 否则把整个函数改成返回常数也能过。
      const audible = [1e-4, 0.001, 0.01, 0.1, 0.5, 1.0];
      for (var i = 1; i < audible.length; i++) {
        expect(estimatedDbSpl(audible[i]),
            greaterThan(estimatedDbSpl(audible[i - 1])),
            reason: 'RMS ${audible[i]} 和 ${audible[i - 1]} 应当对应不同的分贝');
      }
    });
  });
}
