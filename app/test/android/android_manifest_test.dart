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
///
/// 另一类：**依赖库塞进来的权限**。`RECEIVE_BOOT_COMPLETED`（开机自启）来自
/// flutter_foreground_task，而我们的 `autoRunOnBoot` 是关掉的；
/// `ACCESS_NETWORK_STATE` 来自 media3（just_audio 的依赖），而我们只播本地文件。
/// 两条都靠主清单里的 `tools:node="remove"` 在合并时移除。这里盯住这些
/// remove 指令不被顺手删掉——删了权限就悄悄回来了，而单测和 debug 包都看不出来
/// （权限不报错，只是清单上多两行）。合并结果本身需要构建，不在这里测。
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

  test('开机自启权限在合并时被移除（flutter_foreground_task 带来的）', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    _expectRemovalOnly(
      manifest,
      'android.permission.RECEIVE_BOOT_COMPLETED',
      reason: 'autoRunOnBoot / autoRunOnMyPackageReplaced 都是 false，'
          '开机自启从不启用，这个权限不该出现在 APK 里。',
    );
  });

  test('RebootReceiver 在合并时被移除（与开机自启权限配套）', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    _expectRemovalOnly(
      manifest,
      'com.pravera.flutter_foreground_task.service.RebootReceiver',
      reason: '没有开机自启就不需要这个广播接收器，留着只是白占一个入口。',
    );
  });

  test('ACCESS_NETWORK_STATE 在合并时被移除（media3 只为网络流媒体要它）', () {
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

    _expectRemovalOnly(
      manifest,
      'android.permission.ACCESS_NETWORK_STATE',
      reason: '本 App 只播放本地录音文件，不探测网络。'
          '这条来自 androidx.media3:media3-common（just_audio 的依赖）。',
    );
  });
}

/// 断言主清单里每一处提到 [needle] 的标签都带 `tools:node="remove"`。
///
/// 只查「有没有 remove 指令」不够：如果别处又普通声明了一次同名权限，
/// remove 指令在，权限照样会进 APK。所以要求所有出现处都必须是移除声明。
void _expectRemovalOnly(
  String manifest,
  String needle, {
  required String reason,
}) {
  final tags = RegExp(r'<[^>]*>', dotAll: true)
      .allMatches(manifest)
      .map((match) => match.group(0)!)
      .where((tag) => tag.contains(needle))
      .toList();

  expect(tags, isNotEmpty, reason: '主清单里找不到 $needle 的移除声明。$reason');
  for (final tag in tags) {
    expect(
      tag,
      contains('tools:node="remove"'),
      reason: '主清单里的 $needle 没有 tools:node="remove"，'
          '依赖库声明的它就会回到 APK 里。$reason',
    );
  }
}
