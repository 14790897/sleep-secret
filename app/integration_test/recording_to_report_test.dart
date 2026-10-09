import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import '../test/helpers/pump_app.dart';
import 'package:integration_test/integration_test.dart';
import 'package:sqflite/sqflite.dart' show inMemoryDatabasePath;
import 'package:sleep_secret/data/repositories/recording_repository.dart';
import 'package:sleep_secret/data/repositories/sleep_analysis_repository.dart';
import 'package:sleep_secret/data/services/database_factory_setup.dart';
import 'package:sleep_secret/data/services/event_player.dart';
import 'package:sleep_secret/data/services/file_audio_clip_store.dart';
import 'package:sleep_secret/data/services/onnx_classifier_service.dart';
import 'package:sleep_secret/data/services/session_database.dart';
import 'package:sleep_secret/data/services/wav_decoder_service.dart';
import 'package:sleep_secret/l10n/app_localizations.dart';
import 'package:sleep_secret/l10n/app_strings.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/ui/features/home/views/home_view.dart';
import 'package:sleep_secret/ui/features/recording/view_models/recording_view_model.dart';
import 'package:sleep_secret/ui/features/recording/views/recording_view.dart';
import 'package:sleep_secret/ui/features/report/view_models/report_view_model.dart';

import '../test/helpers/fake_services.dart';
import '../test/helpers/wav_replay_capture.dart';

/// 截图开关。
///
/// 截图**必须从测试内部取**（那时 App 正在真机上渲染），再经 driver 传回主机。
/// 所以它只在 `flutter drive` + `--dart-define=SHOTS=true` 时打开；
/// CI 走 `flutter test integration_test/all_tests.dart`，那里没有 driver 接回调。
///
///   flutter drive --driver=test_driver/screenshots.dart \
///     --target=integration_test/recording_to_report_test.dart \
///     -d emulator-5554 --dart-define=SHOTS=true
const bool shots = bool.fromEnvironment('SHOTS');

/// 从「采集」到「界面」的整条链路。
///
///   flutter test integration_test/recording_to_report_test.dart -d <设备>
///
/// ## 它补的是哪个洞
///
/// 之前两个测试谁都没连起来：
/// - `full_flow_test.dart` 驱动界面，但录音产不出事件，报告页是**手写种子数据**验的；
/// - `analysis_pipeline_test.dart` 把音频**直接喂进 NightAnalysisEngine**，
///   绕过了 RecordingRepository。
///
/// 结果是**分析真正产出的结果从来没渲染到界面上验证过**。
/// 中间那段——`stop()` 之后的收尾与落库、事件合并后的实际时间线、
/// 报告页读真实数据渲染——是空的。而「没被执行过的路径」和
/// 「能工作的路径」在观察上无法区分，这个项目已经因此吃过亏。
///
/// ## 怎么绕开麦克风
///
/// 把 [WavReplayAudioCapture] 注入到 `AudioCapture` 这个接口上。
/// 被换掉的只有 `RecordAudioCapture`——它是 `record` 插件的一层胶水，
/// 约 40 行且没有判断逻辑。它之上的一切都是真代码真逻辑。
///
/// 采集格式本身（16kHz / PCM16 / 单声道）由 `microphone_diagnostic_test.dart`
/// 在真机上把关，那条测不了的在架构上就该是「真机诊断」而不是「CI 断言」。
void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  configureDatabaseFactory();

  late OnnxClassifierService classifier;
  late SleepAnalysisRepository analyzer;
  late Directory supportDir;
  late FileAudioClipStore clipStore;

  setUpAll(() async {
    // ⚠️ 必须**自己**初始化那份"给后台用的"文案。
    //
    // `RecordingRepository.start()` 要读通知栏标题（拿不到 BuildContext 的
    // 地方走 `appStrings`），而 `appStrings` 平时是 `main.dart` 里的
    // `_SyncAppStrings` 赋的值——这个测试自己拼 MaterialApp，轮不到它。
    //
    // 这曾经是个**顺序相关的测试**：单独跑必红，跟在 `full_flow_test`
    // 后面跑就绿（那个泵了真 App，顺手把全局设上了）。聚合入口掩盖了它，
    // 2026-10-07 单独跑才发现。
    setAppStrings(await AppLocalizations.delegate.load(const Locale('zh')));

    classifier = OnnxClassifierService(assetKey: 'assets/models/ced-tiny.onnx');
    analyzer = SleepAnalysisRepository(classifier: classifier);
    supportDir = await Directory.systemTemp.createTemp('rec_to_report');
    clipStore = FileAudioClipStore(baseDirectory: supportDir);
  });

  tearDownAll(() async {
    classifier.dispose();
    if (await supportDir.exists()) await supportDir.delete(recursive: true);
  });

  /// 等真实时间过去，而不是推进假时钟——集成测试跑在真实异步环境里。
  Future<void> settle(WidgetTester tester, [int ms = 500]) async {
    await tester.pump();
    await Future<void>.delayed(Duration(milliseconds: ms));
    await tester.pump();
  }

  Future<Float32List> loadWave(String asset) async {
    final bytes = await rootBundle.load(asset);
    return const WavDecoderService().decode(bytes.buffer.asUint8List()).samples;
  }

  /// 一段音频的峰值。
  ///
  /// 判断"写出来的片段到底有没有声音"要用它——只看文件长度的话，
  /// **一整段零采样点也能通过**，而播放面板上就是一条直线。
  double peakOf(Float32List samples) =>
      samples.fold(0.0, (m, v) => v.abs() > m ? v.abs() : m);

  /// 把素材重复到指定时长。
  ///
  /// 素材只有 5 秒，而窗口 3 秒、最小事件时长 6 秒——
  /// 不拉长的话凑不满一个事件，测出来是假阴性。
  Float32List tile(Float32List src, int seconds) {
    final want = 16000 * seconds;
    final out = Float32List(want);
    for (var i = 0; i < want; i++) {
      out[i] = src[i % src.length];
    }
    return out;
  }

  /// 组装一个**真实**的录音仓库，只把采集器换成回放。
  ({RecordingRepository repository, WavReplayAudioCapture capture}) buildRepo(
    Float32List audio,
  ) {
    final capture = WavReplayAudioCapture(samples: audio);
    final repository = RecordingRepository(
      capture: capture,
      analyzer: analyzer,
      // 用内存库，不污染设备上真实的会话数据
      database: SessionDatabase(databasePath: inMemoryDatabasePath),
      foregroundService: FakeForegroundServiceController(),
      clipStore: clipStore,
    );
    return (repository: repository, capture: capture);
  }

  /// 跑完一次完整的「开始 → 喂数据 → 停止 → 落库」。
  Future<
      ({
        RecordingSession session,
        RecordingRepository repository,
        WavReplayAudioCapture capture,
      })> runSession(
    WidgetTester tester,
    Float32List audio,
  ) async {
    final built = buildRepo(audio);
    addTearDown(built.repository.dispose);

    await built.repository.start();
    expect(built.repository.state.isRecording, isTrue,
        reason: '给了权限、模型也加载得动，就应该进录音态');

    // 必须等数据推完再 stop：收尾时会先取消订阅、再等队列排空，
    // 订阅一取消，还缓冲在流里的块就丢了。
    await built.capture.finished;
    await settle(tester, 600);

    final session = await built.repository.stop();
    expect(session, isNotNull, reason: 'stop() 应当返回本次会话');

    // 采集器确实把整段都推完了——否则下面的断言可能是在空数据上通过的
    expect(built.capture.pushedSamples, audio.length,
        reason: 'fixture 没有完整推完，测试结果不可信');

    return (
      session: session!,
      repository: built.repository,
      capture: built.capture,
    );
  }

  group('分析结果真的落到库里', () {
    testWidgets('真实鼾声走完整条链路，产出鼾声事件并落库', (tester) async {
      final audio = tile(
        await loadWave('assets/testdata/real/snore_01.wav'),
        30,
      );
      final r = await runSession(tester, audio);
      final session = r.session;

      expect(session.events, isNotEmpty,
          reason: '30 秒真实鼾声应当产出事件。为 0 说明采集→仓库→引擎这一段断了');

      final snoreEvents =
          session.events.where((e) => e.label == SleepCategory.snore).toList();
      expect(snoreEvents, isNotEmpty,
          reason: '这段素材在模型里是明确的鼾声（>0.9），检出不了说明链路有问题');

      // 统计口径要和事件对得上——界面上展示的是统计，不是事件列表
      expect(session.stats.snoreEventCount, snoreEvents.length,
          reason: '会话统计里的鼾声段数和实际事件对不上');
      expect(session.stats.eventCount, session.events.length);
      expect(session.stats.analyzedSeconds, greaterThan(0));

      // 鼾声事件应当带电平——不然报告里那句「约 XX 分贝」永远不出现。
      // 这条是**引擎 → 事件**那一段的证明：界面上的分贝不是凭空算的，
      // 是引擎在跑窗口时记下来的。
      expect(snoreEvents.every((e) => e.hasLevel), isTrue,
          reason: '引擎没有把窗口电平记到事件上');
      expect(snoreEvents.first.peakRms, greaterThan(0),
          reason: '真实鼾声的电平不该是 0');

      // 鼾声事件应当带可回放的片段
      final withClip = snoreEvents.where((e) => e.clipPath != null).toList();
      expect(withClip, isNotEmpty, reason: '鼾声事件应当保留音频片段（默认开着）');
      final resolved = await clipStore.resolve(withClip.first.clipPath!);
      expect(resolved, isNotNull, reason: '片段路径应当能还原成真实文件');

      // ⚠️ 光看"文件比头部长"是不够的：文件长度对、内容全是零，照样通过，
      // 而播放面板上会是一条直线。用户就是这么发现问题的。
      // 这里要求片段里真的有音频，而且和喂进去的素材一个量级。
      final clip = const WavDecoderService()
          .decode(await File(resolved!).readAsBytes());
      expect(peakOf(clip.samples), greaterThan(0.02),
          reason: '片段里全是接近 0 的采样点——波形会是一条直线');
      expect(peakOf(clip.samples),
          greaterThan(peakOf(audio) * 0.5),
          reason: '写盘的音频不该比源素材轻一个量级');
    });

    /// 一段「一夜」：安静打底，中间插几段倒吸气。
    ///
    /// 不能直接 tile 成 30 秒——那是**连续**的倒吸气，现实里不存在，
    /// 模型也未必还认它是倒吸气。真实情况是安静中间偶尔来一声。
    Float32List nightWithGasps(Float32List gasp, {int episodes = 4}) {
      const gap = 16000 * 6; // 6 秒安静，够事件定案（mergeGapSeconds = 9）
      final parts = <Float32List>[];
      var seed = 999;
      for (var i = 0; i < episodes; i++) {
        // 固定种子的低幅噪声当底噪，避免每次跑不一致
        final q = Float32List(gap);
        for (var j = 0; j < gap; j++) {
          seed = (seed * 1103515245 + 12345) & 0x7fffffff;
          q[j] = ((seed % 2000) / 1000.0 - 1.0) * 0.0015;
        }
        parts.add(q);
        parts.add(gasp);
      }
      final total = parts.fold<int>(0, (a, p) => a + p.length);
      final out = Float32List(total);
      var at = 0;
      for (final p in parts) {
        out.setRange(at, at + p.length, p);
        at += p.length;
      }
      return out;
    }

    testWidgets('真实倒吸气走完整条链路，产出能回放的信号事件', (tester) async {
      final audio = nightWithGasps(
        await loadWave('assets/testdata/real/real_gasp.wav'),
      );
      final r = await runSession(tester, audio);
      final session = r.session;

      final signals = session.events.where((e) => e.isSignal).toList();
      expect(signals, isNotEmpty,
          reason: '这段素材模型判成 Gasp（0.42~0.49），一段都没有说明链路断了');
      expect(signals.every((e) => e.signal == 'Gasp'), isTrue);
      expect(session.stats.signalsCollected, isTrue,
          reason: '报告靠这个标志区分「没查」和「没有」，没写上的话'
              '新录的夜晚也会显示成「升级前的记录」');

      // ⚠️ 这两条是这次改动的**目的**：高危信号得能听。
      // 事件有 6 秒下限，而倒吸气只有一两秒——不豁免的话它连事件都成立不了，
      // 也就永远不会有片段。这条测试就是盯着那个豁免还在不在。
      final playable = signals.where((e) => e.clipPath != null).toList();
      expect(playable, isNotEmpty, reason: '高危信号必须留下片段，否则点了没反应');
      final resolved = await clipStore.resolve(playable.first.clipPath!);
      expect(resolved, isNotNull, reason: '片段路径应当能还原成真实文件');

      // 同上：要能听，不是"文件存在"。
      final clip = const WavDecoderService()
          .decode(await File(resolved!).readAsBytes());
      expect(peakOf(clip.samples), greaterThan(0.02),
          reason: '片段里全是接近 0 的采样点——波形会是一条直线');
    });

    testWidgets('同一份数据从库里读回来要和写进去的一致', (tester) async {
      final audio = tile(
        await loadWave('assets/testdata/real/snore_01.wav'),
        30,
      );

      final built = buildRepo(audio);
      addTearDown(built.repository.dispose);
      await built.repository.start();
      await built.capture.finished;
      await settle(tester, 600);
      final written = await built.repository.stop();

      // 走仓库自己的公开 API 读回来，不直接查表
      final reloaded = await built.repository.loadSession(written!.id!);
      expect(reloaded, isNotNull, reason: '刚写进去的会话应当能按 id 读回来');
      expect(reloaded!.events.length, written.events.length,
          reason: '读回来的事件数和写进去的不一致');
      expect(reloaded.stats.snoreEventCount, written.stats.snoreEventCount);
      expect(
        reloaded.events.map((e) => e.label).toList(),
        written.events.map((e) => e.label).toList(),
        reason: '事件的类别顺序也要一致——时间线是靠顺序还原的',
      );
      // 高危信号那一列也得真的落盘。这条素材多半一个信号都没有，
      // 但「有没有都写上」和「写了没读回来」是两回事——
      // 后者会让报告里那张卡永远显示成「升级前的记录」。
      expect(reloaded.stats.signalsCollected, isTrue,
          reason: '新录音一律标成「收集过信号」');
      expect(
        reloaded.events.map((e) => e.signal).toList(),
        written.events.map((e) => e.signal).toList(),
        reason: '信号要跟着事件一起往返，不然那一声就点不开了',
      );

      // 「详细视图」那张表靠这两个：原始标签计数得真的被引擎收集到，
      // 而且要真的落盘读回来。少任何一步，报告里那张卡只会显示
      // 「升级前的记录不收集它」——看起来像是版本问题，其实是链路断了。
      expect(written.stats.rawLabelCounts, isNotEmpty,
          reason: '引擎没有把窗口的原始标签记下来');
      expect(written.stats.rawLabelCount('Snoring'), greaterThan(0),
          reason: '这段素材模型判成鼾声（>0.9），原始标签里必须有 Snoring');
      expect(reloaded.stats.rawLabelCounts, written.stats.rawLabelCounts,
          reason: '原始标签计数要能原样读回来');

      final listed = await built.repository.listSessions();
      expect(listed.map((s) => s.id), contains(written.id));
    });
  });

  group('低信噪比的劣质输入也走得通', () {
    // `bandlimited_snore.wav` 是一段 CC0 真实鼾声，**人工做残**之后的结果：
    // 削掉 320Hz 以下、再压上 -6dB 的房间噪声。
    //
    // 为什么要专门留着它：鼾声的能量集中在 60~300Hz，一旦这条被削掉，
    // 模型能拿到的只剩谐波和失真。手机没放在枕边、或者隔着被子，
    // 拿到的就是这种输入。它是最难的一档。
    //
    // ⚠️ 它是**加工出来的**，不是"拿麦克风隔着房间真录的"——原来那个
    // `mic_farfield_snore.wav` 确实是真录的，但它是拿 ESC-50（CC BY-NC）
    // 外放之后再录，属于衍生作品，不能留在仓库里。现在换成从 CC0 素材
    // 加工，**难点一样，许可干净**。见 `scripts/fetch_test_audio.py`。
    //
    // 这里**不断言类别**——那取决于模型能力，不该由这条测试来判对错。
    // 它断言的是：这种输入不会把链路搞崩，产出的东西依然自洽。
    testWidgets('被削掉低频、信噪比很低的鼾声不会 crash，产出自洽的结果', (tester) async {
      final audio = await loadWave('assets/testdata/real/bandlimited_snore.wav');
      expect(audio.length, greaterThan(16000 * 20),
          reason: 'fixture 应当有足够长度，否则跑不满窗口');

      final r = await runSession(tester, audio);
      final session = r.session;

      expect(r.repository.state.inferenceErrors, 0,
          reason: '单个窗口推理失败会被吞掉，累积起来就说明有问题');
      expect(session.stats.windowsTotal, greaterThan(0));

      // 能量门控**默认关着**，所以每一段都会送进模型，不该有窗口被跳过。
      // （门控开着时它确实会跳掉这段录音里的大部分安静窗口——
      // 那条行为覆盖在单元测试 night_analysis_engine_test 里。）
      expect(session.stats.windowsVadSkipped, 0);

      // 事件与统计自洽
      expect(session.stats.eventCount, session.events.length);
      for (final e in session.events) {
        expect(e.durationSeconds, greaterThanOrEqualTo(6.0),
            reason: '短于 minEventSeconds 的碎片不该出现在结果里');
      }
    });
  });

  group('结果真的渲染到界面上', () {
    testWidgets('录音 → 停止 → 报告页显示真实产出的鼾声事件', (tester) async {
      final audio = tile(
        await loadWave('assets/testdata/real/snore_01.wav'),
        30,
      );

      final built = buildRepo(audio);
      addTearDown(built.repository.dispose);
      final player = JustAudioEventPlayer();
      addTearDown(player.dispose);

      // 用真实界面，只把依赖换成注入了回放采集器的仓库。
      // 构造方式和 main.dart 一致——HomeView 就是 App 的外壳。
      // 区别只有 locale 钉死（测试默认 en_US，不钉会渲染成英文）。
      await tester.pumpWidget(localizedApp(
        home: HomeView(
          localeController: FakeLocaleController(),
          recordingViewModel: RecordingViewModel(controller: built.repository),
          reportViewModelFactory: (session) => ReportViewModel(
            session: session,
            clipStore: clipStore,
            player: player,
          ),
        ),
      ));
      await settle(tester, 1200);

      // 底部导航的选中图标也是 Icons.mic，所以要限定在录音页内部找
      // 开始和结束是**同一个按钮**（那颗月亮），所以两个 finder 一样。
      // 不按图标找：月亮是自绘的，Icons.mic / Icons.stop 都没有了。
      final heroButton = find.byKey(RecordingKeys.heroButton);
      final micButton = heroButton;
      final stopButton = heroButton;

      // ---- 点开始录音 ----
      final startedAt = DateTime.now();
      await tester.tap(micButton);
      await settle(tester, 2500);

      expect(find.text('录音中'), findsOneWidget,
          reason: '注入了回放采集器、权限也给了，就该进录音态');

      // ---- 等整段喂完 ----
      await built.capture.finished;
      await settle(tester, 600);

      // ---- 停止 ----
      await tester.tap(stopButton);
      await settle(tester, 2000);

      expect(find.text('点一下开始'), findsOneWidget, reason: '停止后回到待机态');

      // ---- 进报告页 ----
      await tester.tap(find.text('报告'));
      await settle(tester, 1500);
      expect(find.text('历史记录'), findsOneWidget,
          reason: '刚录完的一晚应当出现在报告列表里');

      // 卡片上直接写着鼾声段数——这行文字就是「分析结果 → 界面」的证据
      expect(find.textContaining('鼾声'), findsWidgets,
          reason: '列表卡片应当显示鼾声统计');

      // 点进详情。不能点 Card.last——列表第一个 Card 是顶部趋势卡，
      // 点它不会跳转。按日期文本精确定位刚录的那一晚。
      final dateLabel = '${startedAt.month}月${startedAt.day}日';
      expect(find.textContaining(dateLabel), findsWidgets,
          reason: '历史列表里应当能看到刚录的这一晚（$dateLabel）');
      await tester.tap(find.textContaining(dateLabel).first);
      await settle(tester, 2000);

      // 报告页很长，ListView 只建可视区域。把视口调高让分区都建出来。
      tester.view.physicalSize = const Size(1080, 6400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await settle(tester, 1200);

      expect(find.text('事件明细'), findsOneWidget, reason: '应当进入报告详情页');
      expect(find.text('整夜声音'), findsOneWidget);

      // 界面上的数字要和库里的一致——不一致就是渲染层读错了数据
      final listed = await built.repository.listSessions();
      final latest = listed.first;
      expect(latest.stats.snoreEventCount, greaterThan(0));
      expect(find.textContaining('鼾声段时长'), findsOneWidget);

      // 鼾声事件带片段，界面上应当有可试听的按钮
      expect(find.byIcon(Icons.play_circle_outline), findsWidgets,
          reason: '鼾声事件保留了片段，界面上应当能点开听');

      // 「鼾声录音」卡：把所有带录音的片段**集中**列一份。
      // 段数要和库里真正带片段的条数对得上——数不对说明过滤条件写错了。
      //
      // ⚠️ `listSessions()` 返回的是**不带事件**的摘要，`latest.events` 是空的。
      // 要比事件就得按 id 读完整的那一份。
      final full = await built.repository.loadSession(listed.first.id!);
      expect(full, isNotNull);
      final withClip = full!.events.where((e) => e.hasClip).toList();
      expect(withClip, isNotEmpty, reason: '这条测试的前提是录到了带片段的鼾声');

      // 电平要**能落盘再读回来**——只有内存里有的话，重启 App 就没了
      expect(full.events.where((e) => e.hasLevel), isNotEmpty,
          reason: '电平没有写进数据库，或者读回来时丢了');
      expect(find.text('鼾声录音'), findsOneWidget);
      expect(find.textContaining('共 ${withClip.length} 段 ·'), findsOneWidget,
          reason: '鼾声录音卡应当列出全部 ${withClip.length} 段录音');

      // 截图。**只有 `flutter drive` + `--dart-define=SHOTS=true` 时才走**——
      // 用 `flutter test` 跑（CI 就是）时没有 driver 来接这个回调。
      // 见 `test_driver/screenshots.dart`。
      if (shots) {
        // Android 上要先切到 ImageReader，否则抓到的是空白
        await binding.convertFlutterSurfaceToImage();
        await settle(tester, 500);
        await binding.takeScreenshot('report-detail');
      }

      expect(tester.takeException(), isNull);
    });
  });
}
