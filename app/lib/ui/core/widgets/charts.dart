import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../domain/analysis/session_insights.dart';
import '../l10n/domain_text.dart';
import '../l10n/l10n_context.dart';
import '../theme.dart';

/// 图表共用的尺寸与描边规范。
///
/// 数值来自 dataviz skill 的 mark 规范：细描边、数据端 4px 圆角、
/// 相邻填充之间留 2px 表面色间隙（不是描边——描边会把图变吵）。
class ChartMetrics {
  const ChartMetrics._();

  static const double gap = 2;
  static const double radius = 4;
  static const double gridStroke = 1;
  static const double lineStroke = 2;
  static const double markerSize = 9;

  /// 网格线用实线细线。虚线会被读成"阈值"或"预测"，
  /// 只在真的画阈值时才用。
  static Paint gridPaint() => Paint()
    ..color = AppColors.divider.withValues(alpha: 0.6)
    ..strokeWidth = gridStroke;

  static Paint axisPaint() => Paint()
    ..color = AppColors.divider
    ..strokeWidth = gridStroke;
}

TextPainter label(String text, Color color, {double size = 10, bool bold = false}) {
  final tp = TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        fontSize: size,
        color: color,
        fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
      ),
    ),
    textDirection: ui.TextDirection.ltr,
  )..layout();
  return tp;
}

/// 把秒数写成图轴上够短的标签。
String shortSpan(double seconds) {
  if (seconds >= 3600) return '${(seconds / 3600).toStringAsFixed(1)}h';
  if (seconds >= 60) return '${(seconds / 60).round()}m';
  return '${seconds.round()}s';
}

// ---------------------------------------------------------------- 每小时分布

/// 每小时声音分布。
///
/// 堆叠柱：鼾声在下、其他声音在上。这是"强调"式呈现而不是全分类配色——
/// 读者要回答的是"我几点打鼾最多"，其余声音只是背景信息，所以用中性灰。
class HourlyChart extends StatelessWidget {
  const HourlyChart({super.key, required this.buckets, this.height = 148});

  final List<HourBucket> buckets;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (buckets.isEmpty) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(context.l10n.hourlyEmpty,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textDim)),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _HourlyPainter(buckets: buckets),
      ),
    );
  }
}

class _HourlyPainter extends CustomPainter {
  _HourlyPainter({required this.buckets});

  final List<HourBucket> buckets;

  @override
  void paint(Canvas canvas, Size size) {
    const axisH = 20.0;
    const topPad = 14.0;
    final baseline = size.height - axisH;
    final plotH = baseline - topPad;

    final maxTotal = buckets
        .map((b) => b.totalSeconds)
        .fold<double>(0, (a, b) => a > b ? a : b);
    if (maxTotal <= 0) return;

    // 两条水平参考线，够用就好。
    final grid = ChartMetrics.gridPaint();
    for (final f in const [0.5, 1.0]) {
      final y = baseline - plotH * f;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
      final tp = label(shortSpan(maxTotal * f), AppColors.textDim);
      tp.paint(canvas, Offset(0, y - tp.height - 1));
    }

    final slot = size.width / buckets.length;
    final barW = math.max(slot * 0.56, 4.0);

    for (var i = 0; i < buckets.length; i++) {
      final b = buckets[i];
      final cx = slot * i + slot / 2;
      final left = cx - barW / 2;

      final snoreH = plotH * (b.snoreSeconds / maxTotal);
      final otherH = plotH * (b.otherSeconds / maxTotal);

      // 鼾声贴着基线画，其他声音摞在上面。
      // 鼾声是读者要比较的量——贴基线时它的高度在各小时之间可以直接对比；
      // 放在上面的话顶边同时受两段影响，反而看不出谁多谁少。
      if (snoreH > 0) {
        final h = math.max(snoreH, 1.0);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(left, baseline - h, barW, h),
            topLeft: const Radius.circular(ChartMetrics.radius),
            topRight: const Radius.circular(ChartMetrics.radius),
          ),
          Paint()..color = SoundClass.snore.color,
        );
      }

      // 其他声音摞在鼾声之上，中间留 2px 表面色间隙。
      // 间隙要算在**位置**上而不是高度上——减高度只会让柱子变矮，两段仍然贴在一起。
      if (otherH > 0) {
        final snoreTop = baseline - (snoreH > 0 ? snoreH : 0.0);
        final top = snoreTop - (snoreH > 0 ? ChartMetrics.gap : 0.0);
        final h = math.max(otherH, 1.0);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(left, top - h, barW, h),
            topLeft: Radius.circular(snoreH > 0 ? 0.0 : ChartMetrics.radius),
            topRight: Radius.circular(snoreH > 0 ? 0.0 : ChartMetrics.radius),
          ),
          Paint()..color = AppColors.textDim.withValues(alpha: 0.45),
        );
      }

      final tp = label('${b.hour}', AppColors.textDim);
      tp.paint(canvas, Offset(cx - tp.width / 2, baseline + 5));
    }

    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      ChartMetrics.axisPaint(),
    );
  }

  @override
  bool shouldRepaint(_HourlyPainter old) => old.buckets != buckets;
}

// ---------------------------------------------------------------- 趋势

/// 鼾声指数跨晚趋势。
///
/// 单序列折线，所以**不放图例**——标题已经说明了它是什么。
/// 只直接标注末点（读者最关心"最近怎么样"）和极值点。
class TrendChart extends StatelessWidget {
  const TrendChart({
    super.key,
    required this.points,
    this.height = 168,
    this.threshold,
    this.thresholdLabel,
  });

  final List<TrendPoint> points;
  final double height;

  /// 参考线数值。目前传的是使用者自己的平均值——不定义"医学阈值"，
  /// 那种阈值依赖个人基线和临床背景，凭空画一条会误导。
  final double? threshold;

  /// 参考线的文字说明，必须与它的实际含义一致。
  ///
  /// 为 null 时用默认的「参考」——那个词要按语言来，所以默认值不能在
  /// 参数上写死（参数默认值必须是编译期常量）。
  final String? thresholdLabel;

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            points.isEmpty
                ? context.l10n.chartTrendNoPoints
                : context.l10n.chartTrendNeedTwoNights,
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: AppColors.textDim),
          ),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _TrendPainter(
        points: points,
        threshold: threshold,
        thresholdLabel: thresholdLabel ?? context.l10n.chartThresholdLegend,
      ),
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter({
    required this.points,
    required this.threshold,
    required this.thresholdLabel,
  });

  final List<TrendPoint> points;
  final double? threshold;
  final String thresholdLabel;

  @override
  void paint(Canvas canvas, Size size) {
    const axisH = 22.0;
    const leftPad = 30.0;
    const topPad = 16.0;
    final baseline = size.height - axisH;
    final plotH = baseline - topPad;
    final plotW = size.width - leftPad;

    final values = points.map((p) => p.snoreIndex).toList();
    var maxV = values.reduce((a, b) => a > b ? a : b);
    if (threshold != null) maxV = math.max(maxV, threshold!);
    // 留点顶部余量，否则最高点会贴着边
    maxV = maxV <= 0 ? 1.0 : maxV * 1.2;

    double xAt(int i) => leftPad + plotW * (i / (points.length - 1));
    double yAt(double v) => baseline - plotH * (v / maxV);

    final grid = ChartMetrics.gridPaint();
    for (final f in const [0.0, 0.5, 1.0]) {
      final y = baseline - plotH * f;
      canvas.drawLine(Offset(leftPad, y), Offset(size.width, y), grid);
      final tp = label('${(maxV * f).toStringAsFixed(1)}%', AppColors.textDim);
      tp.paint(canvas, Offset(0, y - tp.height / 2));
    }

    // 阈值线：这里用虚线是对的——它确实是阈值，不是网格。
    if (threshold != null && threshold! <= maxV) {
      final y = yAt(threshold!);
      final dashed = Paint()
        ..color = AppColors.statusCritical.withValues(alpha: 0.7)
        ..strokeWidth = 1.5;
      for (var x = leftPad; x < size.width; x += 7) {
        canvas.drawLine(Offset(x, y), Offset(math.min(x + 4, size.width), y), dashed);
      }
      final tp = label('$thresholdLabel ${threshold!.toStringAsFixed(0)}%',
          AppColors.statusCritical, size: 9);
      tp.paint(canvas, Offset(size.width - tp.width, y - tp.height - 2));
    }

    // 折线
    final path = Path()..moveTo(xAt(0), yAt(values[0]));
    for (var i = 1; i < values.length; i++) {
      path.lineTo(xAt(i), yAt(values[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ChartMetrics.lineStroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = AppColors.accent,
    );

    // 标记点：末点和极值点直接标数值，其余不标
    final lastIdx = values.length - 1;
    final maxIdx = values.indexOf(values.reduce((a, b) => a > b ? a : b));

    for (var i = 0; i < values.length; i++) {
      final c = Offset(xAt(i), yAt(values[i]));
      final labelled = i == lastIdx || i == maxIdx;
      final r = labelled ? ChartMetrics.markerSize / 2 : 3.5;

      // 用表面色描一圈，避免点跟线糊在一起
      canvas.drawCircle(c, r + 1.5, Paint()..color = AppColors.surface);
      canvas.drawCircle(c, r, Paint()..color = AppColors.accent);

      if (labelled) {
        final tp = label('${values[i].toStringAsFixed(1)}%',
            Colors.white, size: 10, bold: true);
        final ty = c.dy - tp.height - 4;
        final tx = (c.dx + tp.width / 2 > size.width)
            ? size.width - tp.width
            : math.max(leftPad, c.dx - tp.width / 2);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(tx - 4, ty - 2, tp.width + 8, tp.height + 4),
            const Radius.circular(4),
          ),
          Paint()..color = AppColors.surfaceHigh,
        );
        tp.paint(canvas, Offset(tx, ty));
      }
    }

    // 横轴：首末两晚的日期
    final first = points.first.night;
    final last = points.last.night;
    label('${first.month}/${first.day}', AppColors.textDim)
        .paint(canvas, Offset(leftPad, baseline + 6));
    final lastTp = label('${last.month}/${last.day}', AppColors.textDim);
    lastTp.paint(canvas, Offset(size.width - lastTp.width, baseline + 6));

    canvas.drawLine(
      Offset(leftPad, baseline),
      Offset(size.width, baseline),
      ChartMetrics.axisPaint(),
    );
  }

  @override
  bool shouldRepaint(_TrendPainter old) =>
      old.points != points ||
      old.threshold != threshold ||
      old.thresholdLabel != thresholdLabel;
}

// ---------------------------------------------------------------- 时长分布

/// 鼾声段时长分布。
///
/// 单序列、顺序型数据，所以用**同一个颜色**，不按大小上色阶——
/// 色阶会把柱高已经表达的信息再编码一遍，白白浪费颜色这个通道。
class DurationHistogram extends StatelessWidget {
  const DurationHistogram({
    super.key,
    required this.bins,
    this.height = 140,
  });

  final List<DurationBin> bins;
  final double height;

  @override
  Widget build(BuildContext context) {
    final total = bins.fold<int>(0, (a, b) => a + b.count);
    if (total == 0) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(context.l10n.histogramEmpty,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: AppColors.textDim)),
        ),
      );
    }
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _HistogramPainter(
          bins: bins,
          labels: [for (final b in bins) b.kind.label(context)],
        ),
      ),
    );
  }
}

class _HistogramPainter extends CustomPainter {
  _HistogramPainter({required this.bins, required this.labels});

  final List<DurationBin> bins;

  /// 横轴上每一格的文字，由 widget 层按当前语言生成好传进来。
  ///
  /// `CustomPainter` 里只有 Canvas，拿不到 BuildContext，也就查不了本地化。
  /// 这不是新发明的办法——同一文件里的 `thresholdLabel` 早就是这么传的。
  final List<String> labels;

  @override
  void paint(Canvas canvas, Size size) {
    const axisH = 20.0;
    const labelH = 14.0;
    final baseline = size.height - axisH;
    final plotH = baseline - labelH;

    final maxCount =
        bins.map((b) => b.count).fold<int>(0, (a, b) => a > b ? a : b);
    if (maxCount <= 0) return;

    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      ChartMetrics.axisPaint(),
    );

    final slot = size.width / bins.length;
    final barW = slot * 0.62;

    for (var i = 0; i < bins.length; i++) {
      final b = bins[i];
      final cx = slot * i + slot / 2;
      final left = cx - barW / 2;

      if (b.count > 0) {
        final h = math.max(plotH * (b.count / maxCount), 3.0);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTWH(left, baseline - h, barW, h),
            topLeft: const Radius.circular(ChartMetrics.radius),
            topRight: const Radius.circular(ChartMetrics.radius),
          ),
          Paint()..color = SoundClass.snore.color,
        );
        // 只有 6 个分箱，逐个标数值不会造成噪音，反而省了查坐标轴
        final tp = label('${b.count}', Colors.white, size: 10, bold: true);
        tp.paint(canvas, Offset(cx - tp.width / 2, baseline - h - tp.height - 3));
      }

      final tp = label(labels[i], AppColors.textDim, size: 9);
      tp.paint(canvas, Offset(cx - tp.width / 2, baseline + 5));
    }
  }

  @override
  bool shouldRepaint(_HistogramPainter old) =>
      old.bins != bins || old.labels != labels;
}
