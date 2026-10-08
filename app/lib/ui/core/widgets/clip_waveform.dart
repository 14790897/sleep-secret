import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../theme.dart';

/// 波形上一根柱子：这一列采样点的最小值和最大值。
typedef WaveformPeak = ({double min, double max});

/// 把采样点抽成 [buckets] 根柱子。
///
/// 抽的是**每列的极值**而不是平均值：波形看的是形状，平均值会把一列里的
/// 尖峰抹平——一段忽大忽小的鼾声画出来会是一根没有起伏的细线。
List<WaveformPeak> waveformPeaks(Float32List samples, {int buckets = 160}) {
  if (samples.isEmpty || buckets <= 0) return const [];

  final out = <WaveformPeak>[];
  final per = samples.length / buckets;

  for (var b = 0; b < buckets; b++) {
    final start = (b * per).floor();
    var end = ((b + 1) * per).ceil();
    if (end <= start) end = start + 1;
    if (end > samples.length) end = samples.length;
    if (start >= end) {
      out.add((min: 0.0, max: 0.0));
      continue;
    }

    var lo = samples[start];
    var hi = samples[start];
    for (var i = start + 1; i < end; i++) {
      final v = samples[i];
      if (v < lo) lo = v;
      if (v > hi) hi = v;
    }
    // 越界的采样点（余量不足的片段会有）夹回来，不然画到框外面
    out.add((min: lo.clamp(-1.0, 1.0), max: hi.clamp(-1.0, 1.0)));
  }
  return out;
}

/// 波形 + 可拖拽的播放头。
///
/// 拖动时**先只动播放头、松手才 seek**：拖动过程中每一帧都 seek 会让播放器
/// 反复重新起播，听感是断续的。所以这里自己维护一个"正在拖"的位置，
/// 只在 [onSeek] 里回调最终结果。
class ClipWaveform extends StatefulWidget {
  const ClipWaveform({
    super.key,
    required this.peaks,
    required this.progress,
    required this.onSeek,
    this.height = 76,
  });

  final List<WaveformPeak> peaks;

  /// 播放进度 0..1。拖动时会被手指的位置盖住。
  final double progress;

  /// 松手（或点一下）时的目标进度 0..1。
  final ValueChanged<double> onSeek;

  final double height;

  @override
  State<ClipWaveform> createState() => _ClipWaveformState();
}

class _ClipWaveformState extends State<ClipWaveform> {
  /// 非 null 表示正在拖。松手后清掉，交回给播放进度。
  double? _drag;

  double _fractionAt(Offset local, double width) {
    if (width <= 0) return 0;
    return (local.dx / width).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final shown = _drag ?? widget.progress.clamp(0.0, 1.0);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => setState(() => _drag = _fractionAt(d.localPosition, width)),
          onTapUp: (d) => setState(() {
            final f = _fractionAt(d.localPosition, width);
            _drag = null;
            widget.onSeek(f);
          }),
          onHorizontalDragStart: (d) =>
              setState(() => _drag = _fractionAt(d.localPosition, width)),
          onHorizontalDragUpdate: (d) =>
              setState(() => _drag = _fractionAt(d.localPosition, width)),
          onHorizontalDragEnd: (_) {
            final f = _drag ?? shown;
            setState(() => _drag = null);
            widget.onSeek(f);
          },
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: CustomPaint(
              painter: _WaveformPainter(
                peaks: widget.peaks,
                progress: shown,
                dragging: _drag != null,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.peaks,
    required this.progress,
    required this.dragging,
  });

  final List<WaveformPeak> peaks;
  final double progress;
  final bool dragging;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;

    // 中线：没声音的地方也能看出"这里是一条时间轴"
    canvas.drawLine(
      Offset(0, mid),
      Offset(size.width, mid),
      Paint()
        ..color = AppColors.divider
        ..strokeWidth = 1,
    );

    if (peaks.isEmpty) return;

    final playedPaint = Paint()..color = AppColors.accent;
    final restPaint = Paint()..color = AppColors.textDim.withValues(alpha: 0.45);
    final slot = size.width / peaks.length;
    // 柱子之间留一点缝才看得出是一根根的；但别细到看不见
    final barWidth = (slot * 0.7).clamp(1.0, 6.0);
    final split = size.width * progress;

    for (var i = 0; i < peaks.length; i++) {
      final x = slot * i + slot / 2;
      final peak = peaks[i];

      // 极小的起伏也要画出来，否则静音段会变成一片空白
      final top = mid - (peak.max.abs() < 0.02 ? 1.0 : peak.max * mid * 0.95);
      final bottom = mid + (peak.min.abs() < 0.02 ? 1.0 : -peak.min * mid * 0.95);

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(x - barWidth / 2, top, x + barWidth / 2, bottom),
          Radius.circular(barWidth / 2),
        ),
        x <= split ? playedPaint : restPaint,
      );
    }

    // 播放头。拖动时加粗——手指底下那条线要看得见
    canvas.drawLine(
      Offset(split, 0),
      Offset(split, size.height),
      Paint()
        ..color = dragging ? Colors.white : AppColors.accent
        ..strokeWidth = dragging ? 2.5 : 1.5,
    );
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.dragging != dragging ||
      !identical(old.peaks, peaks);
}
