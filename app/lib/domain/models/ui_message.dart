/// 界面要显示的一条错误。
///
/// 和 `RecordingError` 是一个路子：**产生错误的那一层说"是哪种错"**，
/// 界面层按语言渲染（见 `lib/ui/core/l10n/ui_message_text.dart`）。
///
/// 为什么不让 ViewModel 直接拿字符串：ViewModel 是 `ChangeNotifier`，
/// 没有 `BuildContext`，也就查不了本地化。它只能给事实。
///
/// [detail] 放**不用翻译**的那部分——异常原文、文件名、字段名。
/// 那些往往是排查问题时唯一的线索，翻掉了等于把线索也翻没了。
library;

enum UiMessageKind {
  // ---- 报告页 ----
  /// 事件对应的片段文件找不到了（被清理过，或用户删过）。
  reportClipMissing,

  // ---- 数据导出/导入 ----
  /// 弹目录选择器失败。
  archivePickFailed,

  /// 导入/导出过程中抛了没预料到的异常。
  archiveOperationFailed,

  /// 还没配导出目录。
  archiveNoTarget,

  /// 配了目录，但现在用不了（授权被撤销，或目录不在了）。
  archiveTargetUnusable,

  /// 上一次导出/导入还没结束。
  archiveBusy,

  /// 片段写不进导出目录。
  archiveClipWriteFailed,

  /// 会话 JSON 写不进导出目录。
  archiveSessionWriteFailed,

  /// 片段从导出目录读出来失败。
  archiveClipImportFailed,

  /// 导出目录里某个文件读不了。
  archiveUnreadableFile,
}

class UiMessage {
  const UiMessage(this.kind, [this.detail]);

  final UiMessageKind kind;

  /// 不翻译的细节：异常原文、文件名、字段名。
  final String? detail;
}
