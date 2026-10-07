import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/l10n/app_localizations.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';
import 'package:sleep_secret/ui/features/home/views/home_view.dart';
import 'package:sleep_secret/ui/features/recording/views/recording_view.dart';
import 'package:sleep_secret/ui/features/report/views/report_view.dart';
import 'package:sleep_secret/ui/features/recording/view_models/recording_view_model.dart';
import 'package:sleep_secret/ui/features/report/view_models/report_view_model.dart';

import '../helpers/fake_clip_services.dart';
import '../helpers/fake_recording_controller.dart';
import '../helpers/fake_services.dart';
import '../helpers/pump_app.dart';

/// 多语言管线的把关测试。
///
/// ## 为什么需要专门的测试
///
/// 缺翻译的时候 Flutter **不报错，而是静默退回模板语言（中文）**。
/// 所以「英文界面里冒出一句中文」这件事，在中文环境下跑测试**永远发现不了**——
/// 而那是这个功能最容易出的错：加了个新 key，只写了中文那份。
///
/// 这里用两种互补的办法堵它：
/// - **结构上**：两份 ARB 的 key 必须一一对应（见下面第一组）
/// - **渲染上**：英文渲染下，页面上不该出现汉字（第二组）
///
/// 光有结构检查不够——直接写死在代码里、根本没进 ARB 的中文它抓不到。
/// 光有渲染检查也不够——它只能覆盖被渲染到的地方。
void main() {
  group('两份 ARB 的 key 必须一一对应', () {
    /// 读一份 arb，去掉 `@@locale` 和 `@key` 这类元数据，只留真正的文案 key。
    Set<String> keysOf(String path) {
      final raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
      return raw.keys
          .where((k) => !k.startsWith('@'))
          .toSet();
    }

    test('英文没有漏翻，也没有多出来', () {
      final zh = keysOf('lib/l10n/app_zh.arb');
      final en = keysOf('lib/l10n/app_en.arb');

      expect(zh.difference(en), isEmpty,
          reason: '这些 key 只有中文、没有英文，英文用户会看到中文：'
              '${zh.difference(en)}');
      expect(en.difference(zh), isEmpty,
          reason: '这些 key 只在英文里有，中文那份缺了（模板是中文）：'
              '${en.difference(zh)}');
      expect(zh, isNotEmpty, reason: '一个 key 都没有，多半是路径读错了');
    });
  });

  group('渲染', () {
    late FakeRecordingController controller;
    late RecordingViewModel recordingVm;

    setUp(() {
      controller = FakeRecordingController();
      recordingVm = RecordingViewModel(controller: controller);
    });

    tearDown(() => recordingVm.dispose());

    Widget homeView() => HomeView(
          localeController: FakeLocaleController(),
          recordingViewModel: recordingVm,
          reportViewModelFactory: (session) => ReportViewModel(
            session: session,
            clipStore: FakeAudioClipStore(),
            player: FakeEventPlayer(),
          ),
        );

    /// 泵起来，并**切到关于页**。
    ///
    /// ⚠️ 必须真的点过去。`HomeView` 用 `IndexedStack`，它**只构建选中的那一页**——
    /// 没点之前关于页的文字根本不在 widget 树上，任何对它子树的断言都会
    /// 在空集合上"通过"。这条踩过：英文残留检查一开始就是这么假绿的。
    Future<void> pumpAbout(WidgetTester tester, String lang) async {
      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
          localizedApp(home: homeView(), locale: Locale(lang)));
      await tester.pumpAndSettle();

      // 按图标而不是文字找——文字本身就是被测的对象。
      // 幂等：同一棵树里连着切两次语言时，'关于' 已经是选中态，
      // 图标换成了 Icons.info，找不到未选中那个。
      final aboutTab = find.byIcon(Icons.info_outline);
      if (aboutTab.evaluate().isNotEmpty) {
        await tester.tap(aboutTab);
        await tester.pumpAndSettle();
      }
    }

    /// 关于页那棵子树里的文字。
    ///
    /// 为什么要圈起来：首页（录音页）还没迁完，整棵树里必然混着中文，
    /// 全局扫会一直红。按 key 圈出已迁完的那部分，等其余页面迁完了
    /// 再把范围放宽——那时候这条断言才真正开始干活。
    List<String> aboutTexts(WidgetTester tester) => [
          for (final t in tester.widgetList<Text>(find.descendant(
            of: find.byKey(HomeKeys.aboutView),
            matching: find.byType(Text),
          )))
            if (t.data != null) t.data!,
        ];

    /// 底部导航上的标签。
    ///
    /// 限定在 `NavigationBar` 里找，不是为了好看——「关于」这个词同时出现在
    /// 底栏和关于页的标题上，全局找会数出两个。
    List<String> navLabels(WidgetTester tester) => [
          for (final t in tester.widgetList<Text>(find.descendant(
            of: find.byType(NavigationBar),
            matching: find.byType(Text),
          )))
            if (t.data != null) t.data!,
        ];

    testWidgets('中文环境下底部导航是中文', (tester) async {
      await pumpAbout(tester, 'zh');

      expect(navLabels(tester), containsAll(['睡眠', '报告', '关于']));
    });

    testWidgets('英文环境下底部导航是英文', (tester) async {
      await pumpAbout(tester, 'en');

      expect(navLabels(tester), containsAll(['Sleep', 'Reports', 'About']));
      expect(navLabels(tester).any((t) => t == '睡眠'), isFalse,
          reason: '切到英文了，中文那份不该还在');
    });

    testWidgets('系统语言不在支持列表里时，回退到英文', (tester) async {
      // ⚠️ supportedLocales 的顺序是**代码生成时按 arb 文件名排的**（en, zh），
      // 不是我们定的。但落点正好是对的：中文用户匹配 zh，其余语言落到 en
      // ——那正是这个 App 想要的国际回退。
      //
      // 这条断言把它钉住：哪天加了第三种语言、生成顺序变了，
      // 会有人立刻发现，而不是等一个德国用户来报「界面怎么变中文了」。
      await pumpAbout(tester, 'de');

      expect(find.text('Sleep'), findsOneWidget);
      expect(find.text('睡眠'), findsNothing);
    });

    testWidgets('切到英文，关于页整页文案跟着变', (tester) async {
      await pumpAbout(tester, 'zh');
      expect(aboutTexts(tester), contains('这个应用做什么'));

      await pumpAbout(tester, 'en');
      final en = aboutTexts(tester);
      expect(en, contains('What this app does'));
      expect(en, contains("What it isn't"));
      expect(en, isNot(contains('这个应用做什么')));
    });

    testWidgets('英文渲染下，关于页不该残留任何中文', (tester) async {
      await pumpAbout(tester, 'en');

      // 中日韩统一表意文字。这个 App 只可能中英混，查这个范围就够。
      final cjk = RegExp('[一-鿿]');
      final offenders = aboutTexts(tester)
          .where((t) => cjk.hasMatch(t) && !intentionallyChinese.contains(t))
          .toList();

      // 先确认子树真的建出来了 —— 空集合上做 isEmpty 永远是 true，
      // 那就是一条永远绿、也永远没用的断言
      expect(aboutTexts(tester), isNotEmpty,
          reason: '关于页的子树是空的，这条断言会假绿');

      expect(offenders, isEmpty, reason: _cjkReport('关于页', offenders));
    });
  });

  group('报告页整页渲染', () {
    /// 一晚普通数据：有鼾声、有干扰、有环境噪音。
    ///
    /// 刻意凑齐这几类，是因为它们分别走诊断卡、评分构成、类别分布、
    /// 片段卡几条不同的渲染路径——只放一条事件的话，漏掉的那几条
    /// 在这条测试里看不见。
    RecordingSession night() => _build(1791278973396);

    testWidgets('英文渲染下，报告页不该残留任何中文', (tester) async {
      tester.view.physicalSize = const Size(900, 5000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final clips = FakeAudioClipStore();
      final player = FakeEventPlayer();
      addTearDown(player.dispose);

      await tester.pumpWidget(localizedApp(
        locale: const Locale('en'),
        home: ReportView(
          viewModel: ReportViewModel(
            session: night(),
            clipStore: clips,
            player: player,
          ),
        ),
      ));
      await tester.pumpAndSettle();

      final texts = [
        for (final t in tester.widgetList<Text>(find.byType(Text)))
          if (t.data != null) t.data!,
      ];
      expect(texts, isNotEmpty, reason: '整棵树没有文字，这条断言会假绿');

      final cjk = RegExp('[一-鿿]');
      final offenders = texts.where((t) => cjk.hasMatch(t)).toList();
      expect(offenders, isEmpty, reason: _cjkReport('报告页', offenders));
    });
  });

  _recordingPageCheck();

  group('手动切换语言', () {
    testWidgets('在关于页选 English，整个界面立刻跟着变', (tester) async {
      final locale = FakeLocaleController();
      final vm = RecordingViewModel(controller: FakeRecordingController());
      addTearDown(vm.dispose);

      tester.view.physicalSize = const Size(900, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 接线方式和 main.dart 一致：MaterialApp.locale 绑在控制器上，
      // null 表示跟随系统。这条测的就是那根线接没接对。
      await tester.pumpWidget(ListenableBuilder(
        listenable: locale,
        builder: (context, _) => MaterialApp(
          locale: locale.locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: HomeView(
            localeController: locale,
            recordingViewModel: vm,
            reportViewModelFactory: (session) => ReportViewModel(
              session: session,
              clipStore: FakeAudioClipStore(),
              player: FakeEventPlayer(),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();

      // 测试环境的系统语言是 en_US，先手动钉成中文再试切换，
      // 否则一上来就是英文，看不出"切换"有没有生效
      await locale.setLocale(const Locale('zh'));
      await tester.pumpAndSettle();
      expect(find.text('睡眠'), findsOneWidget);

      // 进关于页，选 English
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('English'));
      await tester.pumpAndSettle();

      expect(find.text('Sleep'), findsOneWidget,
          reason: '选了 English 之后底部导航该是英文——那根线没接上的话这里会红');
      expect(find.text('睡眠'), findsNothing);
    });
  });
}

/// 录音页也要查一遍：它是用户打开 App 看到的第一屏，
/// 而且有「使用说明」那种整段的文案，最容易漏。
void _recordingPageCheck() {
  testWidgets('英文渲染下，录音页不该残留任何中文', (tester) async {
    final vm = RecordingViewModel(controller: FakeRecordingController());
    addTearDown(vm.dispose);

    tester.view.physicalSize = const Size(900, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(localizedApp(
      locale: const Locale('en'),
      home: RecordingView(viewModel: vm),
    ));
    await tester.pumpAndSettle();

    final texts = [
      for (final t in tester.widgetList<Text>(find.byType(Text)))
        if (t.data != null) t.data!,
    ];
    expect(texts, isNotEmpty, reason: '整棵树没有文字，这条断言会假绿');

    final cjk = RegExp('[一-鿿]');
    expect(texts.where((t) => cjk.hasMatch(t)).toList(), isEmpty,
        reason: _cjkReport(
            '录音页', texts.where((t) => cjk.hasMatch(t)).toList()));
  });
}

/// **有意保留中文**的文案。
///
/// 语言选择器里的「简体中文」就该用中文写——把语言名翻成
/// "Simplified Chinese"，只看得懂中文的人反而找不到自己那一项。
/// 这是少数几个"不该翻译"的地方，所以显式列出来，而不是放宽整条断言。
const Set<String> intentionallyChinese = {'简体中文'};

/// 拼出一份看得懂的中文残留报告。
String _cjkReport(String where, List<String> offenders) =>
    '$where 这些文案没有英文翻译：\n'
    '${offenders.map((t) => '  - $t').join('\n')}\n'
    '（缺翻译时 Flutter 静默退回模板语言，不会报错——'
    '这类断言是唯一能发现它的地方）';

/// 造一晚带事件的数据。
RecordingSession _build(int startMs) {
  final start = DateTime.fromMillisecondsSinceEpoch(startMs);
  SoundEvent ev(SleepCategory label, double at, double dur, {String? clip}) =>
      SoundEvent(
        label: label,
        startSeconds: at,
        durationSeconds: dur,
        confidence: 0.8,
        snoreProbability: label == SleepCategory.snore ? 0.8 : 0.01,
        windowCount: (dur / 3).round(),
        clipPath: clip,
      );
  return RecordingSession(
    id: 1,
    startedAt: start,
    endedAt: start.add(const Duration(hours: 8)),
    events: [
      ev(SleepCategory.snore, 3600, 180, clip: 'a/1.wav'),
      ev(SleepCategory.cough, 7200, 12),
      ev(SleepCategory.ambient, 9000, 600),
      ev(SleepCategory.breathing, 2000, 900),
    ],
    stats: const SessionStats(
      analyzedSeconds: 28000,
      windowsTotal: 9330,
      windowsInferred: 3500,
      windowsVadSkipped: 5830,
      windowsLowConfidence: 3100,
      eventCount: 4,
      snoreEventCount: 1,
      snoreSeconds: 180,
      categoryDistribution: {},
    ),
  );
}
