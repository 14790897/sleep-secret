import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

/// PC 端跑出的单段期望值。
class ExpectedClip {
  const ExpectedClip({required this.logits, required this.durationSeconds});

  final List<double> logits;
  final double durationSeconds;
}

/// PC 端期望值的来源。
///
/// 抽出来是为了让诊断页的 ViewModel 不直接依赖 rootBundle —— 否则
/// 单元测试里 await 真实 asset I/O 会卡死（Flutter 测试的 FakeAsync 时区
/// 不会推进真实 I/O），同时 ViewModel 也不该知道 asset 路径。
abstract interface class DiagnosticFixtures {
  /// 返回 `assetKey -> 期望值`。文件缺失时返回空表，不抛异常。
  Future<Map<String, ExpectedClip>> loadExpectedClips();
}

/// 从打包进 App 的 `assets/testdata/expected.json` 读取。
class AssetDiagnosticFixtures implements DiagnosticFixtures {
  const AssetDiagnosticFixtures({
    this.expectedAsset = 'assets/testdata/expected.json',
  });

  final String expectedAsset;

  @override
  Future<Map<String, ExpectedClip>> loadExpectedClips() async {
    final raw = await rootBundle.loadString(expectedAsset);
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('expected.json 顶层不是 JSON 对象');
    }
    final clips = decoded['clips'];
    if (clips is! Map<String, dynamic>) {
      throw const FormatException('expected.json 缺少 clips');
    }

    final out = <String, ExpectedClip>{};
    for (final entry in clips.entries) {
      final fixture = entry.value;
      if (fixture is! Map<String, dynamic>) continue;
      final logits = fixture['logits'];
      if (logits is! List) continue;
      out['assets/testdata/${entry.key}.wav'] = ExpectedClip(
        logits: logits.map((e) => (e as num).toDouble()).toList(growable: false),
        durationSeconds: (fixture['duration_sec'] as num?)?.toDouble() ?? 0,
      );
    }
    return out;
  }
}
