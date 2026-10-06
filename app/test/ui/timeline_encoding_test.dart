import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/ui/core/theme.dart';

/// 时间线柱高的**编码约束**。
///
/// 时间线用两套通道表达信息：**颜色**表示大类（鼾声/其他/背景），
/// **柱高**表示"这个声音有多值得注意"，也用来在同一颜色内区分细类。
///
/// 这套编码有几个不能破的约束，破了不会报错，只会让图变得读不懂——
/// 所以拿测试锁住。参见 `reference_dataviz_palette.md` 里那条教训：
/// 配色和编码不能靠眼睛判断。
void main() {
  group('柱高顺序', () {
    test('从鼾声到静音严格递减', () {
      const order = [
        SleepCategory.snore,
        SleepCategory.vocal,
        SleepCategory.cough,
        SleepCategory.movement,
        SleepCategory.breathing,
        SleepCategory.ambient,
        SleepCategory.silence,
      ];

      for (var i = 0; i < order.length - 1; i++) {
        final higher = order[i].timelineWeight;
        final lower = order[i + 1].timelineWeight;
        expect(higher, greaterThan(lower),
            reason: '${order[i].label}（$higher）应当高于 '
                '${order[i + 1].label}（$lower）——'
                '柱高是"多值得注意"的编码，顺序错了图就读不懂了');
      }
    });

    test('鼾声顶格，是这个应用的核心信号', () {
      expect(SleepCategory.snore.timelineWeight, 1.0);
    });

    test('环境噪音明显低于呼吸声', () {
      // 这两个**同色**（都是背景绿），柱高是时间线上唯一区分它们的通道。
      // 落差太小的话，屏幕上就是一排高矮差不多的绿条。
      final gap = SleepCategory.breathing.timelineWeight -
          SleepCategory.ambient.timelineWeight;
      expect(gap, greaterThanOrEqualTo(0.2),
          reason: '呼吸和环境的柱高只差 $gap，同色时区分不开');
    });
  });

  group('谁会被画出来', () {
    test('画出来的每一类都不能矮过底纹轨道', () {
      // 时间线底部有一条 maxBar * kTimelineTrackWeight 的底纹当"安静"底色。
      // 柱子比它还矮，那个类在屏幕上就和背景分不开了。
      for (final c in SleepCategory.values) {
        if (c.isRecessive) continue; // 静音根本不画
        expect(c.timelineWeight, greaterThan(kTimelineTrackWeight),
            reason: '${c.label} 的柱高 ${c.timelineWeight} 不高于底纹轨道 '
                '$kTimelineTrackWeight，会和背景糊在一起');
      }
    });

    test('静音是唯一不被画的类别', () {
      // 它是背景状态不是声音事件，时间线、统计、事件列表都不该出现它
      expect(SleepCategory.silence.isRecessive, isTrue);
      expect(
        SleepCategory.values.where((c) => c.isRecessive).toList(),
        [SleepCategory.silence],
      );
    });
  });
}
