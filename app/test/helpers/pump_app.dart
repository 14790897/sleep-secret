import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/l10n/app_localizations.dart';
import 'package:sleep_secret/l10n/app_strings.dart';
import 'package:sleep_secret/ui/core/theme.dart';

/// 测试里那个 `MaterialApp` 的**唯一**构造点。
///
/// ## 为什么不能各自 new
///
/// 加多语言之前，`test/ui/` 下六个文件各自 new 了一个裸 `MaterialApp`。
/// 那种写法的问题是：`localizationsDelegates` 这种东西**加漏一个地方
/// 不会编译报错，只会让那个文件里的断言以看不懂的方式失败**。
/// 九个构造点就是九次漂移的机会。
///
/// ## 为什么测试必须钉死 locale
///
/// `flutter_test` 的默认平台 locale 是 **en_US**。`MaterialApp` 在没有
/// 精确匹配时回退到 `supportedLocales` 的第一项——那个顺序是代码生成时
/// 按 arb 文件名排的，不是我们说了算。所以不钉的话**测试会渲染成英文**，
/// 于是所有 `find.text('鼾声录音')` 这一类的断言集体失败，
/// 而且报的是「找不到」，看不出跟语言有关。
///
/// 钉成中文之后，测试断言的就是用户在这个 App 的主场语言下看到的东西。
/// 英文那一侧由 `test/ui/localization_test.dart` 单独把关。
Widget localizedApp({
  required Widget home,
  Locale locale = const Locale('zh'),
  Map<String, WidgetBuilder>? routes,
  bool animate = false,
}) =>
    MaterialApp(
      theme: buildAppTheme(),
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // ⚠️ 默认**关掉 ticker**。
      //
      // 录音页那颗月亮是**无限循环**的动效（呼吸 / 飘 Z），而
      // `pumpAndSettle` 等的是"没有待调度的帧"——只要它在动，就永远等不到，
      // 于是**所有 pump 了录音页的测试都会超时**。这不是某个测试的问题，
      // 而是"页面上有个永不停的动画"这件事本身和 pumpAndSettle 不兼容。
      //
      // 动画是装饰，测试管行为，所以默认关掉。
      // 要验动效本身的那条测试传 `animate: true`（见
      // `recording_view_test.dart` 的「月亮在动」）。
      home: TickerMode(enabled: animate, child: home),
      routes: routes ?? const <String, WidgetBuilder>{},
    );

/// 给**非 widget 测试**用：把那份"给后台用的"文案初始化成指定语言。
///
/// widget 测试由 [localizedApp] 里的同步器负责；纯 `test()` 里根本没有
/// widget 树，而被测的代码（通知栏标题、录音错误）恰好要用 `appStrings`。
/// 不初始化它会直接抛——这是故意的，静默兜底成中文会让通知栏
/// 悄悄变成错误的语言。
Future<void> initAppStringsForTest([String lang = 'zh']) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setAppStrings(await AppLocalizations.delegate.load(Locale(lang)));
}
