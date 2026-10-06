import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../../domain/analysis/analysis_config.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/section_card.dart';
import '../view_models/recording_view_model.dart';

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
              _ErrorBanner(message: viewModel.state.error!),
            ],
            if (viewModel.state.warning != null) ...[
              const SizedBox(height: 16),
              _WarningBanner(message: viewModel.state.warning!),
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
            appBar: AppBar(title: const Text('睡眠录音')),
            body: body,
          );
        }
        return Scaffold(
          appBar: AppBar(title: const Text('睡眠录音')),
          body: body,
        );
      },
    );
  }
}

/// 中间的大圆按钮。整夜录音只有一个主动作，就该做得足够大、足够明确。
class _HeroButton extends StatelessWidget {
  const _HeroButton({required this.viewModel});

  final RecordingViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = viewModel.state;
    final recording = state.isRecording;

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        child: Column(
          children: [
            GestureDetector(
              onTap: viewModel.busy ? null : viewModel.toggle,
              child: SizedBox(
                width: 152,
                height: 152,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // 录音时外圈缓慢转动，给一个"在跑"的低干扰反馈
                    if (recording)
                      const _RotatingRing()
                    else
                      Container(
                        width: 148,
                        height: 148,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: AppColors.accent.withValues(alpha: 0.35),
                            width: 2,
                          ),
                        ),
                      ),
                    Container(
                      width: 116,
                      height: 116,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: recording
                            ? AppColors.statusCritical
                            : AppColors.accent,
                      ),
                      child: viewModel.busy
                          ? const Center(
                              child: SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.white,
                                ),
                              ),
                            )
                          : Icon(
                              recording ? Icons.stop : Icons.mic,
                              size: 48,
                              color: Colors.white,
                            ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              recording ? '录音中' : '点一下开始',
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
                '整夜录音、本地分析，早上给出报告',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textDim),
              ),
            if (recording) ...[
              const SizedBox(height: 10),
              Text(
                '已检出 ${state.eventCount} 个声音事件'
                '${state.snoreEventCount > 0 ? '，其中鼾声 ${state.snoreEventCount} 段' : ''}',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: AppColors.textDim),
              ),
              const SizedBox(height: 4),
              Text(
                '再次点击结束并保存',
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

/// 录音时外圈的转动弧线。用动画而不是静态圆环，
/// 是为了在息屏前那一眼就能确认"它还在跑"。
class _RotatingRing extends StatefulWidget {
  const _RotatingRing();

  @override
  State<_RotatingRing> createState() => _RotatingRingState();
}

class _RotatingRingState extends State<_RotatingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _controller,
      child: CustomPaint(
        size: const Size(148, 148),
        painter: _ArcRingPainter(),
      ),
    );
  }
}

class _ArcRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: size.shortestSide / 2 - 1,
    );
    canvas.drawArc(
      rect,
      -1.5707963,
      2.0,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..color = AppColors.statusCritical.withValues(alpha: 0.85),
    );
  }

  @override
  bool shouldRepaint(_ArcRingPainter old) => false;
}


/// 输入电平条。
///
/// 除了当前电平和峰值，**还把能量门控的阈值画成一条线**——
/// 电平条不到那条线，就说明这段声音不会被识别。
/// 整夜录音最怕的就是手机被挡住、录了一晚静音而自己不知道。
class _LevelMeter extends StatelessWidget {
  const _LevelMeter({required this.level, required this.peak, required this.threshold});

  final double level;
  final double peak;
  final double threshold;

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
    final thresholdPos = _pos(threshold);
    final above = level >= threshold;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('输入电平', style: theme.textTheme.bodySmall),
            Text(
              above ? '有声音' : '太安静',
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
                        color: above
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
                  // 阈值线——不到这里就不会被识别
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
          '红线是识别门槛，电平要越过去才会被分析。'
          '当前 ${level.toStringAsFixed(4)}，峰值 ${peak.toStringAsFixed(4)}',
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
      title: '实时分析',
      subtitle: '安静片段会被直接跳过，不送进模型',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LevelMeter(
            level: s.inputLevel,
            peak: s.peakLevel,
            threshold: AnalysisConfig().vadRms,
          ),
          const SizedBox(height: 18),
          MetricRow(
            children: [
              MetricTile(value: '${s.windowsProcessed}', label: '处理窗口'),
              MetricTile(
                value: '${s.windowsInferred}',
                label: '送进模型',
                hint: '${(s.inferenceRatio * 100).toStringAsFixed(0)}%',
                valueColor: AppColors.accent,
              ),
              MetricTile(
                value: '$skipped',
                label: '跳过',
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
                Text('${s.inferenceErrors} 个窗口推理失败',
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
      title: '使用说明',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in const [
            '睡前点上面的大按钮开始录音，屏幕可以关掉。',
            '录音期间会有一条常驻通知，说明应用正在工作。',
            '早上起来再点一次结束，报告会自动生成。',
            '整夜只保留事件时间点，不保存原始音频。',
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
