import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/l10n/domain_text.dart';
import '../../../core/l10n/l10n_context.dart';

import '../../../core/theme.dart';
import '../../../core/widgets/section_card.dart';
import '../view_models/recording_view_model.dart';

/// 测试锚点。和 `ReportKeys` / `HomeKeys` 一个规矩：**定位用 key，文案用 text**。
abstract final class RecordingKeys {
  /// 那颗月亮——开始 / 结束录音的大按钮。
  ///
  /// 存在的理由很具体：按钮原来是 `Icons.mic` / `Icons.stop` 两个图标，
  /// 测试按图标定位。换成自绘的月亮之后**那套 finder 全断了**——
  /// 而这只是换了个长相，不该让测试跟着改。按 key 找就不会。
  static const ValueKey<String> heroButton = ValueKey('recording-hero-button');
}

/// 录音页。
///
/// 处于底部导航内（[embedded] 为 true）时不自带 Scaffold 与 AppBar，
/// 由外壳提供，否则会出现双层标题栏。
class RecordingView extends StatelessWidget {
  const RecordingView({
    super.key,
    required this.viewModel,
    this.embedded = false,
  });

  final RecordingViewModel viewModel;
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) {
        final body = ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _HeroButton(viewModel: viewModel),
            if (viewModel.state.error != null) ...[
              const SizedBox(height: 16),
              _ErrorBanner(message: viewModel.state.error!.message(context)),
            ],
            if (viewModel.state.warning != null) ...[
              const SizedBox(height: 16),
              _WarningBanner(message: viewModel.state.warning!.message(context)),
            ],
            if (viewModel.state.isRecording) ...[
              const SizedBox(height: 16),
              _LiveStatsCard(viewModel: viewModel),
            ],
            const SizedBox(height: 16),
            const _HowItWorksCard(),
          ],
        );

        if (embedded) {
          return Scaffold(
            appBar: AppBar(title: Text(context.l10n.recordingTitle)),
            body: body,
          );
        }
        return Scaffold(
          appBar: AppBar(title: Text(context.l10n.recordingTitle)),
          body: body,
        );
      },
    );
  }
}

/// 中间的大圆按钮。整夜录音只有一个主动作，就该做得足够大、足够明确。
/// 开始 / 结束录音的大按钮。
///
/// ## 为什么是一轮月亮
///
/// 这是整个 App 的意象（图标就是弯月 + 声波），而「睡前点一下开始」
/// 这个动作本来就该有个跟睡眠有关的形状，而不是一个通用的麦克风。
///
/// 它是一只**犯困的月亮**：待机时闭着眼、缓慢呼吸；一按下去就睁眼，
/// 旁边开始飘 Z——那意思是"它在听着你睡"，比一个红点更贴切。
///
/// ## 动效为什么不停
///
/// 两态都在动，只是节奏不同（待机 3.6 秒一个呼吸周期，录音时 Z 飘得更快）。
/// **停下来的动画会让人以为卡住了**——尤其是这个按钮，用户按下去之后
/// 要盯着它确认"到底开始录了没有"。
class _HeroButton extends StatefulWidget {
  const _HeroButton({required this.viewModel});

  final RecordingViewModel viewModel;

  @override
  State<_HeroButton> createState() => _HeroButtonState();
}

class _HeroButtonState extends State<_HeroButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop;

  @override
  void initState() {
    super.initState();
    _loop = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3600),
    )..repeat();
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final viewModel = widget.viewModel;
    final state = viewModel.state;
    final recording = state.isRecording;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        child: Column(
          children: [
            GestureDetector(
              key: RecordingKeys.heroButton,
              onTap: viewModel.busy ? null : viewModel.toggle,
              child: SizedBox(
                width: 176,
                height: 176,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedBuilder(
                      animation: _loop,
                      builder: (context, _) => CustomPaint(
                        size: const Size(176, 176),
                        painter: _MoonButtonPainter(
                          t: _loop.value,
                          recording: recording,
                        ),
                      ),
                    ),
                    if (viewModel.busy)
                      const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: Colors.white,
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              recording ? context.l10n.recordingActive : context.l10n.recordingIdle,
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            if (recording)
              Text(
                formatDuration(state.elapsed),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              )
            else
              Text(
                context.l10n.recordingSubtitle,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textDim),
              ),
            if (recording) ...[
              const SizedBox(height: 10),
              Text(
                state.snoreEventCount > 0
                    ? context.l10n.recordingEventCountWithSnore(
                        state.eventCount, state.snoreEventCount)
                    : context.l10n.recordingEventCount(state.eventCount),
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textDim),
              ),
              const SizedBox(height: 4),
              Text(
                context.l10n.recordingTapAgain,
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: AppColors.textDim),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 输入电平条。
///
/// 除了当前电平和峰值，**还把能量门控的阈值画成一条线**——
/// 电平条不到那条线，就说明这段声音不会被识别。
/// 整夜录音最怕的就是手机被挡住、录了一晚静音而自己不知道。
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level, required this.peak, this.threshold});

  final double level;
  final double peak;
  /// 识别门槛。**为 null 表示能量门控关着**，这时不存在门槛这回事，
  /// 不画线也不给「有声音/太安静」的判断——没有参照物。
  final double? threshold;

  /// 用对数刻度。声音的 RMS 跨好几个数量级，线性刻度下阈值会挤在最左边看不见。
  static const double _floor = 0.0001;
  static const double _ceil = 0.3;

  double _pos(double rms) {
    if (rms <= _floor) return 0;
    if (rms >= _ceil) return 1;
    return ((math.log(rms) - math.log(_floor)) /
            (math.log(_ceil) - math.log(_floor)))
        .clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final levelPos = _pos(level);
    final peakPos = _pos(peak);
    final t = threshold;
    final thresholdPos = t == null ? null : _pos(t);
    final above = t == null ? null : level >= t;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(context.l10n.recordingInputLevel, style: theme.textTheme.bodySmall),
            if (above != null)
              Text(
                above ? context.l10n.recordingLoud : context.l10n.recordingQuiet,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: above ? AppColors.statusGood : AppColors.textDim,
                ),
              ),
          ],
        ),
        const SizedBox(height: 6),
        LayoutBuilder(
          builder: (context, c) {
            final w = c.maxWidth;
            return SizedBox(
              height: 22,
              child: Stack(
                children: [
                  // 轨道
                  Positioned(
                    top: 7,
                    left: 0,
                    right: 0,
                    child: Container(
                      height: 8,
                      decoration: BoxDecoration(
                        color: AppColors.surfaceHigh,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  // 当前电平
                  Positioned(
                    top: 7,
                    left: 0,
                    child: Container(
                      height: 8,
                      width: w * levelPos,
                      decoration: BoxDecoration(
                        color: above == null
                            // 没有门槛就没有"过没过"这回事，用中性色——
                            // 拿绿色会暗示"这条被识别了"，那是假的
                            ? AppColors.accent
                            : above
                                ? AppColors.statusGood
                                : AppColors.textDim.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                  // 峰值
                  if (peakPos > 0.01)
                    Positioned(
                      top: 4,
                      left: (w * peakPos - 1).clamp(0.0, w - 2),
                      child: Container(
                        width: 2,
                        height: 14,
                        color: AppColors.accent,
                      ),
                    ),
                  // 阈值线——不到这里就不会被识别。
                  // 能量门控关着的时候没有门槛，这条线不该出现。
                  if (thresholdPos != null)
                    Positioned(
                      top: 0,
                      left: (w * thresholdPos - 1).clamp(0.0, w - 2),
                      child: Column(
                        children: [
                          Container(
                              width: 2,
                              height: 22,
                              color: AppColors.statusCritical
                                  .withValues(alpha: 0.85)),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        Text(
          t == null
              // 门控关着的时候电平条只剩一个作用：看麦克风有没有在工作
              ? context.l10n.recordingLevelNoGate(
                  level.toStringAsFixed(4), peak.toStringAsFixed(4))
              : context.l10n.recordingLevelGated(t.toStringAsFixed(4),
                  level.toStringAsFixed(4), peak.toStringAsFixed(4)),
          style: theme.textTheme.labelSmall
              ?.copyWith(color: AppColors.textDim, height: 1.5),
        ),
      ],
    );
  }
}

/// 录音中的实时统计。
class _LiveStatsCard extends StatelessWidget {
  const _LiveStatsCard({required this.viewModel});

  final RecordingViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = viewModel.state;
    final skipped = s.windowsProcessed - s.windowsInferred;

    return SectionCard(
      title: context.l10n.recordingLiveTitle,
      subtitle: context.l10n.recordingLiveSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LevelMeter(
            level: s.inputLevel,
            peak: s.peakLevel,
            // 用**当前生效的**阈值，不是配置里的固定值——阈值会随房间
            // 噪声底浮动，画错了这条线就是在骗用户
            threshold: s.vadThreshold,
          ),
          const SizedBox(height: 18),
          MetricRow(
            children: [
              MetricTile(
                  value: '${s.windowsProcessed}',
                  label: context.l10n.recordingWindowsProcessed),
              MetricTile(
                value: '${s.windowsInferred}',
                label: context.l10n.recordingWindowsInferred,
                hint: '${(s.inferenceRatio * 100).toStringAsFixed(0)}%',
                valueColor: AppColors.accent,
              ),
              MetricTile(
                value: '$skipped',
                label: context.l10n.recordingWindowsSkipped,
                valueColor: AppColors.statusGood,
              ),
            ],
          ),
          if (s.inferenceErrors > 0) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.warning_amber,
                    size: 16, color: AppColors.statusCritical),
                const SizedBox(width: 6),
                Text(context.l10n.recordingInferenceErrors(s.inferenceErrors),
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.statusCritical)),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            const Icon(Icons.warning_amber, color: AppColors.statusCritical),
            const SizedBox(width: 12),
            Expanded(
              child: Text(message, style: theme.textTheme.bodySmall),
            ),
          ],
        ),
      ),
    );
  }
}

/// 非致命的提醒：录音在正常跑，但有件事用户该知道。
///
/// 和 [_ErrorBanner] 用同一套版式、不同的颜色和图标——用户扫一眼就能
/// 分辨「出事了」和「有事要提醒你」，不必读完文字。
class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.notifications_off_outlined,
                color: AppColors.statusWarning),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HowItWorksCard extends StatelessWidget {
  const _HowItWorksCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: context.l10n.recordingUsageTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in [
            context.l10n.recordingUsage1,
            context.l10n.recordingUsage2,
            context.l10n.recordingUsage3,
            context.l10n.recordingUsage4,
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 6, right: 8),
                    child: Icon(Icons.circle, size: 5,
                        color: AppColors.textDim),
                  ),
                  Expanded(
                    child: Text(line,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(height: 1.6)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 画那颗月亮。用 painter 而不是图标字体：弯月是两块圆相减，
/// 图标库里没有这个形状，而且自绘不依赖任何字体。
class _MoonButtonPainter extends CustomPainter {
  _MoonButtonPainter({required this.t, required this.recording});

  /// 0..1 的循环进度。
  final double t;

  final bool recording;

  /// 录音中用暖橙而不是红：红读起来是"出事了"，这里是"它在工作"。
  Color get _tint =>
      recording ? AppColors.statusSerious : AppColors.accent;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    // 待机时的呼吸：幅度刻意很小（3.5%）。这是"它还活着"，
    // 不是"它想让你点"——催人的动效在睡前是最不合适的。
    final breathe =
        recording ? 1.0 : 1 + 0.035 * math.sin(t * 2 * math.pi);

    // 环 + 光晕。录音时光晕稳定亮着（"在工作"），待机时跟着呼吸明暗。
    final ringR = size.width * 0.5 - 3;
    canvas.drawCircle(
      center,
      ringR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = _tint.withValues(alpha: 0.35),
    );
    final haloAlpha = recording
        ? 0.16
        : 0.05 + 0.07 * (0.5 + 0.5 * math.sin(t * 2 * math.pi));
    canvas.drawCircle(
      center,
      ringR - 4,
      Paint()
        ..color = _tint.withValues(alpha: haloAlpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );

    // 底圆
    canvas.drawCircle(
      center,
      size.width * 0.385 * breathe,
      Paint()..color = _tint,
    );

    // 弯月：大圆挖掉一个偏移的小圆。和生成 App 图标那套几何同一个思路，
    // 所以桌面图标和这个按钮是同一个形状。
    final r = size.width * 0.195 * breathe;
    final moonCenter = center + Offset(-2, -4);
    final moon = Path.combine(
      PathOperation.difference,
      Path()..addOval(Rect.fromCircle(center: moonCenter, radius: r)),
      Path()
        ..addOval(Rect.fromCircle(
            center: moonCenter + Offset(r * 0.62, -r * 0.16),
            radius: r * 0.88)),
    );
    canvas.drawPath(moon, Paint()..color = Colors.white);

    // 脸画在月亮的厚的那一侧
    final face = moonCenter + Offset(-r * 0.40, 0);
    final stroke = Paint()
      ..color = _tint
      ..style = PaintingStyle.stroke
      ..strokeWidth = r * 0.15
      ..strokeCap = StrokeCap.round;

    for (final dx in [-r * 0.28, r * 0.28]) {
      final eye = face + Offset(dx, -r * 0.08);
      if (recording) {
        // 睁眼：两个点，表示"醒着在听"
        canvas.drawCircle(eye, r * 0.11, Paint()..color = _tint);
      } else {
        // 闭眼：下半圆，像「︶」。睡觉的脸就是这么画的。
        canvas.drawArc(
          Rect.fromCircle(center: eye + Offset(0, -r * 0.12), radius: r * 0.22),
          0,
          math.pi,
          false,
          stroke,
        );
      }
    }
    // 嘴：一条小小的弧，跟着眼睛一起笑
    canvas.drawArc(
      Rect.fromCircle(center: face + Offset(0, r * 0.32), radius: r * 0.20),
      0,
      math.pi,
      false,
      stroke,
    );

    if (!recording) return;

    // 录音时飘 Z：三颗错开相位，边升边淡。
    // 两头淡、中间最深（sin 包络）——不然会像凭空出现又凭空消失。
    for (var i = 0; i < 3; i++) {
      final phase = (t + i / 3) % 1.0;
      final fade = math.sin(phase * math.pi) * 0.9;
      final zSize = r * (0.44 + 0.30 * phase);
      final zCenter = center +
          Offset(r * 1.35 + phase * r * 0.55, -r * (0.75 + phase * 2.0));
      canvas.drawPath(
        _zPath(zCenter, zSize),
        Paint()
          ..color = Colors.white.withValues(alpha: fade)
          ..style = PaintingStyle.stroke
          ..strokeWidth = zSize * 0.22
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  /// 一个 Z：三笔。手画而不是排文字——不依赖字体，也省得管行高。
  Path _zPath(Offset c, double s) {
    final h = s / 2;
    return Path()
      ..moveTo(c.dx - h, c.dy - h)
      ..lineTo(c.dx + h, c.dy - h)
      ..lineTo(c.dx - h, c.dy + h)
      ..lineTo(c.dx + h, c.dy + h);
  }

  @override
  bool shouldRepaint(_MoonButtonPainter old) =>
      old.t != t || old.recording != recording;
}
