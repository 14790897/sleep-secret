/// 527 个 AudioSet 标签的中文对照（`assets/models/audioset_zh.json`）。
///
/// ## 为什么它不是 i18n 资源
///
/// 界面文案走 ARB——那套东西是给**按钮、标题、句子**用的。这 527 条是
/// **AudioSet 的分类体系**，是数据：它们跟着模型走，不随界面文案改；
/// 而且**只有中文**——英文界面里这些标签本来就是英文，不需要对照。
/// 塞进 ARB 只会把一份词表混进 UI 文案里。
///
/// 它是给报告页那张「详细视图」用的：那一列是**模型的原话**（英文，
/// 那正是核查要看的东西），中文界面下再给一个看得懂的说法。
library;

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

Future<Map<String, String>>? _cached;

/// 读一次就缓存住。
///
/// 读坏了返回空表而不是抛异常：这张表是**补充信息**，
/// 缺了它那一列退回只显示英文就够了，不该让整份报告打不开。
/// （真有缺漏由 `test/data/audioset_zh_test.dart` 拦——
/// 那条测试直接比对真实映射表，所以这个兜底不会掩盖真问题。）
Future<Map<String, String>> loadAudioSetZh() {
  return _cached ??= rootBundle
      .loadString('assets/models/audioset_zh.json')
      .then(
        (raw) => {
          for (final e in (jsonDecode(raw) as Map<String, dynamic>).entries)
            e.key: e.value as String,
        },
      )
      .catchError((Object _) => <String, String>{});
}
