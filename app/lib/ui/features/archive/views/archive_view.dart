import 'package:flutter/material.dart';

import '../../../../domain/repositories/archive_controller.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/l10n/l10n_context.dart';
import '../../../core/l10n/ui_message_text.dart';
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
        appBar: AppBar(title: Text(context.l10n.archiveTitle)),
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
      title: context.l10n.archiveTargetTitle,
      subtitle: context.l10n.archiveTargetSubtitle,
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
                  target ?? context.l10n.archiveNoTarget,
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
              context.l10n.archiveTargetBroken,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: AppColors.statusWarning, height: 1.5),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: viewModel.busy ? null : viewModel.chooseTarget,
                child: Text(target == null
                    ? context.l10n.archiveChooseFolder
                    : context.l10n.archiveChangeFolder),
              ),
              if (target != null) ...[
                const SizedBox(width: 8),
                TextButton(
                  onPressed: viewModel.busy ? null : viewModel.clearTarget,
                  child: Text(context.l10n.archiveClearTarget),
                ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Text(
            context.l10n.archiveSyncHint,
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
      title: context.l10n.archiveManualTitle,
      subtitle: context.l10n.archiveManualSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              FilledButton.tonal(
                onPressed: ready ? viewModel.exportAll : null,
                child: Text(context.l10n.archiveExportAll),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: ready ? viewModel.importAll : null,
                child: Text(context.l10n.archiveImportAll),
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
              viewModel.error!.message(context),
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
            context.l10n.archiveDedupeHint,
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
    final parts = <String>[
      wasExport
          ? context.l10n.archivePartExported(outcome.sessions)
          : context.l10n.archivePartImported(outcome.sessions),
      if (outcome.clips > 0) context.l10n.archivePartClips(outcome.clips),
      if (outcome.skipped > 0) context.l10n.archivePartSkipped(outcome.skipped),
      if (outcome.clipsMissing > 0)
        context.l10n.archivePartClipsMissing(outcome.clipsMissing),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          (wasExport
                  ? context.l10n.archiveLastExport
                  : context.l10n.archiveLastImport)(
              parts.join(' · ')),
          style: theme.textTheme.bodySmall?.copyWith(
            color: outcome.isClean ? AppColors.statusGood : AppColors.statusWarning,
          ),
        ),
        for (final p in outcome.problems.take(5))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '· ${p.message(context)}',
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
      title: context.l10n.archiveContentsTitle,
      subtitle: context.l10n.archiveContentsSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final line in [
            context.l10n.archiveContentsLine1,
            context.l10n.archiveContentsLine2,
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text('· $line',
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.6)),
            ),
          const SizedBox(height: 6),
          Text(
            context.l10n.archiveAudioWarning,
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.textDim, height: 1.65),
          ),
        ],
      ),
    );
  }
}
