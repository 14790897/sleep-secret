import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/data/models/audioset_zh.dart';

/// 527 个 AudioSet 标签的中文对照。
///
/// ⚠️ **这个文件是这批中文的唯一防线。** 那张表是**手写**的——
/// 527 条，一条一条对着 AudioSet 的清单填。写错一个键，那一行就静默退回英文；
/// 漏掉一条，那一行也是静默退回英文。两种都不会报错、不会崩、界面上只是
/// 「少了个中文」，靠肉眼翻 527 行是看不出来的。
///
/// 所以这里**直接比对真实的映射表**：键集合必须和 `id2label` 完全相等。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Set<String> id2labels;
  late Map<String, String> zh;

  setUpAll(() async {
    final raw =
        await rootBundle.loadString('assets/models/sleep_class_map.json');
    id2labels = ((jsonDecode(raw) as Map<String, dynamic>)['id2label']
            as Map<String, dynamic>)
        .values
        .cast<String>()
        .toSet();
    zh = await loadAudioSetZh();
  });

  group('audioset_zh.json', () {
    test('真读得出来，而且是 527 条', () async {
      expect(zh, hasLength(527));
      expect(id2labels, hasLength(527));
    });

    test('每个 AudioSet 标签都有中文——一个不落', () {
      final missing = id2labels.difference(zh.keys.toSet()).toList()..sort();
      expect(
        missing,
        isEmpty,
        reason: '这些标签没有中文对照，界面上会静默显示成英文：$missing',
      );
    });

    test('没有多余的键——写了中文的标签必须真的存在', () {
      final extra = zh.keys.toSet().difference(id2labels).toList()..sort();
      expect(
        extra,
        isEmpty,
        reason: '这些键在映射表里不存在，八成是拼错了：$extra',
      );
    });

    test('没有空的中文', () {
      final blank = zh.entries.where((e) => e.value.trim().isEmpty).toList();
      expect(blank, isEmpty, reason: '空值会让那一行看起来像没翻译：$blank');
    });

    test('中文里不该混进英文——那是漏翻的样子（少数专名除外）', () {
      // 允许留下拉丁字母的只有几个专名/缩写：约德尔、特雷门、铁克诺、
      // 浩室、斯卡、萨尔萨、塔布拉、颂钵这类音译其实都是中文，
      // 真正该留英文的只有「DTMF」这种。这里只查**整条都是 ASCII**
      // 的情况——那一定是漏翻了。
      final ascii = zh.entries
          .where((e) => e.value.codeUnits.every((c) => c < 128))
          .map((e) => '${e.key} -> ${e.value}')
          .toList();
      expect(ascii, isEmpty, reason: '这些都还是英文：$ascii');
    });

    test('抽查几条：关键的那几个必须译对', () {
      // 这几条是 App 到处在用的（信号、大类名、对照组的原始标签），
      // 译错了界面上的说法会和别处对不上。
      expect(zh['Snoring'], '鼾声');
      expect(zh['Gasp'], '倒吸气');
      expect(zh['Sniff'], '吸鼻子');
      expect(zh['Silence'], '静音');
      expect(zh['Crowing, cock-a-doodle-doo'], '公鸡打鸣');
      expect(zh['Mains hum'], '市电嗡鸣');
    });

    test('同一个中文不重复太多——大面积的重复多半是复制粘贴错了', () {
      // 允许少量重复（「走路、脚步」和「脚步」这种本来就近义），
      // 但**大面积**重复说明有整段复制没改。
      final byValue = <String, List<String>>{};
      for (final e in zh.entries) {
        byValue.putIfAbsent(e.value, () => []).add(e.key);
      }
      final dup = byValue.entries.where((e) => e.value.length > 2).toList();
      expect(
        dup,
        isEmpty,
        reason: '这些中文被三个以上标签共用，八成是复制粘贴：$dup',
      );
    });
  });
}
