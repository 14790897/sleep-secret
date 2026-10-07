/// 睡眠声音的大类。
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

  /// 喷嚏。
  ///
  /// **从 [cough] 里拆出来的。** 声学上不是一回事：咳嗽是喉部发力，
  /// 喷嚏是爆发性的鼻腔冲气。而且夜间喷嚏往往指向过敏，和咳嗽的原因不同。
  sneeze,

  vocal,
  movement,
  ambient,

  /// 机器声和麦克风自身的噪声（风扇、空调、充电器嗡鸣、风噪）。
  ///
  /// **和 [ambient] 分开的唯一理由是误报**：风扇和空调的低频嗡鸣在频谱上
  /// 极像鼾声，是打鼾检测最大的误报源。混在「环境噪音」里的话，
  /// 界面只能笼统地说「有环境噪音」，说不出关键那句「那是风扇，不是鼾声」。
  deviceNoise,

  silence;

  /// 静音是背景状态，不是声音事件。
  ///
  /// 时间线不画它、统计不计它、事件列表不列它——多个分析函数都依赖
  /// 这个判断，所以放在领域模型里，而不是 UI 层的配色扩展里。
  bool get isRecessive => this == SleepCategory.silence;
}
