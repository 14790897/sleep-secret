import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/models/sleep_class_map.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';

/// 一份最小合法映射表，用于构造各种畸形输入。
Map<String, dynamic> validJson() => {
      'model': 'test-model',
      'num_classes': 3,
      'categories': {
        '鼾声': [0],
        '呼吸声': [1],
        '咳嗽清嗓': [2],
        '人声梦话': [0],
        '体动床响': [1],
        '环境噪音': [2],
        '静音': [0],
      },
      'core_snore': [0],
      'id2label': {'0': 'Snoring', '1': 'Breathing', '2': 'Cough'},
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SleepClassMap', () {
    test('解析合法映射表', () {
      final map = SleepClassMap.fromJson(validJson());

      expect(map.modelName, 'test-model');
      expect(map.numClasses, 3);
      expect(map.categoryIndices[SleepCategory.snore], [0]);
      expect(map.categoryIndices[SleepCategory.silence], [0]);
      expect(map.snoreIndices, [0]);
    });

    test('labels 按索引顺序还原，labelOf 可查', () {
      final map = SleepClassMap.fromJson(validJson());

      expect(map.labels, ['Snoring', 'Breathing', 'Cough']);
      expect(map.labelOf(1), 'Breathing');
      // 越界返回占位符，不抛异常——诊断展示不该因此崩掉
      expect(map.labelOf(99), 'unknown(99)');
    });

    test('缺少 categories 时抛 FormatException', () {
      final json = validJson()..remove('categories');
      expect(() => SleepClassMap.fromJson(json), throwsFormatException);
    });

    test('出现未知大类名时抛 FormatException', () {
      final json = validJson();
      (json['categories'] as Map)['打呼噜'] = [0];
      expect(() => SleepClassMap.fromJson(json), throwsFormatException);
    });

    test('缺少某个必需大类时抛 FormatException', () {
      final json = validJson();
      (json['categories'] as Map).remove('静音');
      expect(() => SleepClassMap.fromJson(json), throwsFormatException);
    });

    test('id2label 索引不连续时抛 FormatException', () {
      final json = validJson();
      json['id2label'] = {'0': 'Snoring', '2': 'Cough'};
      expect(() => SleepClassMap.fromJson(json), throwsFormatException);
    });

    test('toJson 可往返', () {
      final map = SleepClassMap.fromJson(validJson());
      final round = SleepClassMap.fromJson(map.toJson());

      expect(round.categoryIndices, map.categoryIndices);
      expect(round.snoreIndices, map.snoreIndices);
      expect(round.labels, map.labels);
    });
  });

  group('真实资源文件', () {
    test('assets/models/sleep_class_map.json 能被解析且覆盖全部 7 大类', () async {
      final raw = await rootBundle.loadString('assets/models/sleep_class_map.json');
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final map = SleepClassMap.fromJson(decoded);

      expect(map.numClasses, 527);
      expect(map.labels.length, 527);
      for (final category in SleepCategory.values) {
        expect(
          map.categoryIndices[category],
          isNotEmpty,
          reason: '${category.label} 不应为空',
        );
      }
      // Snoring 是 AudioSet 第 43 号标签，类别映射必须落在它上面
      expect(map.snoreIndices, contains(43));
      expect(map.labelOf(43), 'Snoring');
      expect(map.labelOf(500), 'Silence');
    });
  });
}
