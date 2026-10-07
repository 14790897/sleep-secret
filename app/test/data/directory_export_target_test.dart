import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/services/directory_export_target.dart';

void main() {
  late Directory temp;
  late DirectoryExportTarget target;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dir_target_test');
    target = DirectoryExportTarget(temp.path);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('可用性', () {
    test('存在的可写目录 —— 可用', () async {
      expect(await target.isUsable(), isTrue);
    });

    test('目录不存在 —— 不可用', () async {
      final gone = DirectoryExportTarget('${temp.path}/并不存在');
      expect(await gone.isUsable(), isFalse);
    });

    test('探针文件不会留下来', () async {
      // isUsable 会真写一个文件来验证可写性（光判断"存在"不够——
      // 可能是只读盘），但**不能留下垃圾**。
      await target.isUsable();
      final leftovers = await temp
          .list()
          .where((e) => e.path.contains('write_test'))
          .toList();
      expect(leftovers, isEmpty);
    });
  });

  group('读写', () {
    test('文本往返', () async {
      await target.writeText('a/b.json', '{"x":1}');
      expect(await target.readText('a/b.json'), '{"x":1}');
    });

    test('读不存在的文件返回 null 而不是抛异常', () async {
      // 「没有这个文件」在导入时是正常情况，不该当成错误
      expect(await target.readText('nope.json'), isNull);
    });

    test('重名覆盖，不生成第二个文件', () async {
      await target.writeText('x.json', 'one');
      await target.writeText('x.json', 'two');
      expect(await target.readText('x.json'), 'two');
      expect(await target.listFiles('.'), ['x.json']);
    });
  });

  group('二进制搬运', () {
    test('复制进去、复制出来，内容一致', () async {
      final src = File('${temp.path}/source.wav');
      final bytes = List<int>.generate(500, (i) => i % 256);
      await src.writeAsBytes(bytes);

      await target.copyIn(src.path, 'clips/123/456.wav');

      final back = '${temp.path}/back.wav';
      expect(await target.copyOut('clips/123/456.wav', back), isTrue);
      expect(await File(back).readAsBytes(), bytes);
    });

    test('源文件不存在 —— copyOut 返回 false，不抛异常', () async {
      expect(await target.copyOut('clips/没有.wav', '${temp.path}/x'),
          isFalse);
    });
  });

  group('列目录', () {
    test('只列直接子项，不递归', () async {
      await target.writeText('sessions/a.json', '1');
      await target.writeText('sessions/b.json', '2');
      await target.writeText('sessions/sub/c.json', '3');

      expect(await target.listFiles('sessions'), ['a.json', 'b.json']);
    });

    test('目录不存在返回空表而不是抛异常', () async {
      expect(await target.listFiles('没这个目录'), isEmpty);
    });

    test('结果排过序 —— 导入顺序要稳定，否则测试会随机挂', () async {
      for (final n in ['c.json', 'a.json', 'b.json']) {
        await target.writeText('sessions/$n', 'x');
      }
      expect(await target.listFiles('sessions'),
          ['a.json', 'b.json', 'c.json']);
    });
  });

  group('配置的存与还原', () {
    test('serialized 带平台前缀，还原得回来', () async {
      final restored = await const DesktopExportTargetPicker()
          .restore(target.serialized);
      expect(restored, isNotNull);
      expect(restored!.description, temp.path);
    });

    test('前缀不对 —— 还原成 null 而不是当成路径用', () async {
      // Android 存的是 content:// URI，形状完全不同。
      // 不加前缀的话桌面这边会把它当路径去开。
      expect(await const DesktopExportTargetPicker().restore('saf:content://x'),
          isNull);
    });
  });
}
