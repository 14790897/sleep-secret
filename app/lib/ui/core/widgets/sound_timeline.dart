import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../../domain/models/sound_event.dart';
import '../theme.dart';
import '../l10n/domain_text.dart';

/// 整夜声音时间线。
///
/// 每个事件一根柱子，宽度 = 持续时长，高度 = 类别权重，颜色 = 声音大类。
/// 静音不画柱子，只在底部留一层底纹——它是背景，不是事件。
///
/// 颜色只有 3 类（见 [SoundClass] 的说明，这是 CVD 验证器的硬约束），
/// 7 个细类靠柱高区分；精确类别由点按提示和下方事件列表给出。
class SoundTimeline extends StatefulWidget {
  const SoundTimeline({
    super.key,
    required this.events,
    required this.totalSeconds,
    this.startedAt,
    this.height = 132,
  });

  final List<SoundEvent> events;

  /// 整段时长，决定横轴比例。
  final double totalSeconds;

  /// 会话开始时刻，用于把横轴标成真实钟点。
  final DateTime? startedAt;

  final double height;

  @override
  State<SoundTimeline> createState() => _SoundTimelineState();
}

class _SoundTimelineState extends State<SoundTimeline> {
  /// 被点按选中的事件下标；-1 表示没有。
  int _selected = -1;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (widget.events.isEmpty || widget.totalSeconds <= 0) {
      return SizedBox(
        height: widget.height,
        child: Center(
          child: Text('这一晚没有检出声音事件',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textDim)),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _select(d.localPosition.dx, context),
          onHorizontalDragUpdate: (d) => _select(d.localPosition.dx, context),
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: CustomPaint(
              painter: _TimelinePainter(
                events: widget.events,
                totalSeconds: widget.totalSeconds,
                startedAt: widget.startedAt,
                selected: _selected,
                dimColor: AppColors.textDim,
                gridColor: AppColors.divider,
                trackColor: AppColors.surfaceHigh,
                surfaceColor: AppColors.surface,
                textDirection: Directionality.of(context),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        _AxisLabels(
          totalSeconds: widget.totalSeconds,
          startedAt: widget.startedAt,
        ),
        if (_selected >= 0 && _selected < widget.events.length) ...[
          const SizedBox(height: 10),
          _EventTooltip(
            event: widget.events[_selected],
            startedAt: widget.startedAt,
          ),
        ],
      ],
    );
  }

  void _select(double dx, BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || widget.totalSeconds <= 0) return;
    final width = box.size.width;
    if (width <= 0) return;

    final seconds = (dx / width) * widget.totalSeconds;

    // 找覆盖该时间点的事件；没有就找最近的。
    var best = -1;
    var bestDistance = double.infinity;
    for (var i = 0; i < widget.events.length; i++) {
      final e = widget.events[i];
      if (seconds >= e.startSeconds && seconds <= e.endSeconds) {
        best = i;
        break;
      }
      final d = math.min(
        (seconds - e.startSeconds).abs(),
        (seconds - e.endSeconds).abs(),
      );
      if (d < bestDistance) {
        bestDistance = d;
        best = i;
      }
    }
    if (best != _selected) setState(() => _selected = best);
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.events,
    required this.totalSeconds,
    required this.startedAt,
    required this.selected,
    required this.dimColor,
    required this.gridColor,
    required this.trackColor,
    required this.surfaceColor,
    required this.textDirection,
  });

  final List<SoundEvent> events;
  final double totalSeconds;
  final DateTime? startedAt;
  final int selected;
  final Color dimColor;
  final Color gridColor;
  final Color trackColor;
  final Color surfaceColor;
  final ui.TextDirection textDirection;

  /// 柱子要有间隙，否则相邻事件糊成一片。
  static const double _gap = 2;

  /// 数据端圆角，和 skill 的 mark 规范一致。
  static const double _radius = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final baseline = size.height - 18;
    final maxBar = baseline - 6;

    // 底纹：整夜的"安静"底色。
    final track = Paint()..color = trackColor.withValues(alpha: 0.55);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, baseline - maxBar * kTimelineTrackWeight, size.width,
            maxBar * kTimelineTrackWeight),
        const Radius.circular(2),
      ),
      track,
    );

    // 横向参考线，克制一点。
    final grid = Paint()
      ..color = gridColor.withValues(alpha: 0.5)
      ..strokeWidth = 1;
    for (final f in const [0.25, 0.5, 0.75, 1.0]) {
      final y = baseline - maxBar * f;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    for (var i = 0; i < events.length; i++) {
      final e = events[i];
      if (e.label.isRecessive) continue;

      final left = (e.startSeconds / totalSeconds) * size.width;
      final rawRight = (e.endSeconds / totalSeconds) * size.width;
      final right = math.max(rawRight, left + 1.0);
      final width = math.max(right - left - _gap, 1.0);
      final barHeight = math.max(maxBar * e.label.timelineWeight, 2.0);

      final color = e.label.soundClass.color;
      final isSelected = i == selected;

      final paint = Paint()
        ..color = isSelected ? color : color.withValues(alpha: 0.88);

      final rect = Rect.fromLTWH(left, baseline - barHeight, width, barHeight);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          rect,
          topLeft: const Radius.circular(_radius),
          topRight: const Radius.circular(_radius),
        ),
        paint,
      );

      // 选中态：加一圈表面色描边把它从邻居里"抠"出来，
      // 而不是靠变亮——变亮会跟别的大类撞色。
      if (isSelected) {
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            rect.inflate(1),
            topLeft: const Radius.circular(_radius + 1),
            topRight: const Radius.circular(_radius + 1),
          ),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2
            ..color = surfaceColor,
        );
      }
    }

    // 基线
    canvas.drawLine(
      Offset(0, baseline),
      Offset(size.width, baseline),
      Paint()
        ..color = gridColor
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_TimelinePainter old) =>
      old.events != events ||
      old.selected != selected ||
      old.totalSeconds != totalSeconds;
}

/// 横轴刻度：整点为主，首尾标真实时刻。
class _AxisLabels extends StatelessWidget {
  const _AxisLabels({required this.totalSeconds, required this.startedAt});

  final double totalSeconds;
  final DateTime? startedAt;

  static const int _ticks = 5;

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context)
        .textTheme
        .labelSmall
        ?.copyWith(color: AppColors.textDim, fontSize: 10);

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        for (var i = 0; i < _ticks; i++)
          Text(_labelFor(i / (_ticks - 1) * totalSeconds), style: style),
      ],
    );
  }

  String _labelFor(double seconds) {
    final at = startedAt?.add(Duration(seconds: seconds.round()));
    if (at != null) {
      return '${at.hour.toString().padLeft(2, '0')}:'
          '${at.minute.toString().padLeft(2, '0')}';
    }
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    return '$m:00';
  }
}

/// 点按后显示的详情条。
class _EventTooltip extends StatelessWidget {
  const _EventTooltip({required this.event, required this.startedAt});

  final SoundEvent event;
  final DateTime? startedAt;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final at = startedAt?.add(Duration(seconds: event.startSeconds.round()));
    final clock = at == null
        ? _mmss(event.startSeconds)
        : '${at.hour.toString().padLeft(2, '0')}:'
            '${at.minute.toString().padLeft(2, '0')}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: event.label.soundClass.color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '$clock  ${event.label.label(context)}  ·  '
              '${event.durationSeconds.round()} 秒'
              '${event.isSnore ? '  ·  鼾声概率 ${(event.snoreProbability * 100).toStringAsFixed(0)}%' : ''}',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  static String _mmss(double seconds) {
    final t = seconds.round();
    return '${(t ~/ 60).toString().padLeft(2, '0')}:'
        '${(t % 60).toString().padLeft(2, '0')}';
  }
}
