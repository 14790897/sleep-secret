import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Android 清单里那些**本地怎么测都测不出来**的声明。
///
/// ## 为什么单为一条权限写测试
///
/// Flutter 会往 **debug/profile** 的清单里自动加 `INTERNET`（Dart VM 调试要用），
/// **release 不会**。漏掉这一条的表现是：
///
/// - 单元 / widget / 集成测试全绿——它们跑的都是 debug 构建
/// - 调试时在真机上点 WebDAV 的「保存并测试」也是通的（debug 有权限）
/// - 只有**装出去的 release 包**连不上网，报一个像「地址填错」的网络错误
///
/// 也就是说这个错误没有任何一条既有测试会发现它。2026-10-08 就是这么漏掉的：
/// WebDAV 客户端拿真账号在 PC 上验通过，但那验的是 Dart 脚本，
/// 不是 APK 的清单。
///
/// 其余几条权限（`RECORD_AUDIO` / `FOREGROUND_SERVICE` /
/// `FOREGROUND_SERVICE_MICROPHONE`）不受这个坑影响：缺了它们会在启动录音时
/// 直接抛 `SecurityException`，一眼就能看见，不需要测试盯着。
void main() {
  test('主清单声明了 INTERNET —— 少了它 release 包根本连不上网', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    expect(
      manifest,
      contains('android.permission.INTERNET'),
      reason: 'Flutter 只给 debug/profile 清单加 INTERNET。主清单不写的话，'
          'release 构建没有联网权限，坚果云 / WebDAV 导出会失效——'
          '而且所有测试仍然是绿的。',
    );
  });
}
