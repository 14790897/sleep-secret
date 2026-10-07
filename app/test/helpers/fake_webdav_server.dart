import 'dart:convert';
import 'dart:io';

/// 一个**真的**走 HTTP 的假 WebDAV 服务器。
///
/// ## 为什么不 mock
///
/// 这个客户端出问题的地方几乎全在**传输层之上**：URL 转义（中文目录名）、
/// Basic 认证头、状态码、PROPFIND 的 XML 结构。把 `HttpClient` mock 掉，
/// 恰好把这些**全都绕过去了**——测试会变成在验证我自己写的那层假象。
///
/// 所以这里起一个真的 socket，用真的 HTTP 说话。代价是几十行，
/// 换来的是「转义漏了」「认证头没带」这类错误真的会被抓住。
class FakeWebDavServer {
  FakeWebDavServer._(this._server);

  final HttpServer _server;

  /// 相对路径（**已解码**，即真实文件名）-> 内容。
  final Map<String, List<int>> files = {};

  /// 已有的目录（相对路径，不含尾斜杠）。
  final Set<String> dirs = {''};

  /// 期望的 Basic 认证值；null 表示不校验。
  String? expectedAuth;

  /// 每收到一个请求记一笔，便于断言「到底发了几个请求」。
  final List<String> requests = [];

  static Future<FakeWebDavServer> start({String expectedAuth = ''}) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeWebDavServer._(server);
    if (expectedAuth.isNotEmpty) {
      fake.expectedAuth = 'Basic ${base64Encode(utf8.encode(expectedAuth))}';
    }
    server.listen(fake._handle);
    return fake;
  }

  String get baseUrl => 'http://127.0.0.1:${_server.port}/dav/';

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    // 路径一律先解码——真服务器也是这么做的，客户端必须转义对了才对得上
    final path = Uri.decodeComponent(
      request.uri.path.replaceFirst(RegExp(r'^/dav/?'), ''),
    );
    requests.add('${request.method} $path');

    final auth = request.headers.value('authorization');
    if (expectedAuth != null && auth != expectedAuth) {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }

    switch (request.method) {
      case 'PROPFIND':
        await _propfind(request, path);
      case 'MKCOL':
        await _mkcol(request, path);
      case 'PUT':
        await _put(request, path);
      case 'GET':
        await _get(request, path);
      default:
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
    }
  }

  Future<void> _propfind(HttpRequest request, String path) async {
    final depth = request.headers.value('depth') ?? '1';
    // 父目录也存在（'a/b' 的父是 'a'），否则子目录列不出来
    final known = dirs.contains(path) ||
        files.keys.any((k) => k.startsWith('$path/'));
    if (!known) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }

    // ⚠️ 刻意用 **D: 前缀** 和自闭合变体——真实的 WebDAV 响应就是这样，
    // 拿正则去抠 `<href>` 的写法在这里会翻车。
    final prefix = path.isEmpty ? '' : '$path/';
    final hrefs = <String>[
      '/dav/$path/',
      if (depth == '1')
        for (final key in [...files.keys, ...dirs])
          if (key.startsWith(prefix) &&
              key != path &&
              !key.substring(prefix.length).contains('/'))
            // ⚠️ **目录必须带尾斜杠**——WebDAV 就是靠这个区分目录和文件的。
            // 第一版没带，于是子目录被客户端当成了文件列出来，
            // 「列目录只给文件名，不含子目录」那条测试当场抓到。
            '$key${dirs.contains(key) ? '/' : ''}',
    ];

    final entries = hrefs
        .map((h) => h
            .split('/')
            .map(Uri.encodeComponent)
            .join('/'))
        .map((h) => '''
<D:response>
  <D:href>$h</D:href>
  <D:propstat><D:prop><D:resourcetype/></D:prop>
  <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
</D:response>''')
        .join();

    request.response.statusCode = 207;
    request.response.headers.contentType =
        ContentType.parse('application/xml; charset=utf-8');
    request.response.write('<?xml version="1.0" encoding="utf-8"?>'
        '<D:multistatus xmlns:D="DAV:">$entries</D:multistatus>');
    await request.response.close();
  }

  Future<void> _mkcol(HttpRequest request, String path) async {
    if (dirs.contains(path)) {
      request.response.statusCode = HttpStatus.methodNotAllowed; // 405
    } else {
      dirs.add(path);
      request.response.statusCode = HttpStatus.created; // 201
    }
    await request.response.close();
  }

  Future<void> _put(HttpRequest request, String path) async {
    final chunks = await request.fold<List<int>>(
        <int>[], (acc, chunk) => acc..addAll(chunk));
    final existed = files.containsKey(path);
    files[path] = chunks;
    request.response.statusCode =
        existed ? HttpStatus.noContent : HttpStatus.created;
    await request.response.close();
  }

  Future<void> _get(HttpRequest request, String path) async {
    final content = files[path];
    if (content == null) {
      request.response.statusCode = HttpStatus.notFound;
    } else {
      request.response.add(content);
    }
    await request.response.close();
  }
}
