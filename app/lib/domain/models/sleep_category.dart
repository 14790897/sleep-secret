/// 睡眠声音的 7 个大类。
///
/// 由 AudioSet 的 527 个细类聚合而来（见 assets/models/sleep_class_map.json），
/// 是 App 内部唯一的类别表示，UI 与算法都用它。
enum SleepCategory {
  snore('鼾声'),
  breathing('呼吸声'),
  cough('咳嗽清嗓'),
  vocal('人声梦话'),
  movement('体动床响'),
  ambient('环境噪音'),
  silence('静音');

  const SleepCategory(this.label);

  /// 界面展示用的中文名。
  final String label;

  /// 静音是背景状态，不是声音事件。
  ///
  /// 时间线不画它、统计不计它、事件列表不列它——多个分析函数都依赖
  /// 这个判断，所以放在领域模型里，而不是 UI 层的配色扩展里。
  bool get isRecessive => this == SleepCategory.silence;
}
