import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/recording_diagnosis.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';

/// 造一个只有统计、没有事件的会话。诊断只看 [SessionStats]。
RecordingSession sessionWith({
  double analyzedSeconds = 8 * 3600,
  int windowsTotal = 9600,
  int windowsInferred = 3000,
  int? windowsVadSkipped,
  int windowsLowConfidence = 1200,
  int eventCount = 12,
  double snoreSeconds = 0,
}) =>
    RecordingSession(
      id: 1,
      startedAt: DateTime(2026, 10, 6, 23),
      endedAt: DateTime(2026, 10, 6, 23).add(Duration(seconds: analyzedSeconds.round())),
      events: const <SoundEvent>[],
      stats: SessionStats(
        analyzedSeconds: analyzedSeconds,
        windowsTotal: windowsTotal,
        windowsInferred: windowsInferred,
        windowsVadSkipped:
            windowsVadSkipped ?? (windowsTotal - windowsInferred),
        windowsLowConfidence: windowsLowConfidence,
        eventCount: eventCount,
        snoreEventCount: 0,
        snoreSeconds: snoreSeconds,
        categoryDistribution: const <SleepCategory, double>{},
      ),
    );

/// 按**是哪一条**找，不按标题文字找。
///
/// 加多语言之后 `Diagnosis` 不再自带句子（那是界面层按语言渲染的），
/// 所以「有没有报这一条」只能靠 kind 判断——这也本来就是这条测试该问的问题。
Diagnosis? find(List<Diagnosis> list, DiagnosisKind kind) {
  for (final d in list) {
    if (d.kind == kind) return d;
  }
  return null;
}

void main() {
  group('正常的一夜不该报任何警告', () {
    test('有声音、有事件、比例正常', () {
      final out = diagnoseSession(sessionWith());
      expect(hasWarnings(out), isFalse,
          reason: '数据都正常时不该给用户制造焦虑，实际: '
              '${out.map((d) => d.kind).toList()}');
    });

    test('很安静的一夜也不该报警告', () {
      // 送进模型的窗口少，但确实有在分析——这是安静，不是故障
      final out = diagnoseSession(sessionWith(
        windowsTotal: 9600,
        windowsInferred: 300,
        windowsLowConfidence: 100,
        eventCount: 1,
      ));
      expect(hasWarnings(out), isFalse);
    });
  });

  group('整晚没触发分析', () {
    test('一个窗口都没进模型 —— 这是最要命的情况', () {
      final out = diagnoseSession(sessionWith(
        windowsInferred: 0,
        windowsLowConfidence: 0,
        eventCount: 0,
      ));

      final d = find(out, DiagnosisKind.noInference);
      expect(d, isNotNull);
      expect(d!.level, DiagnosisLevel.warning);
      // 报告是空的，但原因不是"我没打鼾"——这条诊断存在的全部意义就是
      // 把这个区别做出来。按 kind 找到它，就已经证明了这一点。
      //
      // ⚠️ 原先这里还断言了文案里有没有"挡住"两个字。加多语言之后，
      // 具体的措辞归 ARB 管（`diagnosisNoInferenceDetail`），领域层只说
      // "报了哪一条"。措辞本身由 `localization_test` 的对 key 那条守着。
    });

    test('只有 1% 的窗口进了模型', () {
      final out = diagnoseSession(sessionWith(
        windowsTotal: 9600,
        windowsInferred: 96,
        eventCount: 0,
      ));
      expect(find(out, DiagnosisKind.tooFewInferred)?.level, DiagnosisLevel.warning);
    });

    test('触发率 5% 不报——留够余量，不制造误报', () {
      final out = diagnoseSession(sessionWith(
        windowsTotal: 9600,
        windowsInferred: 480,
        windowsLowConfidence: 100,
      ));
      expect(find(out, DiagnosisKind.tooFewInferred), isNull);
    });
  });

  group('有声音但认不出来', () {
    test('整晚大部分时间都有声音、且几乎都认不出', () {
      final out = diagnoseSession(sessionWith(
        windowsTotal: 9600,
        windowsInferred: 8000, // 83% 的窗口越过门控 —— 整晚很吵
        windowsLowConfidence: 7600,
      ));
      final d = find(out, DiagnosisKind.lowConfidence);
      expect(d?.level, DiagnosisLevel.warning);
      // 原先断言文案里给了"风扇"这个最可能的原因。那种措辞上的要求在
      // ARB 里（`diagnosisLowConfidenceDetail`），这里只保证报了这条。
    });

    test('安静的一夜低置信度也很高，但这不是异常', () {
      // 实测：安静房间里 VAD 只放行零星几声，模型对这几声自然没把握，
      // 比例能到 90% 以上。这是正常结果，报出来只会吓人。
      final out = diagnoseSession(sessionWith(
        windowsTotal: 9600,
        windowsInferred: 300, // 只有 3% 的窗口有声音
        windowsLowConfidence: 290, // 但其中 97% 没把握
        eventCount: 1,
      ));
      expect(find(out, DiagnosisKind.lowConfidence), isNull,
          reason: '低置信度比例高本身不是问题——只有"整晚都吵"才是');
    });

    test('样本太少时不下结论', () {
      final out = diagnoseSession(sessionWith(
        windowsTotal: 200,
        windowsInferred: 200,
        windowsLowConfidence: 200,
        analyzedSeconds: 10 * 60,
      ));
      expect(find(out, DiagnosisKind.lowConfidence), isNull,
          reason: '样本不足时下结论比不下更糟');
    });
  });

  group('鼾声占比', () {
    test('超过一半时间判定为鼾声 —— 多半是把持续噪声听成了鼾声', () {
      // 刻意不用 62.5% 这类落在四舍五入边界上的值，免得测的是舍入而不是逻辑
      final out = diagnoseSession(sessionWith(
        analyzedSeconds: 8 * 3600,
        snoreSeconds: 0.65 * 8 * 3600,
      ));
      final d = find(out, DiagnosisKind.snoreRatioHigh);
      expect(d?.level, DiagnosisLevel.warning);
      // 这个数是这条诊断的关键——它要出现在**标题**里，用户第一眼就看到。
      // 断言的是数值，不是"标题字符串里有没有 65%"：措辞归 ARB。
      expect(d!.params['percent'], closeTo(65, 1));
    });

    test('占比 30% 不报', () {
      final out = diagnoseSession(sessionWith(
        analyzedSeconds: 8 * 3600,
        snoreSeconds: 0.3 * 8 * 3600,
      ));
      expect(find(out, DiagnosisKind.snoreRatioHigh), isNull);
    });
  });

  group('短录音', () {
    // 「录音太短」这件事刻意不在这里报——评分仪表已经在说了，
    // 而且时长门槛是同一个，两者必然同时出现，重复说只是噪音。
    // 这里验证的是：短录音不该套用整夜性质的判断。
    test('20 分钟、一个窗口没进模型 —— 这是"太短"而不是"麦克风坏了"', () {
      final out = diagnoseSession(sessionWith(
        analyzedSeconds: 20 * 60,
        windowsTotal: 400,
        windowsInferred: 0,
        windowsLowConfidence: 0,
        eventCount: 0,
      ));
      expect(find(out, DiagnosisKind.noInference), isNull,
          reason: '整夜性质的判断不该套用在 20 分钟的录音上——'
              '短录音本来就可能什么都还没发生');
    });

    test('短录音不报鼾声占比异常', () {
      final out = diagnoseSession(sessionWith(
        analyzedSeconds: 20 * 60,
        windowsTotal: 400,
        windowsInferred: 200,
        snoreSeconds: 15 * 60, // 75%
      ));
      expect(find(out, DiagnosisKind.snoreRatioHigh), isNull);
    });
  });

  group('边界', () {
    test('完全没有窗口时只返回时长短的提示，不崩', () {
      final out = diagnoseSession(sessionWith(
        analyzedSeconds: 0,
        windowsTotal: 0,
        windowsInferred: 0,
        windowsLowConfidence: 0,
        eventCount: 0,
      ));
      expect(out, isEmpty);
    });

    test('有窗口进模型但零事件 —— 是陈述不是警告', () {
      final out = diagnoseSession(sessionWith(
        windowsInferred: 3000,
        windowsLowConfidence: 500,
        eventCount: 0,
      ));
      final d = find(out, DiagnosisKind.noEvents);
      expect(d?.level, DiagnosisLevel.info,
          reason: '安静的一夜本来就可能没有事件，不该报警告');
    });
  });
}
