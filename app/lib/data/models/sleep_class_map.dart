import 'dart:convert';

import 'package:flutter/foundation.dart' show compute;

import '../../domain/models/sleep_category.dart';

/// `assets/models/sleep_class_map.json` 的内存表示。
///
/// 该文件由 `ml/sleep_classes.py` 生成，定义 AudioSet 527 细类
/// 到 7 个睡眠大类的聚合关系。
class SleepClassMap {
  const SleepClassMap({
    required this.modelName,
    required this.numClasses,
    required this.labels,
    required this.categoryIndices,
    required this.snoreIndices,
  });

  final String modelName;
  final int numClasses;

  /// AudioSet 527 个标签名，下标即标签索引。
  final List<String> labels;

  /// 每个大类对应的 AudioSet 标签索引。
  final Map<SleepCategory, List<int>> categoryIndices;

  /// 其中的 Snoring 类索引，单独拎出来方便算鼾声指数。
  final List<int> snoreIndices;

  /// 按索引取标签名，越界返回占位符（而不是抛异常——诊断展示不该因此崩掉）。
  String labelOf(int index) =>
      (index >= 0 && index < labels.length) ? labels[index] : 'unknown($index)';

  /// 中文大类名 -> 枚举。名字对不上说明映射表和代码不同步，必须报错而不是兜底。
  static const Map<String, SleepCategory> _byLabel = {
    '鼾声': SleepCategory.snore,
    '呼吸声': SleepCategory.breathing,
    '咳嗽清嗓': SleepCategory.cough,
    '人声梦话': SleepCategory.vocal,
    '体动床响': SleepCategory.movement,
    '环境噪音': SleepCategory.ambient,
    '静音': SleepCategory.silence,
  };

  /// 解析 JSON。字段缺失或类型不符直接抛 [FormatException]。
  factory SleepClassMap.fromJson(Map<String, dynamic> json) {
    final rawCategories = json['categories'];
    final rawId2Label = json['id2label'];
    if (rawCategories is! Map || rawId2Label is! Map) {
      throw const FormatException('sleep_class_map.json 缺少 categories 或 id2label');
    }

    final indices = <SleepCategory, List<int>>{};
    for (final entry in rawCategories.entries) {
      final category = _byLabel[entry.key];
      if (category == null) {
        throw FormatException('未知的睡眠大类: ${entry.key}');
      }
      final value = entry.value;
      if (value is! List) {
        throw FormatException('${entry.key} 的索引不是数组');
      }
      indices[category] = value.cast<int>();
    }

    for (final category in SleepCategory.values) {
      if (!indices.containsKey(category)) {
        throw FormatException('映射表缺少大类: ${category.label}');
      }
    }

    final coreSnore = json['core_snore'];
    return SleepClassMap(
      modelName: json['model'] as String? ?? 'unknown',
      numClasses: json['num_classes'] as int? ?? rawId2Label.length,
      labels: _labelsFrom(rawId2Label),
      categoryIndices: indices,
      snoreIndices:
          coreSnore is List ? coreSnore.cast<int>() : indices[SleepCategory.snore]!,
    );
  }

  /// id2label 的 key 是字符串形式的索引，按索引序排成列表。
  static List<String> _labelsFrom(Map<dynamic, dynamic> id2Label) {
    final pairs = <int, String>{};
    for (final entry in id2Label.entries) {
      final index = int.tryParse('${entry.key}');
      final label = entry.value;
      if (index == null || label is! String) {
        throw FormatException('id2label 含非法条目: ${entry.key} -> ${entry.value}');
      }
      pairs[index] = label;
    }
    if (pairs.isEmpty) {
      throw const FormatException('id2label 为空');
    }
    final size = pairs.keys.reduce((a, b) => a > b ? a : b) + 1;
    final labels = List<String>.filled(size, '', growable: false);
    for (var i = 0; i < size; i++) {
      final label = pairs[i];
      if (label == null) {
        throw FormatException('id2label 缺少索引 $i');
      }
      labels[i] = label;
    }
    return labels;
  }

  Map<String, dynamic> toJson() => {
        'model': modelName,
        'num_classes': numClasses,
        'categories': {
          for (final entry in categoryIndices.entries) entry.key.label: entry.value,
        },
        'core_snore': snoreIndices,
        'id2label': {
          for (var i = 0; i < labels.length; i++) '$i': labels[i],
        },
      };
}

/// 在后台 isolate 解析映射表（顶层函数，[compute] 要求可跨 isolate 传递）。
///
/// 返回 [SleepClassMap] 而非 Map：只在 isolate 内部用 Map，避免把
/// 无法跨 isolate 传递的类型带出来。
SleepClassMap parseSleepClassMap(String jsonString) {
  final decoded = jsonDecode(jsonString);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('sleep_class_map.json 顶层不是 JSON 对象');
  }
  return SleepClassMap.fromJson(decoded);
}

/// 便捷入口：从 JSON 字符串解析，大文件走后台 isolate。
///
/// 映射表约 15KB，主线程解析通常也在 16ms 内，但这里仍走 [compute]
/// 以免未来类别表增大时卡 UI。
Future<SleepClassMap> decodeSleepClassMap(String jsonString) =>
    compute(parseSleepClassMap, jsonString);
