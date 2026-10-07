import 'package:flutter/material.dart';

import '../../../../domain/models/recording_session.dart';
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
    RecordingSession session);

/// 应用外壳：底部导航 + 三个页面。
class HomeView extends StatefulWidget {
  const HomeView({
    super.key,
    required this.recordingViewModel,
    required this.reportViewModelFactory,
  });

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
              RecordingView(viewModel: widget.recordingViewModel, embedded: true),
              _ReportListView(
                viewModel: widget.recordingViewModel,
                reportViewModelFactory: widget.reportViewModelFactory,
              ),
              _AboutView(viewModel: widget.recordingViewModel),            ],
          ),
          bottomNavigationBar: NavigationBar(
            selectedIndex: _tab,
            onDestinationSelected: (i) => setState(() => _tab = i),
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.mic_none),
                selectedIcon: Icon(Icons.mic),
                label: '睡眠',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: widget.recordingViewModel.sessions.isNotEmpty,
                  label: Text('${widget.recordingViewModel.sessions.length}'),
                  child: const Icon(Icons.bar_chart_outlined),
                ),
                selectedIcon: const Icon(Icons.bar_chart),
                label: '报告',
              ),
              const NavigationDestination(
                icon: Icon(Icons.info_outline),
                selectedIcon: Icon(Icons.info),
                label: '关于',
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
      appBar: AppBar(title: const Text('睡眠报告')),
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
                        child: Text('历史记录',
                            style: Theme.of(context).textTheme.titleSmall),
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
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ReportView(viewModel: reportVm)),
    );
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
            Icon(Icons.nightlight_outlined,
                size: 56, color: AppColors.textDim.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text('还没有睡眠报告', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '到「睡眠」页点开始录音，\n第二天早上这里就会出现这一晚的分析。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: AppColors.textDim, height: 1.6),
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
                      '${started.month}月${started.day}日  '
                      '${started.hour.toString().padLeft(2, '0')}:'
                      '${started.minute.toString().padLeft(2, '0')}',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '鼾声 ${s.snoreEventCount} 段 · ${formatSpan(s.snoreSeconds)}'
                      ' · ${s.eventCount} 个事件',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: AppColors.textDim),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                color: AppColors.textDim,
                tooltip: '删除',
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
        title: const Text('删除这条记录？'),
        content: const Text('删除后无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
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

/// 关于页：说明 App 做什么、不做什么，以及音频片段的隐私开关。
class _AboutView extends StatelessWidget {
  const _AboutView({required this.viewModel});

  final RecordingViewModel viewModel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListenableBuilder(
        listenable: viewModel,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            SectionCard(
              title: '这个应用做什么',
              child: Text(
                '整夜录音，在手机本地识别睡眠中的声音类型——鼾声、呼吸声、'
                '咳嗽、梦话、翻身、环境噪音——并生成一晚的时间线和统计。',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.7),
              ),
            ),
            const SizedBox(height: 12),
            _ClipRecordingCard(viewModel: viewModel),
            const SizedBox(height: 12),
            SectionCard(
              title: '数据不出手机',
              subtitle: '所有分析都在设备本地完成',
              child: Text(
                '录音不会上传。原始音频在分析后即丢弃，只保留事件的时间点、'
                '类别，以及（如果你开着上面的开关）鼾声片段。',
                style: theme.textTheme.bodySmall?.copyWith(height: 1.7),
              ),
            ),
            const SizedBox(height: 12),
            SectionCard(
              title: '它不是什么',
              child: Text(
                '不是医疗器械，不能用于诊断睡眠呼吸暂停或其他疾病。'
                '识别结果来自通用的音频事件模型，没有针对你本人做过校准。'
                '身体不适请就医。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(height: 1.7, color: AppColors.textDim),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.cloud_upload_outlined,
                    color: AppColors.accent),
                title: const Text('数据导出'),
                subtitle: Text('导出到网盘同步目录，换设备可以再导回来',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.textDim)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(
                  ArchiveView.routeName,
                ),
              ),
            ),
            const SizedBox(height: 12),
            Card(
              child: ListTile(
                leading: const Icon(Icons.memory, color: AppColors.accent),
                title: const Text('端侧推理诊断'),
                subtitle: Text('开发者选项：验证模型加载与推理',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: AppColors.textDim)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).pushNamed(
                  DiagnosticView.routeName,
                ),
              ),
            ),
          ],
        ),
      ),
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
      title: '录音片段',
      subtitle: '为鼾声事件保留一段可回放的音频',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: enabled,
            onChanged: (v) => viewModel.setRecordClips(v),
            title: Text(enabled ? '保留鼾声片段' : '不保留任何音频',
                style: theme.textTheme.bodyMedium),
            subtitle: Text(
              enabled
                  ? '每晚约几 MB，存在应用私有目录里'
                  : '分析完即丢弃，历史记录里无法试听',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: AppColors.textDim),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            enabled
                ? '只会保留鼾声，不会保留梦话等其他声音。片段存在应用私有目录，'
                    '其他应用读不到；删除某晚记录时会连同片段一起删掉。'
                : '关掉之后 App 不写出任何音频文件，只保留事件的时间点和类别。',
            style: theme.textTheme.labelSmall
                ?.copyWith(color: AppColors.textDim, height: 1.6),
          ),
        ],
      ),
    );
  }
}
