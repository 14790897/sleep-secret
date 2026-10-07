import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/services/webdav_client.dart';

import '../helpers/fake_webdav_server.dart';

void main() {
  late FakeWebDavServer server;
  late WebDavClient client;

  setUp(() async {
    // 刻意带中文和空格的账号——Basic 头要按 UTF-8 编码
    server = await FakeWebDavServer.start(expectedAuth: '我@example.com:abcd efgh');
    client = WebDavClient(
      baseUrl: server.baseUrl,
      username: '我@example.com',
      password: 'abcd efgh',
    );
  });

  tearDown(() async {
    client.close();
    await server.stop();
  });

  group('WebDavClient 地址', () {
    test('没写协议头时补 https', () {
      final c = WebDavClient(
          baseUrl: 'dav.jianguoyun.com/dav', username: 'u', password: 'p');
      addTearDown(c.close);
      // 不真的发请求，只确认它没在构造时炸
      expect(c, isNotNull);
    });

    test('地址根本不是地址时，构造就报错', () {
      expect(
        () => WebDavClient(baseUrl: '   ', username: 'u', password: 'p'),
        throwsA(isA<WebDavException>()),
      );
    });
  });

  group('WebDavClient 目录', () {
    test('目录不存在时返回 false 而不是抛异常', () async {
      expect(await client.directoryExists('没有这个目录'), isFalse);
    });

    test('逐级创建，父目录也跟着建', () async {
      await client.ensureDirectory('a/b/c');
      expect(server.dirs, containsAll(['a', 'a/b', 'a/b/c']));
    });

    test('重复创建当成成功——每晚都要 ensure 一次', () async {
      await client.ensureDirectory('a/b');
      await client.ensureDirectory('a/b'); // 不该抛
      expect(server.dirs, contains('a/b'));
    });

    test('**中文目录名**也能建能列——转义漏了这里就红', () async {
      await client.ensureDirectory('睡眠记录');
      await client.putBytes('睡眠记录/一.json', utf8.encode('{}'));

      expect(await client.listFileNames('睡眠记录'), contains('一.json'));
    });
  });

  group('WebDavClient 读写', () {
    test('传上去再取回来，内容一致', () async {
      final payload = utf8.encode('{"hello":"世界"}');
      await client.putBytes('x.json', payload);

      expect(await client.getBytes('x.json'), payload);
    });

    test('下载不存在的文件返回 null，不是抛异常', () async {
      expect(await client.getBytes('没有这个.json'), isNull);
    });

    test('列目录只给文件名，不含子目录', () async {
      await client.ensureDirectory('d/sub');
      await client.putBytes('d/a.json', utf8.encode('a'));
      await client.putBytes('d/b b.json', utf8.encode('b'));

      final names = await client.listFileNames('d');
      expect(names, {'a.json', 'b b.json'});
    });

    test('列一个还不存在的目录返回空表——第一次同步时目标就是空的', () async {
      expect(await client.listFileNames('还没有'), isEmpty);
    });

    test('**嵌套子目录**也能列——真实的导出就是放在子目录里的', () async {
      // 导出把会话放在 sessions/、片段放在 clips/，都是子目录。
      // 第一版客户端测试只测了根目录，于是这个缺口一直到
      // 「整套导出逻辑跑在 WebDAV 上」那条测试红了才露出来。
      await client.ensureDirectory('sleep-secret/sessions');
      await client.putBytes('sleep-secret/sessions/1.json', utf8.encode('{}'));

      expect(await client.listFileNames('sleep-secret/sessions'), {'1.json'});
    });
  });

  group('WebDavClient 出错时的话', () {
    test('401 要说「用应用密码」，不能只说 401', () async {
      final wrong = WebDavClient(
        baseUrl: server.baseUrl,
        username: '我@example.com',
        password: '登录密码不是这个',
      );
      addTearDown(wrong.close);

      WebDavException? caught;
      try {
        await wrong.listFileNames('');
      } on WebDavException catch (e) {
        caught = e;
      }

      expect(caught, isNotNull);
      expect(caught!.statusCode, 401);
      // 这句是重点：光说 401，用户不知道下一步干什么
      expect(caught.message, contains('应用密码'));
    });

    test('地址写错到连不上时，话里带着「检查地址」', () async {
      // 127.0.0.1 上一个没人听的端口
      final dead = WebDavClient(
        baseUrl: 'http://127.0.0.1:1/dav/',
        username: 'u',
        password: 'p',
        timeout: const Duration(seconds: 2),
      );
      addTearDown(dead.close);

      WebDavException? caught;
      try {
        await dead.listFileNames('');
      } on WebDavException catch (e) {
        caught = e;
      }

      expect(caught, isNotNull);
      expect(caught!.statusCode, isNull);
      // 断言「话里带着下一步」，不断言具体措辞：连一个没人听的端口，
      // Windows 上是**超时**（「服务器没有回应」），别处可能是立刻拒绝
      // （「连不上」）。两种都该说清去哪儿看。
      expect(caught.message, contains('检查地址'));
    });
  });
}
