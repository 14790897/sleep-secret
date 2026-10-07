/// 睡眠声音的 7 个大类。
///
/// 由 AudioSet 的 527 个细类聚合而来（见 assets/models/sleep_class_map.json），
/// 是 App 内部唯一的类别表示，UI 与算法都用它。
///
/// ⚠️ **这里刻意不带展示名。** 曾经带过（`snore('鼾声')`），加多语言时才看出来
/// 那不是个便利：它同时被当成 `sleep_class_map.json` 的**数据键**在用
/// （`lib/data/models/sleep_class_map.dart` 按它反查枚举），改一次界面文案
/// 就会让整张映射表读不出来。
///
/// 现在分得很清楚：
/// - **数据**用 `.name`（英文，`snore`/`breathing`/…）——数据库、导出文件、映射表
/// - **展示**在界面层按语言取，见 `lib/ui/core/l10n/category_l10n.dart`
enum SleepCategory {
  snore,
  breathing,
  cough,
  vocal,
  movement,
  ambient,
  silence;

  /// 静音是背景状态，不是声音事件。
  ///
  /// 时间线不画它、统计不计它、事件列表不列它——多个分析函数都依赖
  /// 这个判断，所以放在领域模型里，而不是 UI 层的配色扩展里。
  bool get isRecessive => this == SleepCategory.silence;
}
