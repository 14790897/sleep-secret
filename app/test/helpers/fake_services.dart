import 'dart:async';
import 'dart:typed_data';

import 'package:sleep_secret/data/services/audio_capture_service.dart';
import 'package:sleep_secret/data/services/foreground_service_controller.dart';

/// 可手动推送数据、可模拟失败的假采集器。
class FakeAudioCapture implements AudioCapture {
  FakeAudioCapture({this.permissionGranted = true});

  bool permissionGranted;
  int permissionRequests = 0;
  int startCount = 0;
  int stopCount = 0;
  bool disposed = false;

  StreamController<Uint8List>? _active;

  bool get isStreaming => _active != null && !_active!.isClosed;

  @override
  Future<bool> hasPermission({bool request = true}) async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<Stream<Uint8List>> start() async {
    startCount++;
    await _closeActive();
    final controller = StreamController<Uint8List>();
    _active = controller;
    return controller.stream;
  }

  /// 推送一块 PCM 给正在录的音。
  void push(Uint8List chunk) => _active?.add(chunk);

  void failWith(Object error) => _active?.addError(error);

  void endStream() {
    final c = _active;
    _active = null;
    if (c != null && !c.isClosed) c.close();
  }

  Future<void> _closeActive() async {
    final c = _active;
    _active = null;
    if (c != null && !c.isClosed) await c.close();
  }

  @override
  Future<void> stop() async {
    stopCount++;
    await _closeActive();
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _closeActive();
  }
}

/// 只记录调用的前台服务假实现——测试环境没有 Android。
class FakeForegroundServiceController implements ForegroundServiceController {
  int initializeCount = 0;
  int startCount = 0;
  int stopCount = 0;
  int updateCount = 0;
  bool running = false;
  String lastTitle = '';
  String lastText = '';

  /// 置为 true 时 start 抛异常，用于验证启动失败时的回滚。
  bool failOnStart = false;

  /// 通知权限是否已授予。默认授予——大多数测试不关心这件事，
  /// 要验证「被拒之后的提示」时把它置为 false。
  bool notificationPermissionGranted = true;
  int notificationPermissionRequests = 0;

  @override
  void initialize() => initializeCount++;

  @override
  Future<bool> ensureNotificationPermission() async {
    notificationPermissionRequests++;
    return notificationPermissionGranted;
  }

  @override
  Future<void> start({required String title, required String text}) async {
    startCount++;
    if (failOnStart) throw StateError('模拟前台服务启动失败');
    running = true;
    lastTitle = title;
    lastText = text;
  }

  @override
  Future<void> update({required String text}) async {
    updateCount++;
    lastText = text;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    running = false;
  }

  @override
  Future<bool> get isRunning async => running;
}
