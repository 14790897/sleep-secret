import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/apnea_signals.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';

SoundEvent ev({
  required String? signal,
  double start = 0,
  SleepCategory label = SleepCategory.breathing,
}) =>
    SoundEvent(
      label: label,
      startSeconds: start,
      durationSeconds: 3,
      confidence: 0.6,
      snoreProbability: 0.1,
      windowCount: 1,
      signal: signal,
    );

RecordingSession sessionOf(
  List<SoundEvent> events, {
  bool collected = true,
}) =>
    RecordingSession(
      id: 1,
      startedAt: DateTime(2026, 10, 7, 23),
      endedAt: DateTime(2026, 10, 8, 7),
      events: events,
      stats: SessionStats(
        analyzedSeconds: 28800,
        windowsTotal: 9600,
        windowsInferred: 9600,
        windowsVadSkipped: 0,
        windowsLowConfidence: 0,
        eventCount: events.length,
        snoreEventCount: events.where((e) => e.isSnore).length,
        snoreSeconds: 0,
        categoryDistribution: const {},
        signalsCollected: collected,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('信号名和模型对得上', () {
    test('kApneaSignalLabels 里每个名字都是 AudioSet 真实存在的标签', () async {
      // ⚠️ **这是这个文件里最重要的一条。**
      //
      // 信号是按字符串和模型输出的原始标签比对的。名字写错一个字母，
      // 那个信号会**永远显示 0 次**——不报错、不崩溃、测试也不会红，
      // 只是那一栏从此空着。没有这条测试，这种错误只能靠人偶然发现。
      final raw = await rootBundle.loadString('assets/models/sleep_class_map.json');
      final labels = (jsonDecode(raw) as Map<String, dynamic>)['id2label']
          as Map<String, dynamic>;
      final names = labels.values.cast<String>().toSet();

      for (final label in kApneaSignalLabels) {
        expect(
          names,
          contains(label),
          reason: 'AudioSet 里没有叫「$label」的标签，这个名字写错了',
        );
      }
    });

    test('名单里没有重复', () {
      expect(kApneaSignalLabels.toSet(), hasLength(kApneaSignalLabels.length));
    });

    test('isApneaSignalLabel 认名单里的，不认别的', () {
      expect(isApneaSignalLabel('Gasp'), isTrue);
      expect(isApneaSignalLabel('Cough'), isFalse);
      expect(isApneaSignalLabel(null), isFalse);
      expect(isApneaSignalLabel(''), isFalse);
    });
  });

  group('从事件里挑信号', () {
    test('一个信号都没有时，是「查了没有」而不是「没查」', () {
      final a = analyzeApneaSignals(sessionOf([
        ev(signal: null),
        ev(signal: null, label: SleepCategory.snore),
      ]));

      expect(a.hits, isEmpty);
      expect(a.isEmpty, isTrue);
      // 区别就在这儿：collected 为 true 才敢说「这一夜没有」。
      expect(a.collected, isTrue);
    });

    test('老记录（没收集）和「没有」分得开', () {
      final a = analyzeApneaSignals(sessionOf([ev(signal: null)], collected: false));

      expect(a.collected, isFalse);
      expect(a.hits, isEmpty);
    });

    test('同名信号归成一组，按时间先后', () {
      final a = analyzeApneaSignals(sessionOf([
        ev(signal: 'Gasp', start: 100),
        ev(signal: 'Gasp', start: 300),
        ev(signal: 'Gasp', start: 200),
      ]));

      expect(a.hits, hasLength(1));
      expect(a.hits.single.label, 'Gasp');
      expect(a.hits.single.count, 3);
      expect(a.hits.single.events.map((e) => e.startSeconds), [100, 300, 200],
          reason: '顺序照搬事件列表，不在这里重排——排序是界面的事');
    });

    test('名单外的标签不会被当成信号', () {
      final a = analyzeApneaSignals(sessionOf([
        ev(signal: 'Cough'),
        ev(signal: 'Gasp'),
      ]));

      expect(a.hits.map((h) => h.label), ['Gasp']);
    });

    test('totalCount 是各信号次数之和', () {
      final a = analyzeApneaSignals(sessionOf([
        ev(signal: 'Gasp'),
        ev(signal: 'Gasp', start: 10),
        ev(signal: null, start: 20),
      ]));

      expect(a.totalCount, 2);
    });

    test('被移出名单的那几个，现在都不算信号', () {
      // 2026-10-07 量过一轮，这三个在能找到的 CC0 素材上一段都没通过
      // （判据：argmax == 目标标签且分数 ≥ 0.5）。移出去了就是移出去了——
      // 这条测试把这个决定钉住，免得将来顺手又加回来。
      // 理由和数字见 `lib/domain/analysis/apnea_signals.dart`。
      for (final gone in ['Wheeze', 'Pant', 'Snort', 'Sniff']) {
        expect(isApneaSignalLabel(gone), isFalse, reason: gone);
        expect(analyzeApneaSignals(sessionOf([ev(signal: gone)])).hits,
            isEmpty, reason: gone);
      }
    });

    test('普通事件不算进去', () {
      final a = analyzeApneaSignals(sessionOf([
        ev(signal: null, label: SleepCategory.snore),
        ev(signal: null, label: SleepCategory.cough),
        ev(signal: null),
      ]));

      expect(a.hits, isEmpty);
    });
  });
}
