import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/pump_app.dart';
import 'package:sleep_secret/data/models/sleep_class_map.dart';
import 'package:sleep_secret/data/services/diagnostic_fixtures.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sleep_prediction.dart';
import 'package:sleep_secret/domain/repositories/sleep_analyzer.dart';
import 'package:sleep_secret/ui/features/diagnostic/view_models/diagnostic_view_model.dart';
import 'package:sleep_secret/ui/features/diagnostic/views/diagnostic_view.dart';

const _clips = ['quiet', 'noise', 'tone', 'pulse'];

/// 假的分析器，替代真实 ONNX 运行时。
///
/// 之所以能这样注入，是因为 ViewModel 依赖的是 [SleepAnalyzer] 抽象
/// 而不是具体的 Repository 实现。
class FakeSleepAnalyzer implements SleepAnalyzer {
  FakeSleepAnalyzer({this.logits, this.failOnInitialize = false});

  /// 每段音频都返回这份 logits；为 null 时返回全 0。
  final List<double>? logits;
  final bool failOnInitialize;

  int initializeCount = 0;

  @override
  SleepClassMap? classMap = _stubMap();

  @override
  bool isReady = false;

  @override
  Future<void> initialize() async {
    initializeCount++;
    if (failOnInitialize) {
      throw StateError('模拟的加载失败');
    }
    isReady = true;
  }

  @override
  Future<SleepPrediction> classifyAsset(String assetKey) async =>
      _prediction(logits ?? List<double>.filled(527, 0.0));

  @override
  Future<SleepPrediction> classifySamples(Float32List samples) async =>
      _prediction(logits ?? List<double>.filled(527, 0.0));

  SleepPrediction _prediction(List<double> raw) {
    final asFloat = Float32List.fromList(raw);
    return SleepPrediction(
      probabilities: {
        for (final c in SleepCategory.values) c: asFloat.isEmpty ? 0.0 : asFloat[0] / 100,
      },
      logits: asFloat,
      topLabels: const [(label: 'Snoring', probability: 0.1)],
    );
  }

  static SleepClassMap _stubMap() => SleepClassMap(
        modelName: 'fake-model',
        numClasses: 527,
        labels: List<String>.filled(527, 'x', growable: false),
        categoryIndices: {
          for (final c in SleepCategory.values) c: const [0],
        },
        snoreIndices: const [0],
      );
}

/// 假的夹具来源，直接内存返回——不碰 rootBundle。
///
/// 真实实现读 asset，而 Flutter 测试的 FakeAsync 时区不会推进真实 I/O，
/// 所以 ViewModel 必须通过这个抽象拿夹具，测试才能注入。
class FakeDiagnosticFixtures implements DiagnosticFixtures {
  FakeDiagnosticFixtures({Map<String, ExpectedClip>? clips})
      : _clips = clips ?? const {};

  final Map<String, ExpectedClip> _clips;

  @override
  Future<Map<String, ExpectedClip>> loadExpectedClips() async => _clips;
}

Map<String, ExpectedClip> clipsWith(List<double> logits) => {
      for (final name in _clips)
        'assets/testdata/$name.wav':
            ExpectedClip(logits: logits, durationSeconds: 5.0),
    };

void main() {
  Widget wrap(DiagnosticViewModel vm) =>
      localizedApp(home: DiagnosticView(viewModel: vm));

  DiagnosticViewModel buildVm({
    List<double>? analyzerLogits,
    List<double>? fixtureLogits,
    bool failOnInitialize = false,
  }) {
    final fixture = fixtureLogits ?? List<double>.filled(527, 0.0);
    return DiagnosticViewModel(
      analyzer: FakeSleepAnalyzer(
        logits: analyzerLogits,
        failOnInitialize: failOnInitialize,
      ),
      fixtures: FakeDiagnosticFixtures(clips: clipsWith(fixture)),
    );
  }

  testWidgets('初始状态展示启动按钮', (tester) async {
    final vm = buildVm();
    await tester.pumpWidget(wrap(vm));

    expect(find.text('端侧推理诊断'), findsOneWidget);
    expect(find.text('加载模型并运行'), findsOneWidget);
    expect(find.textContaining('7 大类概率'), findsNothing);
  });

  testWidgets('点击后完成推理，展示 7 大类与模型信息', (tester) async {
    final vm = buildVm();
    await tester.pumpWidget(wrap(vm));

    await tester.tap(find.text('加载模型并运行'));
    await tester.pumpAndSettle();

    expect(vm.status, DiagnosticStatus.ready);
    expect(find.text('模型：fake-model'), findsOneWidget);
    for (final category in SleepCategory.values) {
      expect(find.text(category.label), findsWidgets, reason: category.label);
    }
    expect(vm.results.length, _clips.length);
  });

  testWidgets('端侧结果与 PC 期望值一致时显示通过', (tester) async {
    final same = List<double>.filled(527, 0.5);
    final vm = buildVm(analyzerLogits: same, fixtureLogits: same);
    await tester.pumpWidget(wrap(vm));
    await tester.tap(find.text('加载模型并运行'));
    await tester.pumpAndSettle();

    expect(vm.allMatchPc, isTrue);
    expect(find.text('与 PC 端一致'), findsOneWidget);
  });

  testWidgets('端侧结果与 PC 期望值不符时给出告警', (tester) async {
    // 端侧返回全 0，期望值是全 0.5 -> 必然不符
    final vm = buildVm(
      analyzerLogits: List<double>.filled(527, 0.0),
      fixtureLogits: List<double>.filled(527, 0.5),
    );
    await tester.pumpWidget(wrap(vm));
    await tester.tap(find.text('加载模型并运行'));
    await tester.pumpAndSettle();

    expect(vm.allMatchPc, isFalse);
    expect(find.text('与 PC 端存在差异'), findsOneWidget);
  });

  testWidgets('加载失败时展示错误与重试按钮', (tester) async {
    final vm = buildVm(failOnInitialize: true);
    await tester.pumpWidget(wrap(vm));
    await tester.tap(find.text('加载模型并运行'));
    await tester.pumpAndSettle();

    expect(vm.status, DiagnosticStatus.failed);
    expect(find.text('加载失败'), findsOneWidget);
    expect(find.textContaining('模拟的加载失败'), findsWidgets);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('重试会重新调用 initialize', (tester) async {
    final analyzer = FakeSleepAnalyzer(failOnInitialize: true);
    final vm = DiagnosticViewModel(
      analyzer: analyzer,
      fixtures: FakeDiagnosticFixtures(clips: clipsWith(List<double>.filled(527, 0))),
    );
    await tester.pumpWidget(wrap(vm));

    await tester.tap(find.text('加载模型并运行'));
    await tester.pumpAndSettle();
    expect(analyzer.initializeCount, 1);

    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(analyzer.initializeCount, 2);
  });
}
