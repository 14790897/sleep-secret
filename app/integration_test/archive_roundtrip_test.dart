import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sleep_secret/data/repositories/archive_repository.dart';
import 'package:sleep_secret/data/services/archive_service.dart';
import 'package:sleep_secret/data/services/database_factory_setup.dart';
import 'package:sleep_secret/data/services/directory_export_target.dart';
import 'package:sleep_secret/data/services/file_audio_clip_store.dart';
import 'package:sleep_secret/data/services/session_database.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';
import 'package:sleep_secret/domain/repositories/export_target.dart';
import 'package:sleep_secret/ui/core/theme.dart';
import 'package:sleep_secret/ui/features/archive/view_models/archive_view_model.dart';
import 'package:sleep_secret/ui/features/archive/views/archive_view.dart';

/// 导出 → 换设备 → 导入，全程走真实界面。
///
///   flutter test integration_test/archive_roundtrip_test.dart -d <设备>
///
/// ## 它补的是哪个洞
///
/// `archive_service_test.dart` 已经把搬家的逻辑盖住了（含真目录）。
/// `archive_view_test.dart` 把页面的状态盖住了（按钮、文案、禁用）。
///
/// 但**两者之间那截没人验**：真实的 `ArchiveRepository` 有没有把
/// 用户配的目录存进设置、下次能不能还原、`ArchiveView` 拿到真结果之后
/// 渲染出来的数字对不对、片段有没有真的落到新设备上。
/// 这一截以前是靠 PowerShell 模拟鼠标点像素验的——坐标、焦点、
/// 窗口遮挡每一环都在骗人，点空了也看不出来。
///
/// ## 桩在哪儿，为什么只桩这一处
///
/// 只有 [ExportTargetPicker.pick] 是桩：它弹的是**系统原生目录选择框**，
/// 自动化点不了，也没法在 CI 上点。它是平台 API 的边界，
/// 桩掉它不损失任何被验的逻辑——`restore` 走的仍是真实实现，
/// Android 上的 `content://` 解析路径也照跑。
///
/// 其余全是真的：真 sqflite、真文件系统、真 WAV 编码、真的 `ArchiveView`。
/// 只桩「弹系统选择框」这一步。
///
/// 它弹的是系统原生目录选择框，自动化点不了，也没法在 CI 上点。
/// 它是平台 API 的边界，桩掉不损失任何被验的逻辑——
/// [restore] 走的仍是真实实现，Android 上 `content://` 的解析路径也照跑。
class _StubPicker implements ExportTargetPicker {
  _StubPicker(this.directory);
  final String directory;

  @override
  Future<ExportTarget?> pick() async => DirectoryExportTarget(directory);

  @override
  Future<ExportTarget?> restore(String serialized) =>
      const DesktopExportTargetPicker().restore(serialized);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  configureDatabaseFactory();

  late Directory deviceRoot; // 「这台设备」的私有目录
  late Directory exportRoot; // 用户配的导出目录（现实中是网盘同步文件夹）

  setUpAll(() async {
    deviceRoot = await Directory.systemTemp.createTemp('archive_device');
    exportRoot = await Directory.systemTemp.createTemp('archive_export');
  });

  tearDownAll(() async {
    for (final d in [deviceRoot, exportRoot]) {
      if (await d.exists()) await d.delete(recursive: true);
    }
  });

  /// 集成测试跑在真实异步环境里，等的是真实时间。
  Future<void> settle(WidgetTester tester, [int ms = 400]) async {
    await tester.pump();
    await Future<void>.delayed(Duration(milliseconds: ms));
    await tester.pump();
  }

  /// 造一晚：带片段的鼾声事件 + 一个不带片段的噪音事件。
  Future<RecordingSession> seedNight(
    SessionDatabase db,
    FileAudioClipStore clips, {
    required int startedAtMs,
  }) async {
    final startedAt = DateTime.fromMillisecondsSinceEpoch(startedAtMs);
    final clipPath = await clips.save(
      sessionStartedAt: startedAt,
      startSeconds: 273,
      samples: Float32List.fromList(List.filled(16000, 0.3)),
      sampleRate: 16000,
    );
    expect(clipPath, isNotNull, reason: '片段应当真的写进磁盘');

    final session = RecordingSession(
      id: null,
      startedAt: startedAt,
      endedAt: startedAt.add(const Duration(hours: 7, minutes: 37)),
      events: [
        SoundEvent(
          label: SleepCategory.snore,
          startSeconds: 273,
          durationSeconds: 12,
          confidence: 0.46,
          snoreProbability: 0.46,
          windowCount: 4,
          clipPath: clipPath,
        ),
        const SoundEvent(
          label: SleepCategory.ambient,
          startSeconds: 300,
          durationSeconds: 21,
          confidence: 0.31,
          snoreProbability: 0.01,
          windowCount: 7,
        ),
      ],
      stats: const SessionStats(
        analyzedSeconds: 27450,
        windowsTotal: 9151,
        windowsInferred: 9151,
        windowsVadSkipped: 0,
        windowsLowConfidence: 492,
        eventCount: 2,
        snoreEventCount: 1,
        snoreSeconds: 12,
        categoryDistribution: {},
      ),
    );
    await db.insertSession(session);
    return session;
  }

  /// 一台「设备」：自己的库 + 自己的片段目录。
  ({SessionDatabase db, FileAudioClipStore clips, ArchiveRepository controller})
      buildDevice(String root) {
    final db = SessionDatabase(databasePath: '$root/sleep_secret.db');
    final clips = FileAudioClipStore(baseDirectory: Directory(root));
    final controller = ArchiveRepository(
      service: ArchiveService(database: db, clipStore: clips),
      database: db,
      picker: _StubPicker(exportRoot.path),
    );
    addTearDown(controller.dispose);
    addTearDown(db.close);
    return (db: db, clips: clips, controller: controller);
  }

  Future<void> pumpPage(WidgetTester tester, ArchiveRepository controller) async {
    // 整页要一次建出来才能断言下面的卡片
    tester.view.physicalSize = const Size(1000, 2600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: ArchiveView(viewModel: ArchiveViewModel(controller: controller)),
    ));
    await settle(tester, 300);
  }

  testWidgets('配目录 → 导出 → 换设备 → 导入，磁盘和库都对得上', (tester) async {
    final startedAtMs = DateTime(2026, 10, 6, 23, 10).millisecondsSinceEpoch;

    // ---------- 这台设备：录了一晚 ----------
    final device = buildDevice(deviceRoot.path);
    await seedNight(device.db, device.clips, startedAtMs: startedAtMs);

    await pumpPage(tester, device.controller);

    // 还没配目录：说清楚，不许点
    expect(find.text('还没选目录'), findsOneWidget);
    expect(buttonPressed(tester, '导出全部'), isNull);

    // ---------- 配目录（只桩了弹框那一步）----------
    await tester.tap(find.text('选择目录'));
    await settle(tester, 500);
    expect(find.text(exportRoot.path), findsOneWidget,
        reason: '配好的目录要显示出来');

    // ---------- 导出 ----------
    await tester.tap(find.text('导出全部'));
    await settle(tester, 1200);

    expect(find.textContaining('导出 1 晚'), findsOneWidget,
        reason: '页面报告的导出数要和实际做的一致');
    expect(find.textContaining('片段 1 个'), findsOneWidget);

    // 磁盘上真有了——不是只有界面说成功
    final json = File('${exportRoot.path}/sessions/$startedAtMs.json');
    final wav = File('${exportRoot.path}/clips/$startedAtMs/273000.wav');
    expect(await json.exists(), isTrue, reason: '这一晚的 JSON 应当写出来了');
    expect(await wav.exists(), isTrue, reason: '片段应当跟着搬过去');
    expect(await wav.length(), greaterThan(44), reason: '不该只有 WAV 头');
    expect(await json.length(), greaterThan(0));

    // 导出的是**可被人读的**东西，不是一串内部编码
    final text = await json.readAsString();
    expect(text, contains('sleep-secret'));
    expect(text, contains('snore'));
    expect(text, isNot(contains('SleepCategory.')),
        reason: '类别要序列化成名字，不能把 Dart 的 toString 写进文件');

    // ---------- 换设备：干净的库 + 干净的片段目录 ----------
    // 导出目录里的东西「跟着网盘同步过去」是用户自己的事，
    // 这里只模拟新设备：什么都没录过，但配了同一个目录。
    final freshRoot = await Directory.systemTemp.createTemp('archive_fresh');
    addTearDown(() async {
      if (await freshRoot.exists()) await freshRoot.delete(recursive: true);
    });
    final fresh = buildDevice(freshRoot.path);

    await pumpPage(tester, fresh.controller);
    expect(find.text('还没选目录'), findsOneWidget,
        reason: '新设备上还没配过目录');

    await tester.tap(find.text('选择目录'));
    await settle(tester, 500);

    // ---------- 导入 ----------
    await tester.tap(find.text('从目录导入'));
    await settle(tester, 1200);

    expect(find.textContaining('导入 1 晚'), findsOneWidget);
    expect(find.textContaining('片段 1 个'), findsOneWidget);

    // 库里真的有了
    final sessions = await fresh.db.listSessions();
    expect(sessions.length, 1, reason: '新设备上应当出现这一晚');
    expect(sessions.single.startedAt.millisecondsSinceEpoch, startedAtMs);

    final full = await fresh.db.loadSession(sessions.single.id!);
    expect(full, isNotNull);
    expect(full!.events.length, 2);
    expect(full.events.first.label, SleepCategory.snore);
    expect(full.stats.snoreSeconds, 12, reason: '统计要原样回来，不能被重算');

    // 关键时刻：片段路径是原样保留的，而且**文件要真的在新设备上**
    final clipPath =
        full.events.firstWhere((e) => e.clipPath != null).clipPath!;
    expect(clipPath, '$startedAtMs/273000.wav',
        reason: '数据库里存的就是这个相对路径，导入不能改写它');
    final resolved = await fresh.clips.resolve(clipPath);
    expect(resolved, isNotNull, reason: '只导了 JSON 没导音频的话，这里会是 null');
    expect(resolved, startsWith(freshRoot.path),
        reason: '片段应当落在本设备，不能在导出目录里就地播');
    expect(await File(resolved!).length(), greaterThan(44));
    expect(File('${freshRoot.path}/clips/$clipPath').existsSync(), isTrue);

    // ---------- 再导一次不会变成两晚 ----------
    await tester.tap(find.text('从目录导入'));
    await settle(tester, 1200);

    expect(find.textContaining('跳过 1 晚'), findsOneWidget,
        reason: '同一晚按开始时刻去重，界面要说清楚是跳过了');
    expect((await fresh.db.listSessions()).length, 1,
        reason: 'started_at 没有唯一约束，不去重就会越导越多');

    expect(tester.takeException(), isNull);
    expect(fresh.clips.failureCount, 0, reason: '导入过程中不该有写入失败');
  });

  testWidgets('目录被删掉之后，页面如实说失效、并不让点', (tester) async {
    // 网盘目录被用户删了、或者 SAF 授权被系统收回——非常常见。
    // 要求：**如实显示**，而不是等用户点了按钮再抛一堆看不懂的异常。
    final doomed = await Directory.systemTemp.createTemp('archive_doomed');
    final spare = await Directory.systemTemp.createTemp('archive_d2');
    addTearDown(() async {
      for (final d in [doomed, spare]) {
        if (await d.exists()) await d.delete(recursive: true);
      }
    });

    final device = buildDevice(spare.path);
    final controller = ArchiveRepository(
      service: ArchiveService(database: device.db, clipStore: device.clips),
      database: device.db,
      picker: _StubPicker(doomed.path),
    );
    addTearDown(controller.dispose);

    await pumpPage(tester, controller);
    await tester.tap(find.text('选择目录'));
    await settle(tester, 500);
    expect(buttonPressed(tester, '导出全部'), isNotNull,
        reason: '目录还在的时候应当能点');

    // 目录没了
    await doomed.delete(recursive: true);

    // 重开页面：应当看到失效提示，按钮禁用
    await pumpPage(tester, controller);
    expect(find.textContaining('这个目录现在用不了'), findsOneWidget);
    expect(buttonPressed(tester, '导出全部'), isNull,
        reason: '点下去再报错，等于把配置问题伪装成操作失败——而这一下会搬整晚的音频');
    expect(buttonPressed(tester, '从目录导入'), isNull);
  });
}

/// 按钮的 onPressed。为 null 就是禁用。
VoidCallback? buttonPressed(WidgetTester tester, String label) => tester
    .widget<ButtonStyleButton>(find.ancestor(
      of: find.text(label),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    ))
    .onPressed;
