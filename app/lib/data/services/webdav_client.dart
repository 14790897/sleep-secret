/// 极简 WebDAV 客户端：只做这个 App 需要的那几件事。
///
/// ## 为什么不用现成的包
///
/// 需要的就是 **PUT / GET / MKCOL / PROPFIND 加 Basic 认证**——五件事，
/// 而且都只走直连、不碰锁、不碰 PROPPATCH、不碰 WebDAV 的版本控制。
/// 一个包带来的是一整套用不到的东西和它的升级节奏；这里两百行能收住。
///
/// ## 为什么状态码要翻译成人话
///
/// 用这个功能的人（包括作者）碰到的第一个问题一定是**「连不上」**，
/// 而 `WebDavException: 401` 对解决它毫无帮助。所以每个错误都带上
/// **下一步该做什么**——401 是应用密码不对（坚果云必须用应用密码，
/// 不是登录密码），403 是权限，404 是路径写错了。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:xml/xml.dart';

/// 一次 WebDAV 调用失败。
class WebDavException implements Exception {
  WebDavException(this.message, {this.statusCode});

  /// 给用户看的一句话，**带着下一步怎么办**。
  final String message;

  /// HTTP 状态码；网络层失败时为 null。
  final int? statusCode;

  @override
  String toString() => statusCode == null ? message : '$message（HTTP $statusCode）';
}

class WebDavClient {
  WebDavClient({
    required String baseUrl,
    required String username,
    required String password,
    HttpClient? http,
    this.timeout = const Duration(seconds: 30),
  })  : _base = _normalize(baseUrl),
        // 用户名和密码**故意保持私有**：它们不该出现在这个对象的公开接口上。
        // ignore: prefer_initializing_formals
        _username = username,
        // ignore: prefer_initializing_formals
        _password = password,
        _http = http ?? HttpClient() {
    _http.connectionTimeout = timeout;
  }

  final Uri _base;
  final String _username;
  final String _password;
  final HttpClient _http;
  final Duration timeout;

  /// 末尾补上斜杠，好在后面拼路径。
  ///
  /// 用户复制粘贴地址时，有没有那个尾斜杠全看运气——两种都得能用。
  static Uri _normalize(String raw) {
    final trimmed = raw.trim();
    final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
    final parsed = Uri.parse(withScheme);
    if (!parsed.hasScheme || parsed.host.isEmpty) {
      throw WebDavException('地址看起来不对：$raw（应当形如 https://dav.jianguoyun.com/dav/）');
    }
    final path = parsed.path.endsWith('/') ? parsed.path : '${parsed.path}/';
    return parsed.replace(path: path);
  }

  /// 把相对路径拼成完整 URL。
  ///
  /// **逐段交给 `Uri` 转义**，不是自己拼字符串：坚果云这类服务商给的是
  /// 中文目录名很常见，手拼必然漏掉转义，然后就是一个看不懂的 404。
  Uri _url(String relativePath) {
    final segments = <String>[
      ..._base.pathSegments.where((s) => s.isNotEmpty),
      ...relativePath.split('/').where((s) => s.isNotEmpty),
    ];
    return _base.replace(pathSegments: segments);
  }

  Map<String, String> get _authHeader => {
        'authorization':
            'Basic ${base64Encode(utf8.encode('$_username:$_password'))}',
      };

  Future<HttpClientResponse> _send(String method, Uri url,
      {Map<String, String> headers = const {}, List<int>? body}) async {
    try {
      final request = await _http.openUrl(method, url).timeout(timeout);
      headers.forEach(request.headers.set);
      _authHeader.forEach(request.headers.set);
      request.headers.set('user-agent', 'sleep-secret/1.0');
      if (body != null) {
        request.headers.contentLength = body.length;
        request.add(body);
      }
      return await request.close().timeout(timeout);
    } on TimeoutException {
      // ⚠️ 连一个**没人听的端口**在 Windows 上是迟迟不给回应、而不是立刻拒绝，
      // 所以超时是这条路径上最常见的结果，必须自己变成人话——
      // 漏出去的话用户看到的是 `TimeoutException after 0:00:30`。
      throw WebDavException('服务器没有回应（超过 ${timeout.inSeconds} 秒）。'
          '检查地址、以及手机是否联网');
    } on SocketException catch (e) {
      throw WebDavException('连不上服务器：${e.message}。检查地址、以及手机是否联网');
    } on HandshakeException {
      throw WebDavException('TLS 握手失败——地址大概是 http 写成了 https，或者反过来');
    } on HttpException catch (e) {
      throw WebDavException('HTTP 出错：${e.message}');
    }
  }

  /// 401/403 单独说，因为它们是这个功能最常见的失败，且各有各的下一步。
  WebDavException _explain(int status, String doing) {
    final hint = switch (status) {
      401 => '。**坚果云必须用「应用密码」**（在网页版：账户信息 → 安全选项 → '
          '添加应用密码），不是登录密码',
      403 => '。账号对但没权限——检查这个路径归不归你',
      404 => '。路径不存在——坚果云一般是 https://dav.jianguoyun.com/dav/',
      _ => '',
    };
    return WebDavException('$doing失败$hint', statusCode: status);
  }

  /// 这个目录存在吗（只问这一层，不列内容）。
  Future<bool> directoryExists(String relativeDir) async {
    final response = await _send('PROPFIND', _url(relativeDir), headers: {
      'depth': '0',
      'content-type': 'application/xml',
    });
    // 把 body 读完再放掉连接，不然 HttpClient 会给下一个请求新开连接
    await response.drain<void>();
    if (response.statusCode == 404) return false;
    if (response.statusCode >= 400) {
      throw _explain(response.statusCode, '访问目录');
    }
    return true;
  }

  /// 逐级建目录（含父目录）。已存在就当成功。
  Future<void> ensureDirectory(String relativeDir) async {
    final parts = relativeDir.split('/').where((s) => s.isNotEmpty).toList();
    var soFar = '';
    for (final part in parts) {
      soFar = soFar.isEmpty ? part : '$soFar/$part';
      final response = await _send('MKCOL', _url(soFar));
      await response.drain<void>();
      // 201 = 建好了；405 = 已经存在。两个都算成功——
      // 重复建目录是常态（每晚都要 ensure 一次），不该报错。
      if (response.statusCode != 201 && response.statusCode != 405) {
        throw _explain(response.statusCode, '创建目录 $soFar');
      }
    }
  }

  Future<void> putBytes(String relativePath, List<int> bytes) async {
    final response = await _send('PUT', _url(relativePath), body: bytes);
    await response.drain<void>();
    // 201 新建 / 204 覆盖 / 200 某些服务商也这么回
    if (response.statusCode >= 300) {
      throw _explain(response.statusCode, '上传 $relativePath');
    }
  }

  /// 下载。文件不存在返回 null——「没有这个文件」在导入时是正常情况。
  Future<List<int>?> getBytes(String relativePath) async {
    final response = await _send('GET', _url(relativePath));
    if (response.statusCode == 404) {
      await response.drain<void>();
      return null;
    }
    if (response.statusCode >= 300) {
      await response.drain<void>();
      throw _explain(response.statusCode, '下载 $relativePath');
    }
    final chunks = await response
        .fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk));
    return chunks;
  }

  /// 列出目录下的**文件名**（不含子目录）。
  ///
  /// 目录不存在时返回空表——第一次同步时目标还是空的，
  /// 那是正常状态，不该当成错误。
  Future<Set<String>> listFileNames(String relativeDir) async {
    final response = await _send('PROPFIND', _url(relativeDir), headers: {
      'depth': '1',
      'content-type': 'application/xml',
    });
    if (response.statusCode == 404) {
      await response.drain<void>();
      return {};
    }
    if (response.statusCode >= 400) {
      await response.drain<void>();
      throw _explain(response.statusCode, '列出目录');
    }

    final body = utf8.decode(
      await response.fold<List<int>>(<int>[], (acc, chunk) => acc..addAll(chunk)),
      allowMalformed: true,
    );

    // 用真正的 XML 解析，不用正则：服务商的响应带不带命名空间前缀、
    // 用不用自闭合标签都不一定，正则迟早会漏。
    final document = XmlDocument.parse(body);
    final names = <String>{};
    // ⚠️ 按 **local name** 匹配，不是 `findAllElements('href')`。
    // 后者比的是**限定名**——服务商发的是 `<D:href>`（带命名空间前缀），
    // 于是就一个都匹配不上，而且**静态不报错、运行时也不抛**，
    // 表现成「列目录永远返回空表」。
    // 前一版我还专门写了注释说「别用正则抠 href」，结果自己掉进了隔壁那个坑。
    final hrefs = document.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'href');
    for (final href in hrefs) {
      final value = href.innerText.trim();
      if (value.isEmpty) continue;
      // ⚠️ `pathSegments` **已经解码过了**，不要再 `decodeComponent` 一次。
      // 双重解码平时看不出来，名字里带 `%` 的时候会直接抛
      // `Illegal percent encoding in URI`——而中文目录名正好会走到这儿。
      final segments = Uri.parse(value).pathSegments.where((s) => s.isNotEmpty);
      if (segments.isEmpty) continue;
      // 目录项以斜杠结尾，跳过（WebDAV 就靠这个区分目录和文件）
      if (value.endsWith('/')) continue;
      names.add(segments.last);
    }
    return names;
  }

  void close() => _http.close(force: true);
}
