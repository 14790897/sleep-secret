import 'dart:math' as math;
import 'dart:typed_data';

import '../models/recording_session.dart';
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
///         -> [EnergyVad] 能量门控（不过就跳过，省掉一次推理）
///         -> [SleepAnalyzer] 端侧推理
///         -> 置信度门控（不够就判未识别）
///         -> [EventAccumulator] 合并成事件 + 累计统计
///
/// 两道闸门缺一不可：只有能量门控会漏掉底噪被强行归类的问题；
/// 只有置信度门控则会把大量算力浪费在安静段上。
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
        recordClips = config.recordClips {
    if (config.recordClips && !config.clipBufferIsAdequate) {
      throw ArgumentError(
        'clipBufferSeconds(${config.clipBufferSeconds}) 不足以容纳 '
        'maxClipSeconds(${config.maxClipSeconds}) + 前后余量，'
        '切片段时会发现音频已被覆盖',
      );
    }
    // 回调要在构造体里接——它引用了引擎自身，初始化列表里拿不到 this。
    _accumulator.onEventClosed = _onEventClosed;
  }

  final SleepAnalyzer _analyzer;
  final AnalysisConfig config;
  final AudioClipStore? _clipStore;

  /// 噪声底估计器。`config.vadAdaptive` 关掉时为 null，退回固定阈值。
  final AdaptiveNoiseFloor? _noiseFloor;

  final PcmWindowBuffer _buffer;

  /// 当前生效的能量门控阈值。
  ///
  /// 界面上的电平条要画在**这个**位置，不能画在配置里的固定值上——
  /// 阈值自适应之后两者会不一样，画错了就是在骗用户。
  double get vadThreshold => _noiseFloor?.threshold ?? config.vadRms;

  /// 估计出来的噪声底。样本不足时为 null。
  double? get noiseFloor => _noiseFloor?.floor;

  /// 最近的原始音频。事件是回溯确认的，等定案时那段声音早就流过去了，
  /// 所以必须留一份缓冲回头切。
  final PcmRingBuffer _ring;

  final EventAccumulator _accumulator;

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
  /// 这里按 [AnalysisConfig.minEventSeconds] 过滤过，和收尾时落库的口径一致。
  /// 不过滤的话，录音界面会显示"已检出 N 个事件"，而报告里是 0——
  /// 用户看到中途出现的数字最后消失，会认为应用不可靠。
  List<SoundEvent> get events => _accumulator.eventsSoFar
      .where((e) => e.durationSeconds >= config.minEventSeconds)
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
    // 原始流进环形缓冲。窗口是从同一份流里切出来的，两者用同一套
    // 绝对采样序号，所以事件时间戳能直接换算成缓冲里的切片范围。
    _ring.write(samples);

    final windows = _buffer.add(samples);
    for (final window in windows) {
      await _processWindow(window);
    }
    return _accumulator.eventsSoFar;
  }

  /// 事件定案：符合条件的去环形缓冲切一段音频存下来。
  void _onEventClosed(int index, SoundEvent event) {
    if (!recordClips) return;
    _pendingClips.add(_saveClipFor(index, event));
  }

  Future<void> _saveClipFor(int index, SoundEvent event) async {
    final store = _clipStore;
    if (store == null) return;
    if (!recordClips) return;

    // 只留鼾声，且只留够长、会被保留成事件的段。
    // 梦话和咳嗽也录的话，隐私含义不一样，先不做。
    if (!event.isSnore) return;
    if (event.durationSeconds < config.minEventSeconds) return;

    final range = config.clipRangeFor(event.startSeconds, event.endSeconds);
    final startSample = (range.start * config.sampleRate).round();
    // 末尾余量夹到已录到的位置。
    //
    // 事件往往在最后一段音频结束时定案，此时"事件之后"的声音还没发生，
    // 尾部余量自然取不到。缺后半截余量只是少听半秒，可以接受；
    // 而缺开头会让片段从声音正中开始，那是误导，所以起点不做夹取，
    // 取不到就整段放弃（slice 会返回 null）。
    final endSample = math.min(
      (range.end * config.sampleRate).round(),
      _ring.newestSample,
    );

    final samples = _ring.slice(startSample, endSample);
    if (samples == null) {
      // 缓冲不够长或事件太长，音频已被覆盖。宁可不存，也不存一段被截断的。
      _clipsSkipped++;
      return;
    }

    final path = await store.save(
      sessionStartedAt: _startedAt ?? DateTime.now(),
      startSeconds: range.start,
      samples: samples,
      sampleRate: config.sampleRate,
    );
    if (path != null) {
      _accumulator.attachClip(index, path);
      _clipsSaved++;
    } else {
      _clipsSkipped++;
    }
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

    // 闸门 1：能量。安静就直接跳过，这次推理省下了。
    if (rms < vadThreshold) {
      _accumulator.add(WindowObservation(
        startSeconds: window.startSeconds,
        durationSeconds: window.durationSeconds,
        label: null,
        confidence: 1.0,
        snoreProbability: 0.0,
        categories: const {},
        wasInferred: false,
      ));
      return;
    }

    try {
      final prediction = await _analyzer.classifySamples(window.samples);
      _inferredCount++;
      final confidence = prediction.confidence;

      // 闸门 2：置信度。太低就判未识别，不产生事件。
      // 合成/陌生音频下各类概率接近均匀，这一步能挡掉大量假事件。
      final label =
          confidence >= config.minConfidence ? prediction.dominant : null;

      _accumulator.add(WindowObservation(
        startSeconds: window.startSeconds,
        durationSeconds: window.durationSeconds,
        label: label,
        confidence: confidence,
        snoreProbability: prediction.snoreProbability,
        categories: prediction.probabilities,
        wasInferred: true,
      ));
    } catch (_) {
      // 单窗口推理失败不断掉整夜录音，记数继续。
      _inferenceErrors++;
    }
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
