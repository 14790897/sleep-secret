import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show Locale;

import '../../domain/repositories/locale_controller.dart';
import '../../l10n/app_localizations.dart';
import '../services/session_database.dart';

/// 把界面语言偏好存进设置表。和录音设置用同一张表、同一个库。
class LocaleRepository extends ChangeNotifier implements LocaleController {
  LocaleRepository({required this._database});

  static const String _key = 'app_locale';

  final SessionDatabase _database;

  Locale? _locale;
  bool _loaded = false;

  @override
  Locale? get locale => _locale;

  @override
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    await _database.open();
    _locale = _parse(await _database.readStringSetting(_key));
    notifyListeners();
  }

  @override
  Future<void> setLocale(Locale? value) async {
    _locale = value;
    // 先通知、再落库：切语言是立刻能看到的事，不该等一次磁盘写。
    // 落库失败最坏是下次启动回到跟随系统，不影响这一次。
    notifyListeners();
    await _database.open();
    await _database.writeStringSetting(_key, value?.languageCode);
  }

  /// 只认支持列表里的语言。
  ///
  /// 存了个不认识的（手改过库、或者从装了更多语言的版本降级回来）就当作
  /// 没设过——**静默接受一个不支持的 locale 会让整个界面变成一堆 key**，
  /// 那比回到跟随系统难查得多。
  static Locale? _parse(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    for (final supported in AppLocalizations.supportedLocales) {
      if (supported.languageCode == raw) return supported;
    }
    return null;
  }
}
