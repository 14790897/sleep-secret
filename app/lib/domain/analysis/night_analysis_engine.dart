import 'dart:async';
import 'dart:typed_data';

import '../models/recording_session.dart';
import '../models/sleep_category.dart';
import '../models/sound_event.dart';
import '../repositories/audio_clip_store.dart';
import '../repositories/sleep_analyzer.dart';
import 'adaptive_noise_floor.dart';
import 'analysis_config.dart';
import 'energy_vad.dart';
import 'event_accumulator.dart';
import 'pcm_ring_buffer.dart';
import 'pcm_window_buffer.dart';

/// 整夜分析引擎：把录音流变成事件时间线。
///
/// 数据流：
///   PCM 块 -> [PcmWindowBuffer] 切成定长窗口
///         -> 能量门控（RMS 不过阈值就跳过，省掉一次推理）
///         -> [SleepAnalyzer] 端侧推理
///         -> [EventAccumulator] 合并成事件 + 累计统计
///
/// 只有**一道**闸门：能量。过了它就一定产生事件，取 argmax。
///
/// 这里曾经还有第二道「置信度门控」（得分太低就判未识别、不产生事件），
/// 后来去掉了——实测它在真实音频上什么也不做，而它声称要防的问题
/// 本来就不会发生。详细证据见 [_processWindow] 里的说明。
class NightAnalysisEngine {
  NightAnalysisEngine({
    required this._analyzer,
    this.config = const AnalysisConfig(),
    this._clipStore,
  })  : _noiseFloor = config.vadAdaptive
            ? AdaptiveNoiseFloor(
                historyWindows: config.vadHistoryWindows,
                percentile: config.vadNoisePercentile,
                minSamples: config.vadMinSamples,
                multiplier: config.vadNoiseMultiplier,
                lowerBound: config.vadLowerBound,
                upperBound: config.vadUpperBound,
                fallbackThreshold: config.vadRms,
              )
            : null,
        _buffer = PcmWindowBuffer(
          windowSamples: config.windowSamples,
          hopSamples: config.hopSamples,
          sampleRate: config.sampleRate,
        ),
        _ring = PcmRingBuffer(capacitySamples: config.clipBufferSamples),
        _accumulator = EventAccumulator(config: config),
        recordClips = config.recordClips,
        vadEnabled = config.vadEnabled {
    if (config.recordClips && !config.clipBufferIsAdequate) {
      throw ArgumentError(
        'clipBufferSeconds(${config.clipBufferSeconds}) 连片段开头那一小段都补不出来'
        '（需要一个窗口 + 前余量），事件开张时音频早被覆盖了',
      );
    }
    if (config.recordClips && config.hopSeconds != config.windowSeconds) {
      throw ArgumentError(
        '片段要求窗口既不重叠、也不跳步（hop == window）：'
        '重叠会写进重复的音频，跳步会让补回来的开头和事件时间轴错位。',
      );
    }
    // 回调要在构造体里接——它引用了引擎自身，初始化列表里拿不到 this。
    _accumulator.onEventClosed = _onEventClosed;
  }

  final SleepAnalyzer _analyzer;
  final AnalysisConfig config;
  final AudioClipStore? _clipStore;

  /// 噪声底估计器。
  ///
  /// ⚠️ 只要配置开着自适应就**一直建着**，**不看当前是否开了门控**——
  /// 门控是能中途拨的（「关于」页那个开关），而它一打开就得立刻有个
  /// 已经热好的阈值可用。代价是每 3 秒排一次 400 个数，相对 30ms 的推理
  /// 可以忽略。
  final AdaptiveNoiseFloor? _noiseFloor;

  final PcmWindowBuffer _buffer;

  /// 当前生效的能量门控阈值。**门控关着时返回 null**——
  /// 那时候不存在"门槛"这回事，界面不该再画一条线。
  ///
  /// 界面上的电平条要画在**这个**位置，不能画在配置里的固定值上——
  /// 阈值自适应之后两者会不一样，画错了就是在骗用户。
  double? get vadThreshold {
    if (!vadEnabled) return null;
    return _noiseFloor?.threshold ?? config.vadRms;
  }

  /// 估计出来的噪声底。样本不足时为 null。
  double? get noiseFloor => _noiseFloor?.floor;

  /// 最近的原始音频。事件是回溯确认的，等定案时那段声音早就流过去了，
  /// 所以必须留一份缓冲回头切。
  final PcmRingBuffer _ring;

  final EventAccumulator _accumulator;

  /// 正在录的那一段事件音频。定案时决定留下还是删掉。
  ClipWriter? _writer;

  /// 这一段的音频放弃记录（开头那几秒已经被缓冲覆盖）。
  ///
  /// 保持到事件定案为止——不然下一窗又会开一个新文件、从声音中间接上。
  bool _audioOptOut = false;

  /// 已经写进当前片段的采样点数。用来卡 [AnalysisConfig.maxEventClipSeconds]。
  int _writerSamples = 0;

  /// 正在写盘的片段。finish() 要等它们全部落盘，否则会话落库时还没拿到路径。
  final List<Future<void>> _pendingClips = [];

  int _inferenceErrors = 0;
  int _inferredCount = 0;
  double _lastRms = 0;
  double _peakRms = 0;
  int _clipsSaved = 0;
  int _clipsSkipped = 0;
  DateTime? _startedAt;

  /// 推理失败的窗口数。单个窗口失败不应该中断整夜录音，
  /// 但累计异常需要能被看见。
  int get inferenceErrors => _inferenceErrors;

  /// 是否落音频片段。可运行时切换——这是隐私开关，
  /// 用户中途关掉就该立刻停止落盘，而不是等下次启动。
  bool recordClips;

  /// 能量门控是否启用。**可运行时切换**，和 [recordClips] 一个道理：
  /// 「关于」页上有这个开关，拨了就该立刻生效，而不是等下次录音。
  ///
  /// 关掉时每一段都送进模型（当前默认）；打开时低于门槛的窗口直接跳过。
  /// 阈值见 [vadThreshold]，它由 [_noiseFloor] 按房间噪声底自适应。
  bool vadEnabled;

  /// 调能量门控的**基准**阈值（「关于」页那个滑块）。
  ///
  /// 传的是 **RMS**，不是分贝——分贝是界面上的估算单位（误差有 ±10dB），
  /// 真正参与比较的是这个。换算用 `domain/analysis/decibel.dart` 里那对
  /// 互逆的函数，和电平条、事件列表是同一套公式。**拨了立刻生效**。
  ///
  /// 适应的上下界按同一套比例跟着走（见 [AnalysisConfig.vadLowerRatio]）。
  void setVadBaseRms(double rms) {
    _noiseFloor?.retune(
      base: rms,
      lowerRatio: AnalysisConfig.vadLowerRatio,
      upperRatio: AnalysisConfig.vadUpperRatio,
    );
  }

  /// 最近一个窗口的输入电平（RMS）。
  ///
  /// 界面用它显示电平条——录音时看不见有没有声音进来，用户没法判断
  /// 手机是不是被挡住了。这也是排查"整夜录到静音"最直接的依据。
  double get lastRms => _lastRms;

  /// 本次录音以来的最高电平。
  double get peakRms => _peakRms;

  /// 成功写盘的音频片段数。
  int get clipsSaved => _clipsSaved;

  /// 想存但没存成的片段数（缓冲已覆盖、磁盘写入失败等）。
  int get clipsSkipped => _clipsSkipped;

  /// 已成立且**最终会被保留**的事件。
  ///
  /// 这里按 [AnalysisConfig.keepsEvent] 过滤过，和收尾时落库的口径一致。
  /// 不过滤的话，录音界面会显示"已检出 N 个事件"，而报告里是 0——
  /// 用户看到中途出现的数字最后消失，会认为应用不可靠。
  List<SoundEvent> get events => _accumulator.eventsSoFar
      .where(config.keepsEvent)
      .toList(growable: false);

  int get windowsProcessed => _accumulator.windowCount;

  /// 真正送进模型的窗口数（已通过能量门控）。
  int get windowsInferred => _inferredCount;

  /// 当前推理比例。界面用它展示"省了多少算力"。
  double get inferenceRatio => _accumulator.windowCount == 0
      ? 0.0
      : _inferredCount / _accumulator.windowCount;

  /// 已缓冲但还没凑满一个窗口的样本数。
  int get pendingSamples => _buffer.pendingSamples;

  DateTime? get startedAt => _startedAt;

  void start(DateTime now) {
    _startedAt = now;
  }

  /// 送入一块 PCM（16-bit 小端，单声道 16kHz），返回当前累计的事件列表。
  Future<List<SoundEvent>> feedPcm(Uint8List pcmBytes) =>
      feedSamples(pcm16ToFloat32(pcmBytes));

  /// 送入一块浮点采样点。
  Future<List<SoundEvent>> feedSamples(Float32List samples) async {
    final windows = _buffer.add(samples);
    for (final window in windows) {
      // ⚠️ 环形缓冲**逐窗写**，而且写在处理这一窗之前。
      //
      // 它存在的唯一理由是给片段补开头那几秒，所以必须停在"已经处理到哪儿"。
      // 早先是把整块 samples 一次写进去——一次喂一大块时（回放、测试、
      // 录音插件的突发块），缓冲还没等窗口被处理就被整块冲了一遍，
      // 事件开张时开头那几秒早没了，片段只能整段放弃。
      //
      // 逐窗写还顺带保证缓冲里的采样序号和窗口时间轴**逐点对应**，
      // 这正是补头能对准的前提（所以片段要求 hop == window）。
      _ring.write(window.samples);
      await _processWindow(window);
    }
    return _accumulator.eventsSoFar;
  }

  /// 事件定案：把它的音频收尾（留下或删掉）。
  void _onEventClosed(int index, SoundEvent event) {
    if (!recordClips) return;
    _pendingClips.add(_finishEventAudio(index, event));
  }

  /// 一段事件结束：决定它的音频留下还是删掉。
  ///
  /// 音频是边录边写盘的（见 [_followEventAudio]），这里只做决定：
  /// 是鼾声或高危信号就落定，否则把临时文件删掉。
  Future<void> _finishEventAudio(int index, SoundEvent event) async {
    final writer = _writer;
    _writer = null;
    final optedOut = _audioOptOut;
    _audioOptOut = false;
    _writerSamples = 0;

    // writer 为空有两种情况：从来没开成（磁盘满、开头补不回来），
    // 或者中途被关掉了片段开关。前者要计数——"想存但没存成"是用户
    // 可能需要知道的事，不能静默咽掉。
    if (writer == null) {
      if (optedOut) _clipsSkipped++;
      return;
    }

    // 只留鼾声和高危信号。梦话和咳嗽也录的话，隐私含义不一样，先不做。
    //
    // 高危信号必须留：用户要的就是把那几声倒吸气翻出来听。它们靠
    // [AnalysisConfig.keepsEvent] 豁免最短时长，不然一两秒的声音
    // 连事件都成立不了，更别提片段。
    final keep = (event.isSnore || event.isSignal) && config.keepsEvent(event);

    if (!keep || optedOut) {
      await writer.release();
      if (optedOut) _clipsSkipped++;
      return;
    }

    final path = await writer.finish();
    if (path != null) {
      _accumulator.attachClip(index, path);
      _clipsSaved++;
    } else {
      _clipsSkipped++;
    }
  }

  /// 跟着当前事件，把音频写到盘上。
  ///
  /// ## 为什么不是"定案时再切一段"
  ///
  /// 因为切不出来。事件可以有几分钟长（连续鼾声三五分钟很常见），而环形缓冲
  /// 只有 60 秒——老实现就是在这儿丢音频的：一条 183 秒的鼾声，等它定案时
  /// 开头早被覆盖，只能从末尾截 20 秒充数。用户点开一听："怎么只有几秒。"
  ///
  /// 现在改成：事件一开张就开文件，之后逐窗追加，定案时只决定留下还是删掉。
  /// 内存里始终只有一个窗口，盘上留下的是**整段**鼾声。
  Future<void> _followEventAudio(AudioWindow window) async {
    if (!recordClips) {
      // 隐私开关是实时的：用户中途关掉，正在录的那段也立刻停止落盘
      final writer = _writer;
      if (writer != null) {
        _writer = null;
        _writerSamples = 0;
        await writer.release();
      }
      return;
    }

    final open = _accumulator.openEvent;
    // 没有开着的事件，或者这一段已经放弃（见下面的 _audioOptOut）
    if (open == null || _audioOptOut) return;

    final store = _clipStore;
    if (store == null) return;

    // ---- 新的一段：开文件，并把"头"从环形缓冲里补回来 ----
    if (_writer == null) {
      final headStart = config.clipStartFor(open.startSeconds);

      final writer = await store.begin(
        sessionStartedAt: _startedAt ?? DateTime.now(),
        startSeconds: headStart,
        sampleRate: config.sampleRate,
      );
      if (writer == null) {
        _audioOptOut = true;
        return;
      }

      // 头 = 事件开头前那一点余量 + **到当前窗口为止**已经流过去的那几秒。
      //
      // ⚠️ 终点必须是这一窗的结束，不能拿缓冲的最新位置：一次 feed 可能
      // 塞进来很多个窗口，拿最新位置当终点会把后面还没处理的窗口也写进头里，
      // 紧接着逐窗追加又写一遍——音频凭空翻倍。
      //
      // 捞不到就**整段放弃**：宁可不要，也不要一段从声音中间开始的音频，
      // 那听起来就像"这段声音本来就这么短"，比没有更误导。
      final headEnd =
          ((window.startSeconds + window.durationSeconds) * config.sampleRate)
              .round();
      final head = _ring.slice(
        (headStart * config.sampleRate).round(),
        headEnd,
      );
      if (head == null) {
        await writer.release();
        _audioOptOut = true;
        return;
      }

      _writer = writer;
      await writer.append(head);
      _writerSamples += head.length;
      return; // 头里已经含当前窗口，不能再补一次
    }

    // ---- 已经开着：接着写这一窗 ----
    final capSamples = config.maxEventClipSeconds * config.sampleRate;
    if (_writerSamples >= capSamples) {
      // 触顶（正常不该发生，见 maxEventClipSeconds）。停止续写但保留已写的——
      // 播放面板显示的是音频自己的长度，事件更长时还会说明，所以截断看得见。
      return;
    }

    await _writer!.append(window.samples);
    _writerSamples += window.samples.length;
  }

  Future<void> _processWindow(AudioWindow window) async {
    // 先量电平，界面要用；顺便判断要不要送进模型
    final rms = EnergyVad.rms(window.samples);
    _lastRms = rms;
    if (rms > _peakRms) _peakRms = rms;

    // 噪声底要在**判定之前**更新，而且**每个窗口都要喂**——
    // 只喂被跳过的会让估计偏低，只喂通过的会让它越推越高，
    // 两种都会让自适应变成自我实现的预言。
    _noiseFloor?.add(rms);

    // 能量门控。跳过安静段，省掉一次推理。
    //
    // 默认**关着**（AnalysisConfig.vadEnabled = false）：实测它没在挡误报——
    // 挡误报的是模型自己（关掉之后雨声/公鸡/白噪声照样 0 个鼾声段）。
    // 它换来的只有算力，而那个账还没在真机上量过。
    final threshold = vadThreshold;
    if (threshold != null && rms < threshold) {
      _accumulator.add(WindowObservation(
        startSeconds: window.startSeconds,
        durationSeconds: window.durationSeconds,
        label: null,
        confidence: 1.0,
        snoreProbability: 0.0,
        categories: const {},
        wasInferred: false,
      ));
      // 静音窗口不建事件，但它**仍然属于**正在进行的那一段——
      // 事件是隔着 mergeGap 之内的小停顿合并出来的，那段停顿也是它的音频。
      await _followEventAudio(window);
      return;
    }

    try {
      final prediction = await _analyzer.classifySamples(window.samples);
      _inferredCount++;
      final confidence = prediction.confidence;

      // 不再按置信度丢弃窗口。
      //
      // 这里原本有一道「置信度门控」，注释写着「没有它底噪会被强行归类」。
      // 实测下来它没有在做这件事：
      //
      //   · 雨声 / 公鸡叫 / 真实鼾声 / 白噪声四份素材上，它拦截的窗口数是 **0**
      //   · 真实房间底噪上也是 0 —— 底噪被稳定地认成「环境噪音 0.359」，
      //     而这个归类本来就是对的（房间底噪就是环境噪音）
      //
      // 它最初的依据是 PLAN.md 里「39 个假事件 → 0 个」那个实验，而那个实验的
      // 底噪是**合成白噪声**（standard_normal × 0.002）——合成白噪声和真实房间
      // 底噪的行为完全不同，那批假事件是合成信号的产物，不是真实场景。
      //
      // 改成：过了能量门控就产生事件，取 argmax。
      //
      // 把握程度照旧记进事件里，由界面展示出来，而不是在这里用一条门槛
      // 替用户丢掉——「没把握」和「确定」在报告上应当长得不一样，
      // 但两者都不该被藏起来。
      //
      // ⚠️ 唯一的例外是「静音」：它在这套类别里被明确定义为
      // **背景状态而不是声音事件**（见 SleepCategory.isRecessive），
      // 所以不给它建事件。这不是置信度门槛，是语义规则——
      // 去掉置信度门控这件事不影响它。
      final dominant = prediction.dominant;
      final label =
          dominant == SleepCategory.silence ? null : dominant;

      _accumulator.add(WindowObservation(
        startSeconds: window.startSeconds,
        durationSeconds: window.durationSeconds,
        label: label,
        confidence: confidence,
        snoreProbability: prediction.snoreProbability,
        categories: prediction.probabilities,
        wasInferred: true,
        rms: rms,
        // 原始标签只留在统计里，不参与建事件——大类才是事件的身份，
        // 换掉它会让同一段声音在时间线上换颜色。
        rawLabel:
            prediction.topLabels.isEmpty ? null : prediction.topLabels.first.label,
      ));
    } catch (_) {
      // 单窗口推理失败不断掉整夜录音，记数继续。
      _inferenceErrors++;
    }

    // 放在 try 外面：推理失败的那一窗，音频照样得写进去——
    // 少了它，片段中间会凭空缺 3 秒（听起来像卡了一下）。
    await _followEventAudio(window);
  }

  /// 结束录音：处理尾部残料，给出最终结果。
  /// 结束录音：处理尾部残料，等片段写完，给出最终结果。
  Future<AnalysisOutcome> finish() async {
    final tail = _buffer.flush();
    if (tail != null) {
      await _processWindow(tail);
    }

    // 先 build 一次让最后一个事件定案——它可能又排队一个片段写入。
    _accumulator.build();

    // 等所有片段落盘。不等的话会话落库时事件还没有 clipPath，
    // 历史记录里就永远放不出声音了。
    while (_pendingClips.isNotEmpty) {
      final batch = List<Future<void>>.of(_pendingClips);
      _pendingClips.clear();
      await Future.wait(batch);
    }

    // 路径已回填，重新取一份带 clipPath 的结果。
    return _accumulator.build();
  }

  void reset() {
    // 还开着的话先扔掉——正常路径上 finish() 已经收过尾了，
    // 这条是防呆：留着会是一个永远不落定、也不删的 .part 文件。
    unawaited(_writer?.release());
    _writer = null;
    _audioOptOut = false;
    _writerSamples = 0;

    _buffer.reset();
    _ring.clear();
    _accumulator.reset();
    _noiseFloor?.reset();
    _pendingClips.clear();
    _inferenceErrors = 0;
    _inferredCount = 0;
    _lastRms = 0;
    _peakRms = 0;
    _clipsSaved = 0;
    _clipsSkipped = 0;
    _startedAt = null;
  }

  /// 生成一个未落库的会话对象。
  RecordingSession toSession(DateTime startedAt, DateTime endedAt,
      AnalysisOutcome outcome) =>
      RecordingSession(
        id: null,
        startedAt: startedAt,
        endedAt: endedAt,
        events: outcome.events,
        stats: outcome.stats,
      );
}
