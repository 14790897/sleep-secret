import 'package:flutter/material.dart';

import '../theme.dart';

/// 分区卡片：左侧一道亮蓝竖条 + 标题，下面是内容。
///
/// 这是蜗牛睡眠最显眼的版式特征，一眼能把长报告切成可扫读的段落。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.subtitle,
    this.onTap,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final Widget child;

  /// 给了就**只有标题那一行**可点——不是整张卡。
  ///
  /// 用在可折叠的卡上：整张卡可点的话，用户读正文时随手一碰就收回去了。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 3,
                    height: 16,
                    margin: const EdgeInsets.only(top: 2, right: 8),
                    decoration: BoxDecoration(
                      color: AppColors.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (subtitle != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              subtitle!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: AppColors.textDim,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  ?trailing,
                ],
              ),
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

/// 大数字 + 小标签。深色报告页里最主要的数值呈现方式。
class MetricTile extends StatelessWidget {
  const MetricTile({
    super.key,
    required this.value,
    required this.label,
    this.unit,
    this.valueColor,
    this.hint,
  });

  final String value;
  final String label;
  final String? unit;
  final Color? valueColor;
  final String? hint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Flexible(
              child: Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: valueColor,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
            if (unit != null)
              Padding(
                padding: const EdgeInsets.only(left: 2),
                child: Text(
                  unit!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textDim,
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.textDim),
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              hint!,
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.textDim,
              ),
            ),
          ),
      ],
    );
  }
}

/// 小圆角状态徽章，用来给指标打「较低 / 一般 / 正常」这类标签。
class StatusBadge extends StatelessWidget {
  const StatusBadge({super.key, required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

/// 等间距排列若干指标，窄屏自动换行。
class MetricRow extends StatelessWidget {
  const MetricRow({super.key, required this.children, this.perRow = 3});

  final List<Widget> children;
  final int perRow;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final spacing = 8.0;
        final width = (constraints.maxWidth - spacing * (perRow - 1)) / perRow;
        return Wrap(
          spacing: spacing,
          runSpacing: 14,
          children: [
            for (final child in children) SizedBox(width: width, child: child),
          ],
        );
      },
    );
  }
}

/// 图例：一行彩色圆点 + 名称。
class CategoryLegend extends StatelessWidget {
  const CategoryLegend({super.key, required this.entries, this.onTap});

  final Map<String, Color> entries;
  final void Function(String label)? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Wrap(
      spacing: 14,
      runSpacing: 6,
      children: [
        for (final e in entries.entries)
          GestureDetector(
            onTap: onTap == null ? null : () => onTap!(e.key),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: e.value,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  e.key,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.textDim,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
