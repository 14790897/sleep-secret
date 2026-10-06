import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/repositories/recording_repository.dart';
import 'package:sleep_secret/data/services/session_database.dart';
import 'package:sleep_secret/domain/analysis/analysis_config.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../helpers/fake_services.dart';
import '../helpers/fake_sleep_analyzer.dart';

/// 1 秒窗口便于构造短测试。
const testConfig = AnalysisConfig(
  windowSeconds: 1.0,
  hopSeconds: 1.0,
  vadRms: 0.01,
  lowConfidenceThreshold: 0.15,
  minEventSeconds: 2.0,
  mergeGapSeconds: 1.5,
);

/// 把浮点采样点打包成 16-bit 小端 PCM —— 与 record 插件给的格式一致。
Uint8List toPcm16(Float32List samples) {
  final out = Uint8List(samples.length * 2);
  final view = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    final clamped = samples[i].clamp(-1.0, 1.0);
    view.setInt16(i * 2, (clamped * 32767).round(), Endian.little);
  }
  return out;
}

/// 每秒一块地推入指定秒数的音频。
void pushSeconds(FakeAudioCapture capture, int seconds, {required double amplitude}) {
  for (var i = 0; i < seconds; i++) {
    capture.push(toPcm16(tone(amplitude: amplitude, length: 16000)));
  }
}

void main() {
  setUpAll(sqfliteFfiInit);

  late FakeAudioCapture capture;
  late FakeForegroundServiceController foreground;
  late SessionDatabase database;
  late FakeSleepAnalyzer analyzer;
  late RecordingRepository repository;

  /// 可控时钟：会话起始时间取的是"音频真正开始采集"那一刻，
  /// 所以测试必须能控制它，否则断言不了具体时间。
  late DateTime fakeNow;

  setUp(() {
    fakeNow = DateTime(2026, 10, 6, 23, 30);
    capture = FakeAudioCapture();
    foreground = FakeForegroundServiceController();
    database = SessionDatabase(
      factory: databaseFactoryFfi,
      databasePath: inMemoryDatabasePath,
    );
    analyzer = FakeSleepAnalyzer();
    repository = RecordingRepository(
      capture: capture,
      analyzer: analyzer,
      database: database,
      foregroundService: foreground,
      config: testConfig,
      clock: () => fakeNow,
    );
  });

  tearDown(() async => repository.dispose());

  final startedAt = DateTime(2026, 10, 6, 23, 30);

  group('启动录音', () {
    test('没有权限时不开录，给出错误提示', () async {
      capture.permissionGranted = false;

      await repository.start();

      expect(repository.state.isRecording, isFalse);
      expect(repository.state.error, contains('权限'));
      expect(capture.startCount, 0, reason: '没权限不该去开麦克风');
      expect(foreground.startCount, 0, reason: '也不该起前台服务');
    });

    test('通知权限被拒时照常开录，但明确告知后果', () async {
      foreground.notificationPermissionGranted = false;

      await repository.start();

      expect(foreground.notificationPermissionRequests, 1,
          reason: '必须主动申请一次——权限虽然由插件的清单声明，'
              '但没申请过的话 Android 13+ 上 granted 会一直是 false，'
              '通知会被系统静默丢弃');
      expect(repository.state.isRecording, isTrue,
          reason: '可见的常驻通知是保活手段，不是录音的前提，不该因为它被拒就不录');
      expect(repository.state.warning, contains('通知'));
      expect(repository.state.error, isNull,
          reason: '这是提醒不是错误——录音在正常跑');
    });

    test('通知权限正常时不留警告', () async {
      await repository.start();

      expect(foreground.notificationPermissionRequests, 1);
      expect(repository.state.warning, isNull);
    });

    test('录音结束后通知权限警告就不再挂着', () async {
      foreground.notificationPermissionGranted = false;
      await repository.start();
      expect(repository.state.warning, isNotNull);

      await repository.stop();

      expect(repository.state.warning, isNull,
          reason: '录音都结束了，这条提醒已经过期');
    });

    test('正常启动：起前台服务 + 开采集 + 模型初始化', () async {
      await repository.start();

      expect(repository.state.isRecording, isTrue);
      expect(repository.state.startedAt, startedAt);
      expect(repository.state.error, isNull);
      expect(capture.startCount, 1);
      expect(foreground.startCount, 1);
      expect(foreground.running, isTrue);
      expect(analyzer.initializeCount, 1);
      expect(foreground.lastTitle, isNotEmpty);
    });

    test('重复调用 start 是空操作', () async {
      await repository.start();
      await repository.start();

      expect(capture.startCount, 1);
      expect(foreground.startCount, 1);
    });

    test('前台服务启动失败时回滚，不留下半开状态', () async {
      foreground.failOnStart = true;

      await repository.start();

      expect(repository.state.isRecording, isFalse);
      expect(repository.state.error, contains('启动录音失败'));
      expect(capture.stopCount, greaterThanOrEqualTo(1),
          reason: '必须把已经开起来的采集关掉');
    });
  });

  group('录音过程', () {
    test('响亮音频会产生事件并能落库', () async {
      await repository.start();
      pushSeconds(capture, 4, amplitude: 0.5);
      await pumpEventQueue();

      final session = await repository.stop();

      expect(session, isNotNull);
      expect(session!.id, isNotNull, reason: '应当已落库并拿到 id');
      expect(session.events, isNotEmpty);
      expect(session.events.first.label, SleepCategory.snore);
      expect(session.stats.windowsInferred, greaterThan(0));
    });

    test('安静音频不触发推理，也不产生事件', () async {
      await repository.start();
      pushSeconds(capture, 4, amplitude: 0.001);
      await pumpEventQueue();

      final session = await repository.stop();

      expect(analyzer.classifyCount, 0, reason: '能量门控应当全部拦下');
      expect(session!.events, isEmpty);
      expect(session.stats.windowsVadSkipped, greaterThan(0));
    });

    test('停止后采集与前台服务都被关停', () async {
      await repository.start();
      pushSeconds(capture, 2, amplitude: 0.5);
      await pumpEventQueue();
      await repository.stop();

      expect(capture.stopCount, greaterThanOrEqualTo(1));
      expect(foreground.stopCount, 1);
      expect(foreground.running, isFalse);
      expect(repository.state.isRecording, isFalse);
    });

    test('分多块推送不会打乱窗口顺序', () async {
      await repository.start();
      // 每块远小于一个窗口（1 秒 = 16000 点），必须靠缓冲拼起来。
      // 40 块 × 4000 点 = 160000 点 = 恰好 10 秒。
      for (var i = 0; i < 40; i++) {
        capture.push(toPcm16(tone(amplitude: 0.5, length: 4000)));
      }
      await pumpEventQueue();

      final session = await repository.stop();

      expect(session!.stats.windowsTotal, 10);
      expect(session.stats.windowsInferred, 10);
      expect(repository.maxBacklog, lessThanOrEqualTo(40));
    });

    test('采集流出错不会让录音崩掉，只是记录错误', () async {
      await repository.start();
      capture.failWith(StateError('模拟采集失败'));
      await pumpEventQueue();

      expect(repository.state.isRecording, isTrue, reason: '不该因此中断整夜录音');
      expect(repository.state.error, contains('录音流出错'));
    });
  });

  group('停止录音', () {
    test('未在录音时 stop 返回 null', () async {
      expect(await repository.stop(), isNull);
    });

    test('stop 后状态里的统计与会话一致', () async {
      await repository.start();
      pushSeconds(capture, 4, amplitude: 0.5);
      await pumpEventQueue();

      final session = await repository.stop();

      expect(repository.state.eventCount, session!.stats.eventCount);
      expect(repository.state.windowsInferred, session.stats.windowsInferred);
      expect(repository.state.inferenceErrors, 0);
    });

    test('尾部不足一个窗口的音频不会丢', () async {
      await repository.start();
      capture.push(toPcm16(tone(amplitude: 0.5, length: 16000 * 3 + 8000)));
      await pumpEventQueue();

      final session = await repository.stop();

      expect(session!.stats.windowsTotal, 4, reason: '3 个整窗 + 1 个尾窗');
    });
  });

  group('会话管理', () {
    test('落库的会话能被列出与读取', () async {
      await repository.start();
      pushSeconds(capture, 3, amplitude: 0.5);
      await pumpEventQueue();
      final saved = await repository.stop();

      final list = await repository.listSessions();
      final loaded = await repository.loadSession(saved!.id!);

      expect(list.length, 1);
      expect(loaded!.id, saved.id);
      expect(loaded.events.length, saved.events.length);
    });

    test('删除会话后不再出现在列表里', () async {
      await repository.start();
      await repository.stop();
      final id = (await repository.listSessions()).single.id!;

      await repository.deleteSession(id);

      expect(await repository.listSessions(), isEmpty);
      expect(await repository.loadSession(id), isNull);
    });

    test('多次录音产生多条独立会话', () async {
      for (var i = 0; i < 3; i++) {
        // 每次录音把可控时钟往前拨一天，制造出三个不同的会话
        fakeNow = DateTime(2026, 10, 3 + i, 23);
        await repository.start();
        pushSeconds(capture, 2, amplitude: 0.5);
        await pumpEventQueue();
        fakeNow = fakeNow.add(const Duration(seconds: 5));
        await repository.stop();
      }

      final list = await repository.listSessions();

      expect(list.length, 3);
      // 按开始时间倒序
      expect(list.first.startedAt.day, 5);
    });
  });

  group('状态流', () {
    test('开始与停止都会推送状态', () async {
      final seen = <bool>[];
      final sub = repository.states.listen((s) => seen.add(s.isRecording));

      await repository.start();
      await repository.stop();
      await pumpEventQueue();
      await sub.cancel();

      expect(seen, contains(true));
      expect(seen.last, isFalse);
    });
  });
}
