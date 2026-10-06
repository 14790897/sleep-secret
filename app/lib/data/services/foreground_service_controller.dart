import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show MissingPluginException;
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// 前台服务的契约。
///
/// 抽出来有两个原因：测试环境（Windows / 单元测试）没有 Android 前台服务；
/// 而且整夜录音的保活策略将来可能换实现。
abstract interface class ForegroundServiceController {
  /// 初始化插件配置。必须在 [start] 之前调用一次。
  void initialize();

  /// 启动麦克风型前台服务。
  Future<void> start({required String title, required String text});

  /// 更新通知文案（例如显示已录音时长）。
  Future<void> update({required String text});

  Future<void> stop();

  Future<bool> get isRunning;
}

/// 基于 `flutter_foreground_task` 的实现。
///
/// 注意：这里只负责「起点一个麦克风型前台服务把进程保住 + 显示通知」，
/// 真正的采集与推理跑在主 isolate 里。整夜录音的关键是进程不被杀，
/// 插件单独跑一个 isolate 反而会让状态同步变复杂。
///
/// **插件只有 Android 实现**。桌面端（开发调试用）没有这个方法通道，
/// 调用会抛 MissingPluginException——那种情况下要**降级继续**，
/// 而不是让整个录音起不来。前台服务只是保活手段，不是录音的前提。
class FlutterForegroundServiceController implements ForegroundServiceController {
  FlutterForegroundServiceController({
    this.channelId = 'sleep_secret_recording',
    this.channelName = '睡眠录音',
  });

  final String channelId;
  final String channelName;

  bool _initialized = false;
  bool _unsupported = false;

  /// 当前平台是否不支持前台服务（桌面端）。
  bool get isUnsupported => _unsupported;

  /// 平台不支持时吞掉异常；其他错误照常抛出——
  /// 免得把 Android 上真正的失败也一起藏起来。
  Future<T?> _guarded<T>(Future<T> Function() action) async {
    if (_unsupported) return null;
    try {
      return await action();
    } on MissingPluginException {
      _unsupported = true;
      debugPrint('当前平台不支持前台服务，录音将在没有保活服务的情况下运行');
      return null;
    }
  }

  @override
  void initialize() {
    if (_initialized || _unsupported) return;
    try {
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: channelId,
          channelName: channelName,
          channelDescription: '整夜录音期间保持运行',
          // 整夜挂着，不该震动或响铃打断睡眠。
          enableVibration: false,
          playSound: false,
          onlyAlertOnce: true,
        ),
        iosNotificationOptions: const IOSNotificationOptions(),
        foregroundTaskOptions: ForegroundTaskOptions(
          eventAction: ForegroundTaskEventAction.nothing(),
          // 息屏后 CPU 仍需工作，否则录音会断。
          allowWakeLock: true,
          // 不在开机时自动启动——用户没主动点开始就不该偷偷录音。
          autoRunOnBoot: false,
          autoRunOnMyPackageReplaced: false,
          allowAutoRestart: false,
        ),
      );
      _initialized = true;
    } on MissingPluginException {
      _unsupported = true;
      debugPrint('当前平台不支持前台服务，录音将在没有保活服务的情况下运行');
    }
  }

  @override
  Future<void> start({required String title, required String text}) async {
    initialize();
    await _guarded(() async {
      if (await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.startService(
        serviceTypes: const [ForegroundServiceTypes.microphone],
        notificationTitle: title,
        notificationText: text,
      );
    });
  }

  @override
  Future<void> update({required String text}) async {
    await _guarded(() async {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.updateService(notificationText: text);
    });
  }

  @override
  Future<void> stop() async {
    await _guarded(() async {
      if (!await FlutterForegroundTask.isRunningService) return;
      await FlutterForegroundTask.stopService();
    });
  }

  @override
  Future<bool> get isRunning async =>
      await _guarded(() => FlutterForegroundTask.isRunningService) ?? false;
}
