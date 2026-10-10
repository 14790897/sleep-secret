import 'dart:math' as math;

/// 从最近若干窗口的 RMS 里估计噪声底，据此给出能量门控阈值。
///
/// ## 为什么固定值不行
///
/// 固定的 `vadRms` 假设了一个**特定的房间**。真机实测：安静房间的环境电平是
/// 0.0097，而阈值是 0.01 —— 几乎贴着。换个更安静的房间，这个阈值就完全不起作用；
/// 换个有空调的房间，它又会把轻声鼾声一起滤掉。同一个数字不可能对两种房间都对。
///
/// ## 自适应不等于"什么都自己决定"
///
/// 阈值只在 [lowerBound, upperBound] 之间浮动，这两条边界由原来的固定值推出来。
/// 口径是：**原来那个值可能不对，但不会错到 4 倍以上**——自适应只在这个范围内
/// 按实际房间挑一个。等有几晚真实录音之后，再决定要不要放开这个范围。
///
/// ## 为什么用分位数而不是均值
///
/// 打鼾本身会把均值拉高：一晚打鼾 30% 的话，均值已经偏离噪声底了。
/// 取低分位数（默认 20%）能落在"安静那部分"里，不受打鼾时长影响。
///
/// 但分位数也救不了极端情况：如果整晚 90% 的时间都在打鼾，低分位数也会落在
/// 鼾声里，阈值被抬高，反而更容易漏掉轻声鼾声。这是自适应的固有代价，
/// [upperBound] 就是给它兜底的。
class AdaptiveNoiseFloor {
  AdaptiveNoiseFloor({
    required this.historyWindows,
    required this.percentile,
    required this.minSamples,
    required this.multiplier,
    required this.lowerBound,
    required this.upperBound,
    required double fallbackThreshold,
  })  : assert(historyWindows > 0, 'historyWindows 必须为正'),
        assert(percentile > 0 && percentile < 1, '分位数必须在 (0,1) 开区间内'),
        assert(minSamples > 0, 'minSamples 必须为正'),
        assert(multiplier > 1, '倍数必须大于 1，否则等于没有门控'),
        assert(lowerBound <= upperBound, '下界不能高于上界'),
        _fallback = fallbackThreshold,
        _threshold = _clamp(fallbackThreshold, lowerBound, upperBound);

  /// 保留多少个窗口的 RMS 用来估计噪声底。
  ///
  /// 太短的话，一段长鼾声会把整个历史填满，噪声底被估成鼾声电平，
  /// 于是下一段鼾声反而被跳过——这是最坏的失效方式。
  /// 默认 400 个窗口（3 秒窗口约 20 分钟），两分钟的鼾声段只占 10%。
  final int historyWindows;

  /// 取哪个分位数当噪声底。
  final double percentile;

  /// 至少积累多少个窗口才开始自适应。不够时用 [fallbackThreshold]。
  final int minSamples;

  /// 噪声底乘多少倍才算"有声音"。
  ///
  /// 3 倍（约 10dB）是刻意保守的：鼾声通常在 50dB SPL 以上，安静卧室在
  /// 30–40dB，实际差距是 10–300 倍。取 3 倍是为了宁可多送几个窗口进模型，
  /// 也不要漏掉轻声鼾声——多推理几个窗口只费电，漏掉就打鼾也看不到。
  final double multiplier;

  /// 阈值能浮动到的区间。**不是 final**——用户在「关于」页调基准阈值时
  /// 整个区间要跟着挪，见 [retune]。
  double lowerBound;
  double upperBound;

  final List<double> _history = [];
  var _next = 0;
  var _count = 0;

  /// 样本不足时用的固定阈值，也是 [reset] 之后回到的值。
  double _fallback;

  double _threshold;

  /// 当前生效的阈值。样本不足时是 fallback（夹在上下界之间）。
  double get threshold => _threshold;

  /// 估计出来的噪声底。样本不足时为 null。
  double? get floor => _count < minSamples ? null : _percentile();

  /// 已经积累的样本数。
  int get sampleCount => _count;

  /// 记录一个窗口的电平。
  ///
  /// **每个窗口都要喂进来**，包括被门控跳过的那种——否则历史里只剩响的那部分，
  /// 噪声底会被严重高估，自适应就成了自我实现的预言。
  void add(double rms) {
    if (_history.length < historyWindows) {
      _history.add(rms);
      _count = _history.length;
    } else {
      _history[_next] = rms;
      _next = (_next + 1) % historyWindows;
    }
    _threshold = _compute();
  }

  void reset() {
    _history.clear();
    _next = 0;
    _count = 0;
    // 阈值也要还原——只清历史的话，下一次录音会带着上一次房间算出来的
    // 阈值开头，而那时一个样本都还没有。这个 bug 一开始就漏了：
    // reset 之后 threshold 停在上一次的 0.0025 而不是 fallback。
    _threshold = _clamp(_fallback, lowerBound, upperBound);
  }

  /// 换一个基准阈值，区间按同一套比例跟着走。
  ///
  /// 「关于」页那个滑块调的就是它。**立刻重算**：用户松手就该看到红线动，
  /// 而不是等下一次录音。
  ///
  /// ⚠️ 上下界跟着挪，但**不取消**：当初加它们是为了防止"越打鼾阈值越高、
  /// 越检测不到"那种失效（见 [AnalysisConfig] 里那段说明）。
  /// 调基准只是把整个区间平移，那条约束换个基准依然成立。
  void retune({
    required double base,
    required double lowerRatio,
    required double upperRatio,
  }) {
    if (base <= 0 || !base.isFinite) return;
    _fallback = base;
    lowerBound = base * lowerRatio;
    upperBound = base * upperRatio;

    // 样本不够时退回基准值；够了就按新房顶重新估一次
    _threshold = _clamp(_fallback, lowerBound, upperBound);
    if (_count >= minSamples) _threshold = _compute();
  }

  double _compute() {
    if (_count < minSamples) return _threshold;
    final estimate = _percentile() * multiplier;
    return _clamp(estimate, lowerBound, upperBound);
  }

  double _percentile() {
    final sorted = List<double>.of(_history)..sort();
    // 用 nearest-rank：索引取 floor(p * n)，n=1 时退化为第 0 个
    final idx = (percentile * sorted.length).floor().clamp(0, sorted.length - 1);
    return sorted[idx];
  }

  static double _clamp(double v, double lo, double hi) =>
      math.min(math.max(v, lo), hi);
}
