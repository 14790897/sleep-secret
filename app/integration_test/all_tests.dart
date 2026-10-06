/// 把所有集成测试聚合成**一个入口**，供 CI 使用。
///
///   flutter test integration_test/all_tests.dart -d emulator-5554
///
/// ## 为什么要这样
///
/// `flutter test integration_test`（目录形式）会为**每个测试文件**单独
/// 构建并安装一次 APK——集成测试的入口就是测试文件本身，所以 APK 各不相同。
/// 5 个文件就是 5 轮「Gradle 构建 → adb 安装 → 启动 → 卸载」。
///
/// 实测在 GitHub 托管的模拟器上，这套反复折腾会在第 2 轮构建时把模拟器搞挂
/// （`adb: device 'emulator-5554' not found`），后面 4 个文件全部失败。
/// 而且每轮构建都要几分钟，整个 job 拖到 13 分钟以上，暴露在风险里的窗口更长。
///
/// 聚合成一个入口之后：**一次构建、一次安装、一次启动**，
/// 时间大幅缩短，模拟器中途挂掉的机会也小得多。
///
/// ⚠️ 文件名故意**不以 `_test.dart` 结尾**——否则 `flutter test integration_test`
/// 会把聚合入口和各个单文件都跑一遍，测试执行两次。
/// 单独跑某个文件的能力仍然保留：
///
///   flutter test integration_test/analysis_pipeline_test.dart -d <设备>
library;

import 'analysis_pipeline_test.dart' as analysis_pipeline;
import 'full_flow_test.dart' as full_flow;
import 'onnx_inference_test.dart' as onnx_inference;
import 'real_audio_detection_test.dart' as real_audio_detection;
import 'recording_to_report_test.dart' as recording_to_report;

void main() {
  // 每个文件自己的 main() 都会调 IntegrationTestWidgetsFlutterBinding
  // .ensureInitialized()，重复调用是安全的（拿到的是同一个实例）。
  //
  // 注意各文件顶层的 setUpAll / tearDownAll：聚合之后它们不再各自成组，
  // 而是**全部在第一个测试之前跑、在最后一个测试之后收尾**。
  // 目前这几个 setUpAll 建的都是各自独立的东西（模型句柄、临时目录），
  // 互不干扰；将来新增的 setUpAll 要保持这个性质。
  analysis_pipeline.main();
  full_flow.main();
  onnx_inference.main();
  real_audio_detection.main();
  recording_to_report.main();
}
