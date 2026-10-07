import 'package:flutter/material.dart';

import '../../../../domain/models/sleep_category.dart';
import '../view_models/diagnostic_view_model.dart';
import '../../../core/l10n/domain_text.dart';

/// 端侧推理诊断页。
///
/// 阶段目标：证明 Flutter 端对同一段音频的输出与 PC 端一致。
/// 页面只负责渲染 ViewModel 的状态，不含任何推理或解析逻辑。
class DiagnosticView extends StatelessWidget {
  const DiagnosticView({super.key, required this.viewModel});

  /// 供 Navigator 注册的路由名。
  static const String routeName = '/diagnostic';

  final DiagnosticViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('端侧推理诊断'),
        actions: [
          IconButton(
            onPressed: viewModel.status == DiagnosticStatus.loading
                ? null
                : viewModel.run,
            icon: const Icon(Icons.refresh),
            tooltip: '重新运行',
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) {
          return switch (viewModel.status) {
            DiagnosticStatus.idle => _Centered(
                child: FilledButton.icon(
                  onPressed: viewModel.run,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('加载模型并运行'),
                ),
              ),
            DiagnosticStatus.loading => const _Centered(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('推理中…'),
                  ],
                ),
              ),
            DiagnosticStatus.failed => _FailureView(
                message: viewModel.errorMessage ?? '未知错误',
                onRetry: viewModel.run,
              ),
            DiagnosticStatus.ready => _ResultView(viewModel: viewModel),
          };
        },
      ),
    );
  }
}

class _ResultView extends StatelessWidget {
  const _ResultView({required this.viewModel});

  final DiagnosticViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.memory),
            title: Text('模型：${viewModel.modelName}'),
            subtitle: Text('${viewModel.classCount} 个 AudioSet 标签 → 7 个睡眠大类'),
          ),
        ),
        const SizedBox(height: 8),
        Card(
          color: viewModel.allMatchPc
              ? theme.colorScheme.secondaryContainer
              : theme.colorScheme.errorContainer,
          child: ListTile(
            leading: Icon(
              viewModel.allMatchPc ? Icons.check_circle : Icons.warning_amber,
              color: viewModel.allMatchPc
                  ? theme.colorScheme.onSecondaryContainer
                  : theme.colorScheme.onErrorContainer,
            ),
            title: Text(viewModel.allMatchPc ? '与 PC 端一致' : '与 PC 端存在差异'),
            subtitle: const Text('比对 527 维 logits，容差 1e-3'),
          ),
        ),
        const SizedBox(height: 16),
        for (final result in viewModel.results) _ClipCard(result: result),
      ],
    );
  }
}

class _ClipCard extends StatelessWidget {
  const _ClipCard({required this.result});

  final ClipResult result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final diff = result.maxAbsDiff;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${result.name}  ·  ${result.durationSeconds.toStringAsFixed(1)}s',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                if (diff != null)
                  Chip(
                    visualDensity: VisualDensity.compact,
                    label: Text('最大差 ${diff.toStringAsExponential(1)}'),
                    backgroundColor: result.matchesPC
                        ? theme.colorScheme.secondaryContainer
                        : theme.colorScheme.errorContainer,
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text('7 大类概率', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            for (final category in SleepCategory.values)
              _CategoryBar(
                category: category,
                value: result.prediction.probabilities[category] ?? 0,
              ),
            const SizedBox(height: 12),
            Text('原始 top-5 标签', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            for (final entry in result.prediction.topLabels)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Text(
                  '${entry.label}  ${entry.probability.toStringAsFixed(5)}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CategoryBar extends StatelessWidget {
  const _CategoryBar({required this.category, required this.value});

  final SleepCategory category;
  final double value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(category.label(context), style: theme.textTheme.bodySmall),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: value.clamp(0.0, 1.0),
                minHeight: 10,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 56,
            child: Text(
              value.toStringAsFixed(4),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _FailureView extends StatelessWidget {
  const _FailureView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return _Centered(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, size: 48),
            const SizedBox(height: 12),
            const Text('加载失败', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _Centered extends StatelessWidget {
  const _Centered({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(child: child);
}
