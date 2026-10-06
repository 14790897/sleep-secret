import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 按平台选择数据库实现。
///
/// `sqflite` 原生只支持 Android / iOS / macOS。在 Windows / Linux 上
/// （目前只用于开发调试，不是交付平台）需要用 `sqflite_common_ffi`
/// 接一个内置的 sqlite3，否则一打开数据库就抛 UnsupportedError。
///
/// 必须在任何数据库操作之前调用，所以放在 `main()` 的最前面。
void configureDatabaseFactory() {
  if (kIsWeb) return;
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
}
