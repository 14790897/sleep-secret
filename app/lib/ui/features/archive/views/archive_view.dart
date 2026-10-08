import 'package:flutter/material.dart';

import '../../../../data/services/webdav_settings.dart';

import '../../../../domain/repositories/archive_controller.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/section_card.dart';
import '../../../core/l10n/l10n_context.dart';
import '../../../core/l10n/ui_message_text.dart';
import '../view_models/archive_view_model.dart';

/// 这一页的测试锚点。**定位用 key、文案用 text**，理由见 report_view 里那段。
abstract final class ArchiveKeys {
  /// 「坚果云 / WebDAV」卡。
  static const ValueKey<String> webDav = ValueKey('section-webdav');
}

/// 数据导出/导入页。
///
/// 存在的意义：**数据不该只困在这台手机上**。
///
/// 两条路：
/// - **文件夹**：配一个目录、把目录设在网盘同步文件夹里，由**网盘客户端**
///   把文件同步走。App 自己不碰网络。
/// - **坚果云 / WebDAV**：App **自己**往网盘上传。这条是为安卓加的——
///   安卓上多数网盘不暴露可写的系统目录，"放进同步文件夹"那条路走不通。
///
/// 两条都是传到**用户自己的**网盘；App 没有自己的服务器。
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
            if (viewModel.webDavAvailable) ...[
              const SizedBox(height: 12),
              _WebDavCard(viewModel: viewModel),
            ],
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
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.statusWarning,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.tonal(
                onPressed: viewModel.busy ? null : viewModel.chooseTarget,
                child: Text(
                  target == null
                      ? context.l10n.archiveChooseFolder
                      : context.l10n.archiveChangeFolder,
                ),
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
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.textDim,
              height: 1.6,
            ),
          ),
        ],
      ),
    );
  }
}

/// 手动导出 / 导入 + 上次的结果。
/// 坚果云 / WebDAV 的连接设置。
///
/// **它是另一种导出目标，不是另一套导出。** 填好之后，下面那张卡上的
/// 「导出全部」就是往网盘写，录完也会自动传——所以它排在目标卡下面。
class _WebDavCard extends StatefulWidget {
  const _WebDavCard({required this.viewModel});

  final ArchiveViewModel viewModel;

  @override
  State<_WebDavCard> createState() => _WebDavCardState();
}

class _WebDavCardState extends State<_WebDavCard> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();

  /// 表单只**预填一次**。
  ///
  /// 连接信息是异步从 Keystore 读的，`initState` 那会儿多半还没到。
  /// 所以不能只在 initState 填——要等它到了再填；而且填过就不再覆盖，
  /// 否则用户正在输入的时候会被读回来的值顶掉。
  bool _filled = false;

  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  void _fillOnce(WebDavSettings? s) {
    if (_filled || s == null) return;
    _filled = true;
    _url.text = s.baseUrl;
    _user.text = s.username;
    _password.text = s.password;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vm = widget.viewModel;
    final note = theme.textTheme.bodySmall?.copyWith(
      color: AppColors.textDim,
      height: 1.6,
    );

    _fillOnce(vm.webDavSettings);

    return SectionCard(
      key: ArchiveKeys.webDav,
      title: context.l10n.webDavTitle,
      subtitle: context.l10n.webDavSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: context.l10n.webDavUrl,
              hintText: WebDavSettings.nutstoreUrl,
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _user,
            autocorrect: false,
            decoration: InputDecoration(labelText: context.l10n.webDavUser),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _password,
            // 遮住。坚果云的应用密码是一串随机字符，输的时候被人看见也难受。
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(labelText: context.l10n.webDavPassword),
          ),
          const SizedBox(height: 10),
          Text(context.l10n.webDavNutstoreHint, style: note),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton(
                onPressed: vm.webDavBusy
                    ? null
                    : () => vm.saveAndUseWebDav(
                        WebDavSettings(
                          baseUrl: _url.text.trim(),
                          username: _user.text.trim(),
                          password: _password.text,
                        ),
                      ),
                child: Text(context.l10n.webDavSave),
              ),
              const SizedBox(width: 8),
              TextButton(
                onPressed: vm.webDavBusy
                    ? null
                    : () {
                        _url.clear();
                        _user.clear();
                        _password.clear();
                        // 清空之后别被读回来的旧值又填上
                        _filled = true;
                        vm.clearWebDav();
                      },
                child: Text(context.l10n.webDavClear),
              ),
            ],
          ),
          if (vm.webDavBusy) ...[
            const SizedBox(height: 10),
            Text(context.l10n.webDavTesting, style: note),
          ] else if (vm.webDavOk) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.check_circle,
                  size: 16,
                  color: AppColors.statusGood,
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(context.l10n.webDavTestOk, style: note)),
              ],
            ),
          ] else if (vm.webDavMessage != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.error_outline,
                  size: 16,
                  color: AppColors.statusCritical,
                ),
                const SizedBox(width: 6),
                // 这条消息是 WebDavClient 拼的，**带着下一步怎么办**
                // （401 会说「用应用密码」）。别在这儿把它翻掉——
                // 那正是用户唯一能照着做的东西。
                Expanded(
                  child: Text(
                    vm.webDavMessage!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.statusCritical,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _ActionsCard extends StatelessWidget {
  const _ActionsCard({required this.viewModel});

  final ArchiveViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outcome = viewModel.lastOutcome;
    final ready =
        viewModel.hasTarget && viewModel.targetUsable && !viewModel.busy;

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
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.statusCritical,
                height: 1.5,
              ),
            ),
          ],
          if (outcome != null) ...[
            const SizedBox(height: 12),
            _OutcomeLine(outcome: outcome, wasExport: viewModel.lastWasExport),
          ],
          const SizedBox(height: 12),
          Text(
            context.l10n.archiveDedupeHint,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.textDim,
              height: 1.6,
            ),
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
              : context.l10n.archiveLastImport)(parts.join(' · ')),
          style: theme.textTheme.bodySmall?.copyWith(
            color: outcome.isClean
                ? AppColors.statusGood
                : AppColors.statusWarning,
          ),
        ),
        for (final p in outcome.problems.take(5))
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '· ${p.message(context)}',
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.textDim,
                height: 1.5,
              ),
            ),
          ),
      ],
    );
  }
}

/// 明确说清楚导出了什么——**包括音频**。
///
/// App 自己的说法是「默认音频不出设备」，而这里导出的文件里**是有音频的**——
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
              child: Text(
                '· $line',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.6),
              ),
            ),
          const SizedBox(height: 6),
          Text(
            context.l10n.archiveAudioWarning,
            style: theme.textTheme.labelSmall?.copyWith(
              color: AppColors.textDim,
              height: 1.65,
            ),
          ),
        ],
      ),
    );
  }
}
