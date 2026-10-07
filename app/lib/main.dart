import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import 'data/repositories/archive_repository.dart';
import 'data/repositories/locale_repository.dart';
import 'data/repositories/recording_repository.dart';
import 'data/repositories/sleep_analysis_repository.dart';
import 'data/services/archive_service.dart';
import 'data/services/audio_capture_service.dart';
import 'data/services/database_factory_setup.dart';
import 'data/services/diagnostic_fixtures.dart';
import 'data/services/directory_export_target.dart';
import 'data/services/event_player.dart';
import 'data/services/file_audio_clip_store.dart';
import 'data/services/foreground_service_controller.dart';
import 'data/services/onnx_classifier_service.dart';
import 'data/services/combined_export_picker.dart';
import 'data/services/saf_export_target.dart';
import 'data/services/webdav_settings.dart';
import 'data/services/session_database.dart';
import 'domain/models/recording_session.dart';
import 'l10n/app_localizations.dart';
import 'l10n/app_strings.dart';
import 'ui/core/l10n/l10n_context.dart';
import 'ui/core/theme.dart';
import 'ui/features/archive/view_models/archive_view_model.dart';
import 'ui/features/archive/views/archive_view.dart';
import 'ui/features/diagnostic/view_models/diagnostic_view_model.dart';
import 'ui/features/diagnostic/views/diagnostic_view.dart';
import 'ui/features/home/views/home_view.dart';
import 'ui/features/recording/view_models/recording_view_model.dart';
import 'ui/features/report/view_models/report_view_model.dart';

Future<void> main() async {
  // 必须在任何数据库操作之前——桌面平台要换成 ffi 实现。
  configureDatabaseFactory();

  // 通知栏和后台代码**拿不到 BuildContext**，只能在启动时先按系统语言
  // 加载一份给它们用。见 `ui/core/l10n/app_strings.dart`。
  WidgetsFlutterBinding.ensureInitialized();
  setAppStrings(await _loadAppStrings());
  runApp(const SleepSecretApp());
}

/// 按系统语言加载那份"给后台用的"文案。
///
/// 系统语言不在支持列表里时退回第一个支持的（中文）——和 `MaterialApp`
/// 的解析规则保持一致，不然会出现「界面中文、通知栏英文」这种错位。
Future<AppLocalizations> _loadAppStrings() {
  final locale = WidgetsBinding.instance.platformDispatcher.locale;
  final resolved = AppLocalizations.delegate.isSupported(locale)
      ? locale
      : AppLocalizations.supportedLocales.first;
  return AppLocalizations.delegate.load(resolved);
}

/// 把当前语言的文案同步给 [appStrings]。
///
/// 必须挂在 `MaterialApp` **里面**——`_SleepSecretAppState` 在 `MaterialApp`
/// 之上，那个 context 上取不到 `Localizations`。
///
/// 用 `didChangeDependencies` 而不是 `build`：它正好是"语言变了"会重新跑到的
/// 那个钩子，而且不会在每次重建时都做一遍。
class _SyncAppStrings extends StatefulWidget {
  const _SyncAppStrings({required this.child});

  final Widget child;

  @override
  State<_SyncAppStrings> createState() => _SyncAppStringsState();
}

class _SyncAppStringsState extends State<_SyncAppStrings> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final l10n = AppLocalizations.of(context);
    if (l10n != null) setAppStrings(l10n);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// 依赖装配。
///
/// 依赖链只有两条（分析、录音），手工装配比引入 provider/get_it 更直观。
class SleepSecretApp extends StatefulWidget {
  const SleepSecretApp({super.key, this.localeOverride});

  /// 测试用：把界面语言钉死。
  ///
  /// 线上永远是 null（跟随系统）。存在的理由：泵**真 App** 的集成测试
  /// 没有别的地方能注入 locale，而 CI 的模拟器是 en_US、断言却按中文写。
  ///
  /// 试过用 `platformDispatcher.localeTestValue` 钉——那是给 `flutter_test`
  /// 的假 binding 用的，集成测试跑在真实 dispatcher 上，**不生效**
  /// （2026-10-07 实测：本机中文 Windows 过、CI 上红）。
  final Locale? localeOverride;

  @override
  State<SleepSecretApp> createState() => _SleepSecretAppState();
}

class _SleepSecretAppState extends State<SleepSecretApp> {
  // 两个功能共用同一个 ONNX 会话——模型 6.3MB，没必要加载两份。
  late final OnnxClassifierService _classifier;
  late final SleepAnalysisRepository _analysisRepository;

  /// 录音和导出**共用同一个实例**。
  ///
  /// 各建各的会指向同一个库文件，而 sqflite 按路径缓存连接——
  /// 任何一边 `close()` 都会把另一边的连接一起关掉。
  late final SessionDatabase _database;
  late final RecordingRepository _recordingRepository;

  // 片段存储与播放器在报告页共用一份。
  late final FileAudioClipStore _clipStore;
  late final JustAudioEventPlayer _player;

  late final ArchiveRepository _archiveRepository;
  late final LocaleRepository _localeRepository;

  late final DiagnosticViewModel _diagnosticViewModel;
  late final RecordingViewModel _recordingViewModel;
  late final ArchiveViewModel _archiveViewModel;

  @override
  void initState() {
    super.initState();

    _classifier = OnnxClassifierService(
      assetKey: 'assets/models/ced-tiny.onnx',
    );
    _analysisRepository = SleepAnalysisRepository(classifier: _classifier);

    _clipStore = FileAudioClipStore();
    _player = JustAudioEventPlayer();
    _database = SessionDatabase();

    // 凭据存在 App 私有的 SQLite 里。取舍写在 webdav_settings.dart 顶上：
    // Keystore 那条路会弄坏 Windows 构建，而这个项目要出 Windows 包。
    final webDavSettings = DatabaseWebDavSettingsStore(_database);

    // Android 走 SAF（拿不到可写的真实路径），桌面就是普通目录；
    // 两者都可以被换成 WebDAV（坚果云）。那只是**第三种目标类型**，
    // 由 CombinedExportTargetPicker 分流，仓储和导出逻辑一个字都不用改。
    _archiveRepository = ArchiveRepository(
      service: ArchiveService(database: _database, clipStore: _clipStore),
      database: _database,
      picker: CombinedExportTargetPicker(
        folderPicker: defaultTargetPlatform == TargetPlatform.android
            ? SafExportTargetPicker()
            : const DesktopExportTargetPicker(),
        settingsStore: webDavSettings,
      ),
    );

    _recordingRepository = RecordingRepository(
      capture: RecordAudioCapture(),
      analyzer: _analysisRepository,
      database: _database,
      foregroundService: FlutterForegroundServiceController(),
      clipStore: _clipStore,
      autoExport: _autoExport,
    );

    _diagnosticViewModel = DiagnosticViewModel(
      analyzer: _analysisRepository,
      fixtures: const AssetDiagnosticFixtures(),
    );
    _localeRepository = LocaleRepository(database: _database);
    // 读一次存下来的语言偏好。不 await：界面先按系统语言渲染，
    // 读到偏好之后 ListenableBuilder 会把它切过去。
    unawaited(_localeRepository.load());

    _recordingViewModel = RecordingViewModel(controller: _recordingRepository);
    _archiveViewModel = ArchiveViewModel(
      controller: _archiveRepository,
      webDavSettings: webDavSettings,
    );

    // 上次没传上去的，趁现在再试一遍。不 await：它要走网络，
    // 卡着启动流程的话，用户会以为 App 打不开了。
    unawaited(_archiveRepository.flushRetries());
  }

  /// 录音落库之后自动导出到用户配的目录。
  ///
  /// **吞掉异常**：导出失败不该让「结束录音」看起来也失败了——
  /// 那次录音已经落库，导出的问题由导出页自己显示。
  Future<void> _autoExport(RecordingSession session) async {
    try {
      await _archiveRepository.exportSession(session);
    } catch (_) {
      // 导出页会显示失败原因，这里不重复报——但要**记下来下次再试**。
      // 这条路多半是深夜自动跑的：那会儿网盘掉线、或者省电模式掐了网络，
      // 用户根本不在旁边，没人会去点「重试」。
      await _archiveRepository.queueRetry(session);
    }
  }

  @override
  void dispose() {
    _diagnosticViewModel.dispose();
    _recordingViewModel.dispose();
    _archiveViewModel.dispose();
    _localeRepository.dispose();
    _archiveRepository.dispose();
    _recordingRepository.dispose();
    _player.dispose();
    _classifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 语言偏好一变，整个 MaterialApp 都得重建 —— locale 是它的参数
    return ListenableBuilder(
      listenable: _localeRepository,
      builder: (context, _) => MaterialApp(
      // 用 onGenerateTitle 而不是 title：title 只在启动时取一次，
      // 系统语言变了不会重算。
      onGenerateTitle: (context) => context.l10n.appTitle,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => _SyncAppStrings(child: child!),
      // null = 跟随系统。**这个默认值不能改**：钉死成某个语言的话，
      // 用户换系统语言时 App 就不跟着变了。
      locale: widget.localeOverride ?? _localeRepository.locale,
      home: HomeView(
        localeController: _localeRepository,
        recordingViewModel: _recordingViewModel,
        reportViewModelFactory: (session) => ReportViewModel(
          session: session,
          clipStore: _clipStore,
          player: _player,
          classMap: _analysisRepository.classMap,
        ),
      ),
      routes: {
        DiagnosticView.routeName: (_) =>
            DiagnosticView(viewModel: _diagnosticViewModel),
        ArchiveView.routeName: (_) =>
            ArchiveView(viewModel: _archiveViewModel),
      },
      ),
    );
  }
}
