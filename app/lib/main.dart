import 'package:flutter/material.dart';

import 'data/repositories/recording_repository.dart';
import 'data/repositories/sleep_analysis_repository.dart';
import 'data/services/audio_capture_service.dart';
import 'data/services/database_factory_setup.dart';
import 'data/services/diagnostic_fixtures.dart';
import 'data/services/event_player.dart';
import 'data/services/file_audio_clip_store.dart';
import 'data/services/foreground_service_controller.dart';
import 'data/services/onnx_classifier_service.dart';
import 'data/services/session_database.dart';
import 'ui/core/theme.dart';
import 'ui/features/diagnostic/view_models/diagnostic_view_model.dart';
import 'ui/features/diagnostic/views/diagnostic_view.dart';
import 'ui/features/home/views/home_view.dart';
import 'ui/features/recording/view_models/recording_view_model.dart';
import 'ui/features/report/view_models/report_view_model.dart';

void main() {
  // 必须在任何数据库操作之前——桌面平台要换成 ffi 实现。
  configureDatabaseFactory();
  runApp(const SleepSecretApp());
}

/// 依赖装配。
///
/// 依赖链只有两条（分析、录音），手工装配比引入 provider/get_it 更直观。
class SleepSecretApp extends StatefulWidget {
  const SleepSecretApp({super.key});

  @override
  State<SleepSecretApp> createState() => _SleepSecretAppState();
}

class _SleepSecretAppState extends State<SleepSecretApp> {
  // 两个功能共用同一个 ONNX 会话——模型 6.3MB，没必要加载两份。
  late final OnnxClassifierService _classifier;
  late final SleepAnalysisRepository _analysisRepository;
  late final RecordingRepository _recordingRepository;

  // 片段存储与播放器在报告页共用一份。
  late final FileAudioClipStore _clipStore;
  late final JustAudioEventPlayer _player;

  late final DiagnosticViewModel _diagnosticViewModel;
  late final RecordingViewModel _recordingViewModel;

  @override
  void initState() {
    super.initState();

    _classifier = OnnxClassifierService(
      assetKey: 'assets/models/ced-tiny.onnx',
    );
    _analysisRepository = SleepAnalysisRepository(classifier: _classifier);

    _clipStore = FileAudioClipStore();
    _player = JustAudioEventPlayer();

    _recordingRepository = RecordingRepository(
      capture: RecordAudioCapture(),
      analyzer: _analysisRepository,
      database: SessionDatabase(),
      foregroundService: FlutterForegroundServiceController(),
      clipStore: _clipStore,
    );

    _diagnosticViewModel = DiagnosticViewModel(
      analyzer: _analysisRepository,
      fixtures: const AssetDiagnosticFixtures(),
    );
    _recordingViewModel = RecordingViewModel(controller: _recordingRepository);
  }

  @override
  void dispose() {
    _diagnosticViewModel.dispose();
    _recordingViewModel.dispose();
    _recordingRepository.dispose();
    _player.dispose();
    _classifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '睡眠录音分析',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: HomeView(
        recordingViewModel: _recordingViewModel,
        reportViewModelFactory: (session) => ReportViewModel(
          session: session,
          clipStore: _clipStore,
          player: _player,
        ),
      ),
      routes: {
        DiagnosticView.routeName: (_) =>
            DiagnosticView(viewModel: _diagnosticViewModel),
      },
    );
  }
}
