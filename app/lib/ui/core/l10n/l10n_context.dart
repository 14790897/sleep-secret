import 'package:flutter/widgets.dart';

import '../../../l10n/app_localizations.dart';

/// `context.l10n.tabSleep`，代替 `AppLocalizations.of(context)!.tabSleep`。
///
/// 为什么要包一层：那个 `!` 要在每个调用点写一遍，而且**写不出来的时候
/// 是运行时才炸**，报的还是个没头没尾的 null 错误。这里换成一句说得清楚的话，
/// 直接点名最可能的原因。
extension L10nContext on BuildContext {
  AppLocalizations get l10n {
    final value = AppLocalizations.of(this);
    if (value == null) {
      throw FlutterError(
        '这个 BuildContext 上取不到 AppLocalizations。\n'
        '正常情况下不可能——多半是某处自己拼了个裸 MaterialApp 却没带上\n'
        'AppLocalizations.localizationsDelegates。测试里的 pump 辅助函数\n'
        '是最容易漏的地方。',
      );
    }
    return value;
  }
}
