import 'package:flutter/widgets.dart';

import '../../../domain/models/ui_message.dart';
import 'l10n_context.dart';

/// 把 [UiMessage] 翻成当前语言的一句话。
///
/// 和 `domain_text.dart` 一个路子：**产生错误的那一层给事实，这里给句子**。
///
/// `detail` 里的东西（异常原文、文件名、字段名）**原样拼进去，不翻译**——
/// 它们往往是排查问题时唯一的线索。见 [UiMessage] 的注释。
extension UiMessageText on UiMessage {
  String message(BuildContext context) => switch (kind) {
        UiMessageKind.reportClipMissing => context.l10n.reportErrorClipMissing,

        UiMessageKind.archivePickFailed =>
          context.l10n.archiveErrorPickFailed(detail ?? ''),
        UiMessageKind.archiveOperationFailed =>
          context.l10n.archiveErrorOperationFailed(detail ?? ''),
        UiMessageKind.archiveNoTarget => context.l10n.archiveErrorNoTarget,
        UiMessageKind.archiveTargetUnusable =>
          context.l10n.archiveErrorTargetUnusable,
        UiMessageKind.archiveBusy => context.l10n.archiveErrorBusy,
        UiMessageKind.archiveClipWriteFailed =>
          context.l10n.archiveErrorClipWriteFailed(detail ?? ''),
        UiMessageKind.archiveSessionWriteFailed =>
          context.l10n.archiveErrorSessionWriteFailed(detail ?? ''),
        UiMessageKind.archiveClipImportFailed =>
          context.l10n.archiveErrorClipImportFailed(detail ?? ''),
        UiMessageKind.archiveUnreadableFile =>
          context.l10n.archiveErrorUnreadableFile(detail ?? ''),
      };
}
