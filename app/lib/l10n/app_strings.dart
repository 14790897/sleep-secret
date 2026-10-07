/// 给**拿不到 `BuildContext` 的地方**用的文案。
///
/// ## 为什么需要它
///
/// 有些用户可见的文案是在完全没有 UI 的环境里产生的：
///
/// - **通知栏**（频道名、标题、正文、权限提醒）——`RecordingRepository` 在
///   `main.dart` 的 `initState` 里就装配好了，生命周期长于任何页面
/// - Android 的**通知渠道名**一旦建立就固化进系统设置，之后切语言不会自动更新
/// - 后台服务更是什么 UI 都没有
///
/// 这些地方不是"忘了传 context"，是**根本没有 context 可传**。
///
/// ## 这是个全局变量，属于不得已
///
/// 所以定了两条规矩，免得它扩散：
/// 1. **只有真的拿不到 `context` 的地方才用它**——widget 里一律用 `context.l10n`
/// 2. 这一层**显式隔离在这一个文件里**，别让 `appStrings` 到处出现
///
/// 值是 `main()` 里按系统语言加载一次、之后由 App 的 `didChangeDependencies`
/// 跟着语言变化刷新（那个回调在语言切换时会重新跑到）。
library;

import 'app_localizations.dart';

AppLocalizations? _current;

/// 记下当前语言的文案。启动时和语言变化时各调一次。
void setAppStrings(AppLocalizations value) => _current = value;

/// 当前语言的文案。
///
/// 没初始化过直接抛。**不要改成返回 null 或兜底成中文**——
/// 那会让通知栏悄悄变成空白或错误语言，比当场崩掉难查得多。
AppLocalizations get appStrings {
  final value = _current;
  if (value == null) {
    throw StateError(
      'appStrings 还没初始化。它应当在 main() 里（runApp 之前）被 setAppStrings '
      '赋一次值；测试里则是 pump 之后由 App 的 didChangeDependencies 赋值。',
    );
  }
  return value;
}
