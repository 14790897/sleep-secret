// 把集成测试里 `binding.takeScreenshot('名字')` 截的图存到磁盘。
//
//   flutter drive \
//     --driver=test_driver/screenshots.dart \
//     --target=integration_test/recording_to_report_test.dart \
//     -d emulator-5554 --dart-define=SHOTS=true
//
// 存到 `build/screenshots/<名字>.png`（`build/` 已经在 .gitignore 里）。
//
// ## 为什么要有这个文件
//
// 想在**界面真的渲染出来**的时候看一眼，只有这一条路：
// 截图必须从**测试内部**取（那时 App 正在真机上跑），再由 driver 传回主机。
// 在外面拿 PowerShell 枚举窗口、模拟鼠标点击、再 PrintWindow 抓图——
// 那是**另一条完全不同的路**，而且不可靠：窗口可能拿不到焦点、
// 点击可能落到别的窗口上、`IsWindowVisible` 可能是 false。
// 这一场里那些坑全踩过一遍，最后也没截到图。
//
// ⚠️ 只在 `flutter drive` 下有效。用 `flutter test` 跑的话没有 driver
// 来接这个回调，所以测试里那些 takeScreenshot 都加了
// `--dart-define=SHOTS=true` 的开关，CI 走 `flutter test` 时不会调到。

import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  await integrationDriver(
    onScreenshot: (
      String name,
      List<int> image, [
      Map<String, Object?>? args,
    ]) async {
      final file = File('build/screenshots/$name.png');
      await file.create(recursive: true);
      await file.writeAsBytes(image);
      stdout.writeln('截图已存：${file.path}（${image.length} 字节）');
      // 返回 true 表示"这张存下来了"，结果会汇总在最后
      return true;
    },
  );
}
