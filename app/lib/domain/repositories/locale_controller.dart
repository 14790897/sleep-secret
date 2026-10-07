import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;

/// 界面语言的用户偏好。
///
/// **默认是 `null`，也就是跟随系统。** 这必须是默认值：一旦钉死成某个具体
/// 语言，用户把系统语言换掉时 App 就不再跟着变了，而那是绝大多数人
/// 期待的行为。这个开关存在的意义只是给少数人一个覆盖手段。
abstract interface class LocaleController implements Listenable {
  /// 当前偏好。`null` 表示跟随系统。
  Locale? get locale;

  /// 读一次存下来的偏好。幂等。
  Future<void> load();

  /// 改偏好。传 `null` 恢复跟随系统。
  Future<void> setLocale(Locale? value);
}
