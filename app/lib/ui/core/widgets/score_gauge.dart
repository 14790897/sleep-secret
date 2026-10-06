import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme.dart';

/// 环形仪表盘：一个圆环 + 中间的大数字。
///
/// 蜗牛睡眠用这个展示睡眠得分。我们展示的是**鼾声指数**——
/// 只用真实算得出来的指标，不编造综合评分。
class ScoreGauge extends StatelessWidget {
  const ScoreGauge({
    super.key,
    required this.value,
    required this.label,
    this.formattedValue,
    this.unit,
    this.subLabel,
    this.size = 148,
    this.maxValue = 100,
    this.higherIsBetter = false,
  });

  /// 当前值，范围 0..[maxValue]。
  final double value;

  /// 圆环下方的说明（如「鼾声指数」）。
  final String label;

  /// 中间显示的文本；为 null 时显示四舍五入后的 [value]。
  final String? formattedValue;

  /// 单位，以小字号跟在数字后面（如 `%`）。
  final String? unit;

  /// 数字下方、标签之上的一行小字（如档位）。
  final String? subLabel;

  final double size;
  final double maxValue;

  /// 数值越高越好还是越差。
  ///
  /// 鼾声指数越高越差，睡眠评分越高越好——同一个仪表盘要能表达两个方向，
  /// 否则颜色的含义就反了。
  final bool higherIsBetter;

  Color get _ringColor {
    final ratio = (value / maxValue).clamp(0.0, 1.0);
    final good = higherIsBetter ? ratio : 1 - ratio;
    if (good >= 0.85) return AppColors.statusGood;
    if (good >= 0.70) return const Color(0xFFB8D94A);
    if (good >= 0.45) return AppColors.statusWarning;
    return AppColors.statusCritical;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ratio = (value / maxValue).clamp(0.0, 1.0);

    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _GaugePainter(progress: ratio, color: _ringColor),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    formattedValue ?? value.round().toString(),
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: _ringColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  if (unit != null)
                    Text(
                      unit!,
                      style: theme.textTheme.titleMedium?.copyWith(
                        color: _ringColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
              Text(label,
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: AppColors.textDim)),
              if (subLabel != null)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Text(subLabel!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: _ringColor,
                        fontWeight: FontWeight.w600,
                      )),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.progress, required this.color});

  final double progress;
  final Color color;

  /// 从正上方开始、顺时针留一个缺口，比整圆更像仪表。
  static const double _startAngle = -math.pi / 2;
  static const double _sweep = math.pi * 1.75;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 10.0;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (size.shortestSide - stroke) / 2,
    );

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..color = AppColors.surfaceHigh;
    canvas.drawArc(rect, _startAngle, _sweep, false, track);

    if (progress <= 0) return;

    final bar = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        startAngle: _startAngle,
        endAngle: _startAngle + _sweep,
        colors: [color.withValues(alpha: 0.55), color],
        transform: GradientRotation(_startAngle),
      ).createShader(rect);

    canvas.drawArc(rect, _startAngle, _sweep * progress, false, bar);
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.progress != progress || old.color != color;
}

/// 把秒数格式化成 `Xh Ym` 或 `Ym`，用于报告里的时长展示。
String formatSpan(double seconds) {
  final total = seconds.round();
  final h = total ~/ 3600;
  final m = (total % 3600) ~/ 60;
  if (h > 0) return '${h}h ${m}m';
  return '${m}m';
}
