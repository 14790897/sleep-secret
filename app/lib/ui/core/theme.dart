import 'package:flutter/material.dart';

import '../../domain/models/sleep_category.dart';

/// 应用配色。
///
/// 深色午夜蓝，参考蜗牛睡眠的夜间风格——整夜使用的应用不能是亮白底，
/// 半夜亮屏太刺眼。
///
/// **数据色不是挑好看的，是跑验证器跑出来的。** 见下方 [SoundClass] 的说明。
class AppColors {
  const AppColors._();

  static const Color midnight = Color(0xFF0B1026);
  static const Color surface = Color(0xFF161D38);
  static const Color surfaceHigh = Color(0xFF1F2749);

  /// 非数据用途的强调色（按钮、标题竖条）。
  static const Color accent = Color(0xFF3987E5);

  static const Color textDim = Color(0xFF8B94B8);
  static const Color divider = Color(0xFF2A3355);

  // ---- 状态色（固定，不随主题变）----
  // 只用于仪表盘这类「单一状态」场景，且必须与文字标签同时出现，
  // 不能只靠颜色表意。
  static const Color statusGood = Color(0xFF0CA30C);
  static const Color statusWarning = Color(0xFFFAB219);
  static const Color statusSerious = Color(0xFFEC835A);
  static const Color statusCritical = Color(0xFFD03B3B);
}

/// 时间线上的声音大类。
///
/// 只有 3 个颜色，这是**验证器给出的硬上限**：声音时间线上任意两类都可能
/// 相邻，所以适用「全配对」判据。用 dataviz skill 的验证器跑下来，
/// 3 色全配对通过（最差 ΔE 9.4 deutan / 20.9 正常视力），
/// 第 4 色就会掉到 ΔE 4.8（黄↔橙），而 skill 明确规定这种 hard fail
/// 不能用辅助编码豁免。
///
/// 蜗牛睡眠的时间线同样只用 3 个颜色，是被同一个约束逼出来的。
///
/// 7 个细类靠**柱高**这个独立通道区分（见 [timelineWeight]），
/// 精确类别则由事件列表和点击查看给出。
enum SoundClass {
  /// 鼾声：最需要被看见的。
  snore(Color(0xFFD95926)),

  /// 其他突发声音：咳嗽、梦话、翻身。
  event(Color(0xFF3987E5)),

  /// 背景声：呼吸、环境噪音。
  background(Color(0xFF199E70));

  const SoundClass(this.color);

  final Color color;

  // 原先这里还有个 `label`（'鼾声'/'其他声音'/'呼吸/环境'）。它被拿去当
  // `CategoryLegend` 的 **map 键**用了，于是改一次界面文案就会让图例读不出来。
  // 展示名现在在界面层按语言渲染，见 `lib/ui/core/l10n/domain_text.dart`。
}

extension SleepCategoryStyle on SleepCategory {
  /// 归入哪个时间线大类。
  SoundClass get soundClass => switch (this) {
        SleepCategory.snore => SoundClass.snore,
        SleepCategory.cough ||
        SleepCategory.vocal ||
        SleepCategory.movement =>
          SoundClass.event,
        SleepCategory.breathing || SleepCategory.ambient => SoundClass.background,
        SleepCategory.silence => SoundClass.background,
      };

  /// 时间线上的柱高权重。同色类内靠它区分细类——这是颜色之外的第二编码通道。
  ///
  /// ⚠️ **环境的权重不能压到 0.10 以下**：时间线上还画了一条 `maxBar * 0.10`
  /// 的底纹轨道当"安静"底色，柱子比轨道还矮就跟背景分不开了。
  /// 0.2 大约是能看清的下限（108px 的柱区里约 22px）。
  ///
  /// 呼吸（0.45）和环境（0.2）**同为背景绿色**，柱高是时间线上唯一区分它们的通道，
  /// 所以两者之间要留出明显的落差。
  double get timelineWeight => switch (this) {
        SleepCategory.snore => 1.0,
        SleepCategory.vocal => 0.82,
        SleepCategory.cough => 0.68,
        SleepCategory.movement => 0.55,
        SleepCategory.breathing => 0.45,
        SleepCategory.ambient => 0.2,
        SleepCategory.silence => 0.10,
      };
}

/// 时间线上那条「安静」底纹轨道的柱高权重。
///
/// 和 [SleepCategory.timelineWeight] 是**耦合的**：任何一类的柱高都不能低于它，
/// 否则那个类会和背景轨道分不开。两个值放在同一个文件里就是为了让这个约束看得见，
/// 改一个的时候别忘了另一个。`test/ui/timeline_encoding_test.dart` 会拦住写错的情况。
const double kTimelineTrackWeight = 0.10;

ThemeData buildAppTheme() {
  final base = ThemeData(
    brightness: Brightness.dark,
    useMaterial3: true,
    colorSchemeSeed: AppColors.accent,
  );

  return base.copyWith(
    scaffoldBackgroundColor: AppColors.midnight,
    colorScheme: base.colorScheme.copyWith(
      surface: AppColors.midnight,
      surfaceContainerHighest: AppColors.surfaceHigh,
      primary: AppColors.accent,
    ),
    cardTheme: const CardThemeData(
      color: AppColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(14)),
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.midnight,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: AppColors.surface,
      indicatorColor: Color(0x333987E5),
      elevation: 0,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 11, color: AppColors.textDim),
      ),
    ),
    dividerTheme: const DividerThemeData(color: AppColors.divider, space: 1),
  );
}
