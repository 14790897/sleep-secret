import 'package:flutter/material.dart';

import '../../../../domain/repositories/archive_controller.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/section_card.dart';
import '../view_models/archive_view_model.dart';

/// 数据导出/导入页。
///
/// 存在的意义：**数据不该只困在这台手机上**。用户配一个目录，把目录设在
/// 网盘同步文件夹里，就自动获得了云端备份——App 自己不上传任何东西，
/// 是用户自己把目录同步走的。
class ArchiveView extends StatelessWidget {
  const ArchiveView({super.key, required this.viewModel});

  static const String routeName = '/archive';

  final ArchiveViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: viewModel,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('数据导出')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _TargetCard(viewModel: viewModel),
            const SizedBox(height: 12),
            _ActionsCard(viewModel: viewModel),
            const SizedBox(height: 12),
            const _WhatGetsExportedCard(),
          ],
        ),
      ),
    );
  }
}

/// 导出到哪儿。
class _TargetCard extends StatelessWidget {
  const _TargetCard({required this.viewModel});

  final ArchiveViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final target = viewModel.targetDescription;

    return SectionCard(
      title: '导出目录',
      subtitle: '选一个目录，每次录音结束会自动导出过去',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                viewModel.targetBroken
                    ? Icons.warning_amber
                    : target == null
                        ? Icons.folder_off_outlined
                        : Icons.folder_outlined,
                size: 18,
                color: viewModel.targetBroken
                    ? AppColors.statusWarning
                    : AppColors.textDim,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  target ?? '还没选目录',
                  style: theme.textTheme.bodyMedium,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (viewModel.targetBroken) ...[
            const SizedBox(height: 8),
            Text(
              '这个目录现在用不了——可能是授权被系统收回了，或者目录被删了。'
              '重新选一次即可。',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: AppColors.statusWarning, height: 1.5),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: viewModel.busy ? null : viewModel.chooseTarget,
                child: Text(target == null ? '选择目录' : '换一个'),
              ),
              if (target != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: viewModel.busy ? null : viewModel.clearTarget,
                  child: const Text('取消配置'),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '把目录设在网盘的同步文件夹里（比如 iCloud、OneDrive、坚果云的本地目录），'
            '就自动有了云端备份。**App 自己不上传任何东西**，是你的网盘客户端在同步。',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.textDim, height: 1.6),
          ),
        ],
      ),
    );
  }
}

/// 手动导出 / 导入 + 上次的结果。
class _ActionsCard extends StatelessWidget {
  const _ActionsCard({required this.viewModel});

  final ArchiveViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outcome = viewModel.lastOutcome;
    final ready = viewModel.hasTarget && viewModel.targetUsable && !viewModel.busy;

    return SectionCard(
      title: '手动导出 / 导入',
      subtitle: '平时不用管，录音结束会自动导',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.tonal(
                onPressed: ready ? viewModel.exportAll : null,
                child: const Text('导出全部'),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: ready ? viewModel.importAll : null,
                child: const Text('从目录导入'),
              ),
              if (viewModel.busy) ...[
                const SizedBox(width: 12),
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ],
            ],
          ),
          if (viewModel.error != null) ...[
            const SizedBox(height: 12),
            Text(
              viewModel.error!,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: AppColors.statusCritical, height: 1.5),
            ),
          ],
          if (outcome != null) ...[
            const SizedBox(height: 12),
            _OutcomeLine(outcome: outcome, wasExport: viewModel.lastWasExport),
          ],
          const SizedBox(height: 12),
          Text(
            '导入按「开始时刻」去重——同一晚不会重复进来。'
            '换设备时先导出，再把目录同步过去，在新设备上导入即可。',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.textDim, height: 1.6),
          ),
        ],
      ),
    );
  }
}

class _OutcomeLine extends StatelessWidget {
  const _OutcomeLine({required this.outcome, required this.wasExport});

  final ArchiveOutcome outcome;
  final bool wasExport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verb = wasExport ? '导出' : '导入';

    final parts = <String>[
      '$verb ${outcome.sessions} 晚',
      if (outcome.clips > 0) '片段 ${outcome.clips} 个',
      if (outcome.skipped > 0) '跳过 ${outcome.skipped} 晚（已经有了）',
      if (outcome.clipsMissing > 0) '${outcome.clipsMissing} 个片段没找到',
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '上次$verb：${parts.join(' · ')}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: outcome.isClean ? AppColors.statusGood : AppColors.statusWarning,
          ),
        ),
        for (final p in outcome.problems.take(5))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '· $p',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: AppColors.textDim, height: 1.5),
            ),
          ),
      ],
    );
  }
}

/// 明确说清楚导出了什么——**包括音频**。
///
/// App 自己的说法是「音频不出设备」，而这里导出的文件里**是有音频的**。
/// 用户把目录放进网盘，音频就跟着上云了。这是用户自己的选择，
/// 但他必须知道自己在选什么。
class _WhatGetsExportedCard extends StatelessWidget {
  const _WhatGetsExportedCard();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SectionCard(
      title: '导出的内容',
      subtitle: '一晚一个 JSON 文件，外加音频片段',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in const [
            '事件的时间点、类别、置信度，以及整晚的统计。',
            '鼾声片段的音频文件（WAV）——**这部分是声音本身**。',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('· $line',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.6)),
            ),
          const SizedBox(height: 6),
          Text(
            '⚠️ 导出的文件里**包含音频**。如果你把目录放在网盘同步文件夹里，'
            '这些音频会跟着上传到云端——那是你的网盘，不是这个应用。'
            '介意的话，到「关于」页把「保留鼾声片段」关掉，'
            '之后就只会导出分析结果，不含任何声音。',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.textDim, height: 1.65),
          ),
        ],
      ),
    );
  }
}
