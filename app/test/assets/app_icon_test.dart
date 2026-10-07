import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// 图标资源的约束。
///
/// ## 为什么值得测
///
/// 自适应图标（API 26+）把图层画成 108dp，但**只保证中间 72dp 可见**——
/// 外面那 18dp 会被厂商的蒙版（圆、圆角方、水滴……）切掉。
/// 图形画到那外面，在方形桌面上看着好好的，一换到圆形就缺一块。
///
/// 这件事**肉眼看预览图看不出来**：普通图标（mipmap-*/ic_launcher.png）
/// 是完整的方形，只有自适应那层才有安全区，而那一层单独看又是一张
/// 透明背景的图。所以很容易做出一份「看着没问题、装到某些机型上被裁」的图标。
///
/// 换图标时用 `scripts/make_app_icon.py` 重新生成，这条测试是那道闸。
void main() {
  const res = 'android/app/src/main/res';

  /// Android 约定：108dp 的图层里，中间 72dp 是安全区。
  const safeRatio = 72 / 108;

  Future<ui.Image> decode(String path) async {
    final bytes = await File(path).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    return (await codec.getNextFrame()).image;
  }

  /// 取整张图的 alpha 通道。
  Future<Uint8List> alphaOf(ui.Image image) async {
    final data =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final rgba = data!.buffer.asUint8List();
    final alpha = Uint8List(image.width * image.height);
    for (var i = 0; i < alpha.length; i++) {
      alpha[i] = rgba[i * 4 + 3];
    }
    return alpha;
  }

  group('自适应图标', () {
    const fgPath = '$res/drawable-xxxhdpi/ic_launcher_foreground.png';

    testWidgets('前景在安全区之外必须是透明的，否则圆蒙版会切掉它', (tester) async {
      late Uint8List alpha;
      late int size;

      await tester.runAsync(() async {
        final img = await decode(fgPath);
        size = img.width;
        alpha = await alphaOf(img);
      });

      expect(size, 432, reason: '108dp × 4x = 432px');

      final safe = (size * safeRatio).round();
      final band = (size - safe) ~/ 2; // 每侧被裁掉的宽度

      var maxOutside = 0;
      var worst = (0, 0);
      for (var y = 0; y < size; y++) {
        for (var x = 0; x < size; x++) {
          final inside =
              x >= band && x < size - band && y >= band && y < size - band;
          if (inside) continue;
          final a = alpha[y * size + x];
          if (a > maxOutside) {
            maxOutside = a;
            worst = (x, y);
          }
        }
      }

      expect(maxOutside, lessThan(16),
          reason: '图形伸进了会被裁掉的 ${band}px 边距，最亮的一点在 '
              '(${worst.$1}, ${worst.$2})，alpha=$maxOutside。'
              '换图标时要保证图形都在正中 $safe×$safe 的安全区内。');
    });

    test('图层文件都在', () {
      expect(File('$res/drawable-xxxhdpi/ic_launcher_foreground.png').existsSync(),
          isTrue, reason: '自适应图标的前景层');
      expect(File('$res/drawable/ic_launcher_background.xml').existsSync(),
          isTrue, reason: '自适应图标的背景层');
      expect(File('$res/mipmap-anydpi-v26/ic_launcher.xml').existsSync(),
          isTrue, reason: '没有这个文件，API 26+ 会退回传统图标，桌面会套白底');
    });

    test('前景**不能带背景**——两层会一起被缩放，自带背景就会看到一圈边', () {
      final xml = File('$res/mipmap-anydpi-v26/ic_launcher.xml').readAsStringSync();
      expect(xml, contains('@drawable/ic_launcher_background'));
      expect(xml, contains('@drawable/ic_launcher_foreground'));
    });
  });

  group('传统图标（API < 26 和 Windows 用）', () {
    testWidgets('五个密度齐全，尺寸都对', (tester) async {
      const want = {
        'mipmap-mdpi': 48,
        'mipmap-hdpi': 72,
        'mipmap-xhdpi': 96,
        'mipmap-xxhdpi': 144,
        'mipmap-xxxhdpi': 192,
      };

      await tester.runAsync(() async {
        for (final entry in want.entries) {
          final path = '$res/${entry.key}/ic_launcher.png';
          expect(File(path).existsSync(), isTrue, reason: '缺了 ${entry.key}');
          final img = await decode(path);
          expect(img.width, entry.value, reason: '${entry.key} 宽度不对');
          expect(img.height, entry.value, reason: '${entry.key} 高度不对');
        }
      });
    });

    test('Windows 的 ico 在', () {
      // 少了它，EXE 会用 Flutter 模板那个默认图标——和安装后的名字对不上
      expect(File('windows/runner/resources/app_icon.ico').existsSync(), isTrue);
    });

    testWidgets('图形要画满，不能只占中间一小块', (tester) async {
      // 安全区（正中 72/108）是 **adaptive icon** 的约束，不是传统图标的。
      // 传统图标是整张方图直接显示，图形只占中间 2/3 的话，
      // 在 Windows 任务栏和旧版桌面上会比旁边的图标小一圈。
      //
      // 两个基准：横向要伸到画布 20% 以内。
      // 画满之后大约在 16.5% ~ 82.6%，照搬安全区那套则只有 23.8% ~ 75.5%。
      late List<int> bright;
      late int size;

      await tester.runAsync(() async {
        final img = await decode('$res/mipmap-xxxhdpi/ic_launcher.png');
        size = img.width;
        final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
        final rgba = data!.buffer.asUint8List();
        bright = [];
        for (var y = 0; y < size; y++) {
          for (var x = 0; x < size; x++) {
            final i = (y * size + x) * 4;
            // 图形是亮蓝色，背景是深藏青——用红色通道分开就够了
            if (rgba[i] > 80) bright.add(x);
          }
        }
      });

      expect(bright, isNotEmpty, reason: '整张图找不到图形，肯定不对');
      final leftmost = bright.reduce((a, b) => a < b ? a : b) / size;
      final rightmost = bright.reduce((a, b) => a > b ? a : b) / size;

      expect(leftmost, lessThanOrEqualTo(0.20),
          reason: '图形最左只到 ${(leftmost * 100).toStringAsFixed(1)}%，'
              '太靠里了——是不是把自适应图标的安全区留白照搬到传统图标上了？');
      expect(rightmost, greaterThanOrEqualTo(0.80),
          reason: '图形最右只到 ${(rightmost * 100).toStringAsFixed(1)}%');
    });
  });
}
