import '../models/recording_session.dart';
import '../models/ui_message.dart';

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
  ///
  /// 存的是结构化的事实（哪一种 + 不翻译的细节），不是拼好的句子——
  /// 拼句子要按语言来，而这一层拿不到 `BuildContext`。
  final List<UiMessage> problems;

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

  /// 把导出目标切到 WebDAV（坚果云）。
  ///
  /// 凭据由界面那边先写进 Keystore（见 `WebDavSettingsStore`），
  /// 这里只把「目标类型」记下来。**不在这里发网络请求**——
  /// 它好不好用由「测试连接」和真正的同步去发现，那时候的错误信息具体得多。
  Future<void> useWebDavTarget();

  /// 取消配置。
  Future<void> clearExportTarget();

  /// 导出全部会话。
  Future<ArchiveOutcome> exportAll();

  /// 只导出这一晚。**自动导出用这个，不要用 [exportAll]。**
  ///
  /// 用 exportAll 的话，每录一晚都会把之前每一晚的片段重新搬一遍——
  /// 时间越久越慢，网盘那边也得把这些没变过的文件重传一次。
  Future<ArchiveOutcome> exportSession(RecordingSession session);

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
