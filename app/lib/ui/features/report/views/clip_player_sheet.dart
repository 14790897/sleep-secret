import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../../data/services/event_player.dart';
import '../../../../data/services/wav_decoder_service.dart';
import '../../../core/l10n/l10n_context.dart';
import '../../../core/theme.dart';
import '../../../core/widgets/clip_waveform.dart';

/// 弹出片段播放面板。返回时面板已经把播放停掉了。
///
/// ## 为什么要有这个面板（而不是把播放按钮留在列表里）
///
/// 报告里的片段是**摘录**：`AnalysisConfig.maxClipSeconds` 封顶 20 秒，
/// 而列表里那个数字是**事件本身**的时长，可以到几分钟。两者差着一个数量级，
/// 不摆出来就是误导——用户会想"明明写着 43 秒，怎么只响了几秒"。
/// 面板上「0:07 / 0:20」加上事件总长，这件事就不言自明了。
///
/// 波形和进度条还有第二个用处：一句鼾声里真正有听头的就是中间那几下，
/// 能拖回去反复听，比从头放一遍有用得多。
Future<void> showClipPlayer(
  BuildContext context, {
  required EventPlayer player,
  required String clipPath,
  required String title,
  required double eventSeconds,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
    ),
    builder: (_) => ClipPlayerSheet(
      player: player,
      clipPath: clipPath,
      title: title,
      eventSeconds: eventSeconds,
    ),
  );
}

class ClipPlayerSheet extends StatefulWidget {
  const ClipPlayerSheet({
    super.key,
    required this.player,
    required this.clipPath,
    required this.title,
    required this.eventSeconds,
  });

  final EventPlayer player;
  final String clipPath;

  /// 面板标题，比如「03:09 · 鼾声」。
  final String title;

  /// **事件**的时长（秒）。用来解释片段为什么比它短。
  final double eventSeconds;

  @override
  State<ClipPlayerSheet> createState() => _ClipPlayerSheetState();
}

class _ClipPlayerSheetState extends State<ClipPlayerSheet> {
  final _decoder = const WavDecoderService();

  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<bool>? _playingSub;

  List<WaveformPeak> _peaks = const [];
  Duration _clipDuration = Duration.zero;
  Duration _position = Duration.zero;
  bool _playing = false;
  bool _unreadable = false;

  @override
  void initState() {
    super.initState();
    _playingSub = widget.player.playingStream.listen((playing) {
      if (mounted) setState(() => _playing = playing);
    });
    _positionSub = widget.player.positionStream.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final bytes = await File(widget.clipPath).readAsBytes();
      final audio = _decoder.decode(bytes);
      if (!mounted) return;
      setState(() {
        _peaks = waveformPeaks(audio.samples);
        _clipDuration = Duration(
          milliseconds: (audio.durationSeconds * 1000).round(),
        );
      });
    } catch (_) {
      // 文件被删了（删掉那一晚的记录）或者读坏了：面板照常开，但要说清楚，
      // 而不是给一条平线让人以为"这段没声音"。
      //
      // ⚠️ 这里**不停播放**：读不出来只说明 Dart 这边的解码器吃不下它，
      // 而真正出声的是平台的解码器，两者不是一回事。真放不出来，
      // playingStream 自己会变回 false。
      if (!mounted) return;
      setState(() => _unreadable = true);
    }
  }

  @override
  void dispose() {
    _positionSub?.cancel();
    _playingSub?.cancel();
    // 关面板就停——不然声音会在用户已经离开这一屏之后继续响
    unawaited(widget.player.stop());
    super.dispose();
  }

  double get _progress {
    final total = _clipDuration.inMilliseconds;
    if (total <= 0) return 0;
    return (_position.inMilliseconds / total).clamp(0.0, 1.0);
  }

  String _mmss(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  /// 播放的是这一段**末尾**的摘录（见 [AnalysisConfig.clipRangeFor]），
  /// 所以只有事件明显更长时才解释，免得短事件上多一句废话。
  bool get _isExcerpt =>
      widget.eventSeconds > _clipDuration.inMilliseconds / 1000 + 1.5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodySmall?.copyWith(color: AppColors.textDim);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 顶上那道小横条：告诉用户这是一个可以下拉关掉的面板
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),

            Row(
              children: [
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close),
                  tooltip: context.l10n.clipPlayerClose,
                ),
              ],
            ),
            const SizedBox(height: 4),

            if (_unreadable)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  context.l10n.clipPlayerUnreadable,
                  style: theme.textTheme.bodyMedium
                      ?.copyWith(color: AppColors.statusWarning),
                ),
              )
            else ...[
              ClipWaveform(
                peaks: _peaks,
                progress: _progress,
                onSeek: (fraction) {
                  final target = Duration(
                    milliseconds: (_clipDuration.inMilliseconds * fraction)
                        .round(),
                  );
                  setState(() => _position = target);
                  unawaited(widget.player.seek(target));
                },
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  IconButton.filled(
                    onPressed: _toggle,
                    icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                  ),
                  const SizedBox(width: 12),
                  // 这里两个数字就是**这一段的真实长度**，不是事件的。
                  // 「显示几十秒、实际只响几秒」那个误会，根子就在
                  // 列表里那个数字是事件的时长。
                  Text(
                    '${_mmss(_position)} / ${_mmss(_clipDuration)}',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              if (_isExcerpt) ...[
                const SizedBox(height: 6),
                Text(
                  context.l10n.clipPlayerExcerpt(
                    widget.eventSeconds.round(),
                    _clipDuration.inSeconds,
                  ),
                  style: dim?.copyWith(height: 1.5),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  void _toggle() {
    if (_playing) {
      unawaited(widget.player.pause());
    } else {
      // 已经放完的话从头再来，否则 resume 会停在末尾一动不动
      if (_clipDuration > Duration.zero && _position >= _clipDuration) {
        unawaited(widget.player.seek(Duration.zero));
      }
      unawaited(widget.player.resume());
    }
  }
}
