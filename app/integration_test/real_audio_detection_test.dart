import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sleep_secret/data/repositories/sleep_analysis_repository.dart';
import 'package:sleep_secret/data/services/onnx_classifier_service.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';

/// 端侧模型对**真实鼾声**的识别验证。
///
///   flutter test integration_test/real_audio_detection_test.dart -d <设备>
///
/// 这是整个项目里最重要的一条测试。之前所有的验证都只用合成音频，
/// 而合成信号的输出是接近均匀的噪声——那只能证明"链路通"，
/// 证明不了"识别准"。真实样本才能回答"它认不认得出鼾声"。
///
/// 样本来源：Freesound 上的 **CC0** 真实录音，见 `scripts/fetch_test_audio.py`
/// 和 `scripts/test_audio_sources.json`（每个文件的出处和许可都记在那儿）。
///
/// 注意：这些是 5 秒片段，且都是"典型"鼾声。它能过不代表真实整夜录音
/// 的检出率就高——那还要看距离、被子遮挡、手机摆放位置等因素。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late OnnxClassifierService classifier;
  late SleepAnalysisRepository repository;

  setUpAll(() {
    classifier = OnnxClassifierService(
      assetKey: 'assets/models/ced-tiny.onnx',
    );
    repository = SleepAnalysisRepository(classifier: classifier);
  });

  tearDownAll(() => classifier.dispose());

  Future<double> snoreScoreOf(String asset) async {
    final prediction = await repository.classifyAsset(asset);
    return prediction.snoreProbability;
  }

  group('真实鼾声应当被识别出来', () {
    for (final name in ['snore_01', 'snore_02', 'snore_05']) {
      testWidgets('$name 被判定为鼾声', (tester) async {
        await repository.initialize();

        final prediction =
            await repository.classifyAsset('assets/testdata/real/$name.wav');

        expect(prediction.dominant, SleepCategory.snore,
            reason: '主导大类应当是鼾声');
        expect(prediction.snoreProbability, greaterThan(0.5),
            reason: '鼾声得分 ${prediction.snoreProbability}，'
                '模型对真实鼾声应当有明确把握，而不是模棱两可');
      });
    }
  });

  group('其他声音不应被误判为鼾声', () {
    for (final name in ['rooster', 'rain']) {
      testWidgets('$name 不会被当成鼾声', (tester) async {
        await repository.initialize();

        final score = await snoreScoreOf('assets/testdata/real/$name.wav');

        expect(score, lessThan(0.1),
            reason: '误报比漏报更伤信任——用户听到一段不是鼾声的音频会认为应用坏了');
      });
    }
  });

  testWidgets('输出是多标签 sigmoid，不是 softmax 分布', (tester) async {
    await repository.initialize();

    final prediction =
        await repository.classifyAsset('assets/testdata/real/snore_01.wav');

    final top1 = prediction.logits.reduce((a, b) => a > b ? a : b);

    // 决定性判据是 top-1 的量级。
    //
    // softmax 会除以 527 个值的大和，把 0.96 压成 0.002——所以只要 top-1
    // 是 0.9 这个量级，就说明没有 softmax。这条断言就是防它回归的。
    expect(top1, greaterThan(0.5),
        reason: 'top-1 只有 $top1 —— 这个量级说明有人又对 sigmoid 输出了做了 softmax，'
            '那会让置信度门控永远过不了');

    // 输出之和略高于 1（真实鼾声约 1.08，多个类同时响应时更高）。
    // 这个指标区分度弱，只作为旁证——softmax 分布的和会恰好等于 1.0。
    final sum = prediction.logits.fold<double>(0, (a, b) => a + b);
    expect(sum, greaterThan(1.0));

    final overHalf = prediction.logits.where((v) => v > 0.5).length;
    expect(overHalf, greaterThanOrEqualTo(1),
        reason: '真实鼾声至少应当有一个类别超过 0.5');
  });

  testWidgets('真实鼾声的得分远高于对照声音', (tester) async {
    await repository.initialize();

    final snore = await snoreScoreOf('assets/testdata/real/snore_01.wav');
    final rooster = await snoreScoreOf('assets/testdata/real/rooster.wav');
    final rain = await snoreScoreOf('assets/testdata/real/rain.wav');

    expect(snore, greaterThan(rooster + 0.4));
    expect(snore, greaterThan(rain + 0.4));
  });
}
