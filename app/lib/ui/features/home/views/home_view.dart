import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../../domain/models/recording_session.dart';
import '../../../../domain/repositories/locale_controller.dart';
import '../../../../domain/repositories/recording_controller.dart'
    show kVadThresholdDbMax, kVadThresholdDbMin;
import '../../../core/l10n/l10n_context.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/score_gauge.dart';
import '../../../core/widgets/section_card.dart';
import '../../archive/views/archive_view.dart';
import '../../diagnostic/views/diagnostic_view.dart';
import '../../recording/view_models/recording_view_model.dart';
import '../../recording/views/recording_view.dart';
import '../../report/view_models/report_view_model.dart';
import '../../report/views/report_view.dart';
import '../../trend/views/trend_card.dart';

/// 会话 -> 报告页 ViewModel 的工厂。
///
/// 外壳不需要知道片段存储和播放器怎么装配，只要求"给一个会话，
/// 还我一个能用的报告 ViewModel"。
typedef ReportViewModelFactory = ReportViewModel Function(
  RecordingSession session,
);

/// 应用外壳：底部导航 + 三个页面。
class HomeView extends StatefulWidget {
  const HomeView({
    super.key,
    required this.localeController,
    required this.recordingViewModel,
    required this.reportViewModelFactory,
  });

  /// 界面语言偏好。关于页上有个选择器。
  final LocaleController localeController;

  final RecordingViewModel recordingViewModel;
  final ReportViewModelFactory reportViewModelFactory;

  @override
  State<HomeView> createState() => _HomeViewState();
}

class _HomeViewState extends State<HomeView> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.recordingViewModel,
      builder: (context, _) {
        return Scaffold(
          body: IndexedStack(
            index: _tab,
            children: [
              RecordingView(
                viewModel: widget.recordingViewModel,
                embedded: true,
              ),
              _ReportListView(
                viewModel: widget.recordingViewModel,
                reportViewModelFactory: widget.reportViewModelFactory,
              ),
              _AboutView(
                viewModel: widget.recordingViewModel,
                localeController: widget.localeController,
              ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              NavigationDestination(
                icon: const Icon(Icons.mic_none),
                selectedIcon: const Icon(Icons.mic),
                label: context.l10n.tabSleep,
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: widget.recordingViewModel.sessions.isNotEmpty,
                  label: Text('${widget.recordingViewModel.sessions.length}'),
                  child: const Icon(Icons.bar_chart_outlined),
                ),
                selectedIcon: const Icon(Icons.bar_chart),
                label: context.l10n.tabReport,
              ),
              NavigationDestination(
                icon: const Icon(Icons.info_outline),
                selectedIcon: const Icon(Icons.info),
                label: context.l10n.tabAbout,
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 报告 tab：历史列表，点进去看单晚详情。
class _ReportListView extends StatefulWidget {
  const _ReportListView({
    required this.viewModel,
    required this.reportViewModelFactory,
  });

  final RecordingViewModel viewModel;
  final ReportViewModelFactory reportViewModelFactory;

  @override
  State<_ReportListView> createState() => _ReportListViewState();
}

class _ReportListViewState extends State<_ReportListView> {
  @override
  void initState() {
    super.initState();
    // 不能在这里直接调 loadSessions()：它会在第一个 await 之前同步
    // notifyListeners()，而 initState 是在 build 阶段跑的，会触发
    // 「setState() called during build」。
    //
    // HomeView 用 IndexedStack 一次构建全部三个页面，所以这个 initState
    // 在 App 启动时就会跑到——也就是说这个错误会在每次冷启动时发生。
    // 放到首帧之后再拉数据。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.viewModel.loadSessions();
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.viewModel;

    return Scaffold(
      appBar: AppBar(title: Text(context.l10n.reportTitle)),
      body: vm.loadingSessions
          ? const Center(child: CircularProgressIndicator())
          : vm.sessions.isEmpty
          ? _EmptyReports()
          : RefreshIndicator(
              onRefresh: vm.loadSessions,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  // 趋势放在最上面：只有一晚时它自己会退化成一句提示
                  TrendCard(sessions: vm.sessions),
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      context.l10n.historyTitle,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  for (final s in vm.sessions)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _ReportCard(
                        session: s,
                        onTap: () => _openReport(s),
                        onDelete: () => vm.deleteSession(s.id!),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  Future<void> _openReport(RecordingSession summary) async {
    // 列表里不带事件，进详情前按 id 取完整数据。
    final full = await widget.viewModel.loadSession(summary.id!);
    if (!mounted || full == null) return;

    final reportVm = widget.reportViewModelFactory(full);
    await Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => ReportView(viewModel: reportVm)));
    // 退出报告页要停掉播放并释放资源，否则声音会继续响。
    reportVm.dispose();
  }
}

class _EmptyReports extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.nightlight_outlined,
              size: 56,
              color: AppColors.textDim.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 16),
            Text(
              context.l10n.noReportsTitle,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              context.l10n.noReportsBody,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.textDim,
                height: 1.6,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  const _ReportCard({
    required this.session,
    required this.onTap,
    required this.onDelete,
  });

  final RecordingSession session;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = session.stats;
    final started = session.startedAt;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // 左侧一个小环，扫一眼就能比较各晚的鼾声程度
              SizedBox(
                width: 64,
                height: 64,
                child: CustomPaint(
                  painter: _MiniRingPainter(
                    progress: (s.snoreIndex / 100).clamp(0.0, 1.0),
                  ),
                  child: Center(
                    child: Text(
                      s.snoreIndex.toStringAsFixed(0),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      // 整句交给 ARB：中文是「10月7日」，英文不能照拼
                      context.l10n.reportCardTime(
                        started.month,
                        started.day,
                        '${started.hour.toString().padLeft(2, '0')}:'
                        '${started.minute.toString().padLeft(2, '0')}',
                      ),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.l10n.reportCardSummary(
                        s.snoreEventCount,
                        formatSpan(s.snoreSeconds),
                        s.eventCount,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.textDim,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: AppColors.textDim,
                tooltip: context.l10n.delete,
                onPressed: () => _confirmDelete(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(context.l10n.deleteConfirmTitle),
        content: Text(context.l10n.deleteConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(context.l10n.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(context.l10n.delete),
          ),
        ],
      ),
    );
    if (ok == true) onDelete();
  }
}

/// 列表里的小圆环，和详情页的大仪表同一套颜色规则。
class _MiniRingPainter extends CustomPainter {
  _MiniRingPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 5.0;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: (size.shortestSide - stroke) / 2,
    );
    final color = progress < 0.15
        ? AppColors.statusGood
        : progress < 0.35
        ? AppColors.statusWarning
        : AppColors.statusCritical;

    canvas.drawCircle(
      rect.center,
      rect.width / 2,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = AppColors.surfaceHigh,
    );
    canvas.drawArc(
      rect,
      -1.5707963,
      6.2831853 * progress,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(_MiniRingPainter old) => old.progress != progress;
}

/// 测试锚点。和 `ReportKeys` 一个规矩：**定位用 key，文案用 text**。
abstract final class HomeKeys {
  /// 关于页整棵子树。
  ///
  /// `_AboutView` 是私有的，测试没法按类型找它；而"这一页有没有混进中文"
  /// 这种检查需要能把它单独圈出来——整棵树里还混着别的页面。
  static const ValueKey<String> aboutView = ValueKey('home-about-view');

  /// 「关于」页底部那行版本号。
  static const ValueKey<String> version = ValueKey('home-version');
}

/// 关于页：说明 App 做什么、不做什么，以及音频片段的隐私开关。
class _AboutView extends StatelessWidget {
  const _AboutView({required this.viewModel, required this.localeController});

  final RecordingViewModel viewModel;
  final LocaleController localeController;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      key: HomeKeys.aboutView,
      appBar: AppBar(title: Text(context.l10n.tabAbout)),
      body: ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            _LanguageCard(controller: localeController),
            const SizedBox(height: 12),
            SectionCard(
              title: context.l10n.aboutWhatTitle,
              child: Text(
                context.l10n.aboutWhatBody,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.7),
              ),
            ),
            const SizedBox(height: 12),
            _ClipRecordingCard(viewModel: viewModel),
            const SizedBox(height: 12),
            _VadCard(viewModel: viewModel),
            const SizedBox(height: 12),
            SectionCard(
              title: context.l10n.aboutPrivacyTitle,
              subtitle: context.l10n.aboutPrivacySubtitle,
              child: Text(
                context.l10n.aboutPrivacyBody,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.7),
              ),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: context.l10n.aboutNotTitle,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.l10n.aboutNotBody,
                    style: theme.textTheme.bodySmall?.copyWith(
                      height: 1.7,
                      color: AppColors.textDim,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // 分贝是估算的，这条必须在用户看得到的地方说清楚——
                  // 不然他会拿它跟真的声级计比，然后发现对不上。
                  Text(
                    context.l10n.levelApproxNote,
                    style: theme.textTheme.labelSmall?.copyWith(
                      height: 1.6,
                      color: AppColors.textDim,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(
                  Icons.cloud_upload_outlined,
                  color: AppColors.accent,
                ),
                title: Text(context.l10n.archiveEntry),
                subtitle: Text(
                  context.l10n.archiveEntrySubtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textDim,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    Navigator.of(context).pushNamed(ArchiveView.routeName),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.memory, color: AppColors.accent),
                title: Text(context.l10n.diagnosticEntry),
                subtitle: Text(
                  context.l10n.diagnosticEntrySubtitle,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.textDim,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () =>
                    Navigator.of(context).pushNamed(DiagnosticView.routeName),
              ),
            ),
            const _VersionFooter(),
          ],
        ),
      ),
    );
  }
}

/// 「关于」页最底下那行版本号。
///
/// ## 为什么从系统读，而不是写个常量
///
/// 版本号在这里是**给用户验货用的**：他刚装完一版，想知道「我装的是新的吗」。
/// 写死常量的话每次发版都得记得改，而发版是 `semantic-release` **自动**去改
/// `pubspec.yaml` 的，人根本不经过这里，迟早漂掉。
/// `package_info_plus` 读的是**系统里那个已经装好的包**，显示的一定是真正
/// 在跑的那一版。
class _VersionFooter extends StatefulWidget {
  const _VersionFooter();

  @override
  State<_VersionFooter> createState() => _VersionFooterState();
}

class _VersionFooterState extends State<_VersionFooter> {
  /// 只解析一次。`IndexedStack` 会让这个 State 长期活着，但别指望这件事——
  /// 每次 build 都去问一遍平台通道是白花力气。
  late final Future<PackageInfo> _info = PackageInfo.fromPlatform();

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PackageInfo>(
      future: _info,
      builder: (context, snap) {
        final info = snap.data;
        // 拿不到就什么都不显示。版本号是补充信息，不是这一页的内容——
        // 为它显示一行错误，只会让人以为应用坏了。
        if (info == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 20),
          child: Text(
            context.l10n.aboutVersion(info.version, info.buildNumber),
            key: HomeKeys.version,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: AppColors.textDim),
          ),
        );
      },
    );
  }
}

/// 音频片段的开关。
///
/// 默认开着——否则"试听这一晚的鼾声"这个功能等于不存在。但必须显眼、
/// 必须能一键关掉，并且说清楚关掉之后会失去什么、开着会占多少空间。
class _ClipRecordingCard extends StatelessWidget {
  const _ClipRecordingCard({required this.viewModel});

  final RecordingViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = viewModel.recordClips;

    return SectionCard(
      title: context.l10n.clipCardTitle,
      subtitle: context.l10n.clipCardSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: enabled,
            onChanged: (v) => viewModel.setRecordClips(v),
            title: Text(
              enabled ? context.l10n.clipOn : context.l10n.clipOff,
              style: theme.textTheme.bodyMedium,
            ),
            subtitle: Text(
              enabled
                  ? context.l10n.clipOnSubtitle
                  : context.l10n.clipOffSubtitle,
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.textDim,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            enabled ? context.l10n.clipOnBody : context.l10n.clipOffBody,
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

/// 安静段跳过（能量门控）开关。
///
/// ## 为什么这个开关的文案是警告式的
///
/// 因为它的下限是**硬编码**的：阈值再怎么自适应，也不会低于 `vadRms / 4`。
/// 而真实录音里，手机放得远、隔着被子时，鼾声的峰值 RMS 可以低到 0.0016
/// ——就在那条线之下。打开它，那些夜晚会**整晚被跳过，一个事件都不产生**，
/// 而界面上不会报错，报告只会是空的。
///
/// 所以文案不是"省电小技巧"，是"开之前先看一眼电平条"。
class _VadCard extends StatefulWidget {
  const _VadCard({required this.viewModel});

  final RecordingViewModel viewModel;

  @override
  State<_VadCard> createState() => _VadCardState();
}

class _VadCardState extends State<_VadCard> {
  /// 拖动滑块时的临时值。
  ///
  /// ⚠️ 不能每一帧都调 `setVadThresholdDb`：那会**每帧写一次数据库**，
  /// 引擎也会被反复重调。松手（`onChangeEnd`）才落定——和波形的播放头
  /// 一个道理。
  double? _dragDb;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final vm = widget.viewModel;
    final enabled = vm.vadEnabled;
    final shownDb = _dragDb ?? vm.vadThresholdDb.toDouble();

    return SectionCard(
      title: context.l10n.vadCardTitle,
      subtitle: context.l10n.vadCardSubtitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: enabled,
            onChanged: (v) => vm.setVadEnabled(v),
            title: Text(
              enabled ? context.l10n.vadOn : context.l10n.vadOff,
              style: theme.textTheme.bodyMedium,
            ),
            subtitle: Text(
              enabled ? context.l10n.vadOnSubtitle : context.l10n.vadOffSubtitle,
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.textDim,
              ),
            ),
          ),
          if (enabled) ...[
            const SizedBox(height: 8),
            const Divider(height: 1),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    context.l10n.vadThresholdLabel,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                Text(
                  context.l10n.vadThresholdValue(shownDb.round()),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            Slider(
              value: shownDb.clamp(
                kVadThresholdDbMin.toDouble(),
                kVadThresholdDbMax.toDouble(),
              ),
              min: kVadThresholdDbMin.toDouble(),
              max: kVadThresholdDbMax.toDouble(),
              divisions: kVadThresholdDbMax - kVadThresholdDbMin,
              label: '${shownDb.round()}',
              onChanged: (v) => setState(() => _dragDb = v.roundToDouble()),
              onChangeEnd: (v) {
                setState(() => _dragDb = null);
                vm.setVadThresholdDb(v.round());
              },
            ),
            Text(
              context.l10n.vadThresholdHint,
              style: theme.textTheme.labelSmall?.copyWith(
                color: AppColors.textDim,
                height: 1.6,
              ),
            ),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          Text(
            enabled ? context.l10n.vadOnBody : context.l10n.vadOffBody,
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

/// 语言选择。
///
/// 为什么要这个开关：App 默认跟随系统语言，而**想试另一种语言就得改整个
/// 手机的系统语言**——那个代价跟"看一下界面长什么样"完全不成比例。
/// 这个开关只是给那种场合用的覆盖手段，所以默认项必须是「跟随系统」。
class _LanguageCard extends StatelessWidget {
  const _LanguageCard({required this.controller});

  final LocaleController controller;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // RadioListTile 的 groupValue 用 languageCode 比较，
    // null（跟随系统）单独用一个哨兵值，免得和"没选中"撞上。
    const system = 'system';
    final current = controller.locale?.languageCode ?? system;

    Widget option(String value, String label) => RadioListTile<String>(
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: value,
      title: Text(label, style: theme.textTheme.bodyMedium),
    );

    return SectionCard(
      title: context.l10n.languageTitle,
      subtitle: context.l10n.languageSubtitle,
      child: RadioGroup<String>(
        groupValue: current,
        onChanged: (v) =>
            controller.setLocale(v == null || v == system ? null : Locale(v)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            option(system, context.l10n.languageSystem),
            option('zh', context.l10n.languageChinese),
            option('en', context.l10n.languageEnglish),
          ],
        ),
      ),
    );
  }
}
