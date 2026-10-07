/// 一次导出/导入的结果。
class ArchiveOutcome {
  const ArchiveOutcome({
    this.sessions = 0,
    this.skipped = 0,
    this.clips = 0,
    this.clipsMissing = 0,
    this.problems = const [],
  });

  /// 实际写出 / 导入的会话数。
  final int sessions;

  /// 跳过的会话数（导入时已存在、或文件读不了）。
  final int skipped;

  /// 搬运成功的片段文件数。
  final int clips;

  /// 找不到来源、没能搬运的片段数。
  ///
  /// **不当成错误**——片段可能被用户在系统里删过，或者那晚本来就设了不保留。
  final int clipsMissing;

  /// 具体哪儿不对（读不了的文件）。**给用户看的**，所以要能看懂。
  final List<String> problems;

  bool get isClean => problems.isEmpty;
}

/// 把分析结果导出到用户指定的地方、或从那里导入。
abstract interface class ArchiveController {
  /// 读一次配置（并检查目标还能不能用）。幂等。
  ///
  /// **和录音那边不一样**：那边的设置只在开录时加载就够了，
  /// 这边的界面一打开就要显示当前目录，所以要能主动调。
  Future<void> load();

  /// 当前配置的导出目录描述（路径或 URI）。没配过就是 null。
  String? get exportTargetDescription;

  /// 当前配置还能用吗。SAF 的授权可能被用户在系统设置里撤销。
  bool get exportTargetUsable;

  /// 弹目录选择器让用户配一个。用户取消返回 false。
  Future<bool> chooseExportTarget();

  /// 取消配置。
  Future<void> clearExportTarget();

  /// 导出全部会话。没配目录时抛 [StateError]。
  Future<ArchiveOutcome> exportAll();

  /// 从配置的目录导入（已存在的按开始时刻去重）。
  Future<ArchiveOutcome> importAll();

  /// 上次操作的结果，给界面显示。没做过就是 null。
  ArchiveOutcome? get lastOutcome;

  /// 上一次操作是导出还是导入。
  bool get lastWasExport;

  /// 正在导出/导入。界面上要禁用按钮，否则连点会去重失败。
  bool get busy;

  /// 状态变化流。
  Stream<void> get changes;

  void dispose();
}
