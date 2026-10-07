import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_secret/domain/analysis/export_codec.dart';
import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/sleep_category.dart';
import 'package:sleep_secret/domain/models/sound_event.dart';

RecordingSession buildSession() => RecordingSession(
      id: 7, // 导出时不该带出去；导入也不该带进来
      startedAt: DateTime(2026, 10, 7, 0, 23),
      endedAt: DateTime(2026, 10, 7, 8, 0),
      events: [
        SoundEvent(
          label: SleepCategory.snore,
          startSeconds: 27300,
          durationSeconds: 12,
          confidence: 0.46,
          snoreProbability: 0.46,
          windowCount: 4,
          clipPath: '1791278973396/27300000.wav',
        ),
        const SoundEvent(
          label: SleepCategory.ambient,
          startSeconds: 300,
          durationSeconds: 21,
          confidence: 0.31,
          snoreProbability: 0.01,
          windowCount: 7,
          // clipPath 为 null：非鼾声事件不落片段
        ),
      ],
      stats: const SessionStats(
        analyzedSeconds: 27450,
        windowsTotal: 9151,
        windowsInferred: 9151,
        windowsVadSkipped: 0,
        windowsLowConfidence: 492,
        eventCount: 81,
        snoreEventCount: 9,
        snoreSeconds: 120,
        categoryDistribution: {},
      ),
    );

void main() {
  group('往返', () {
    test('编出来再解回去，字段一个不差', () {
      final original = buildSession();
      final back = decodeSession(encodeSession(original));

      expect(back.startedAt, original.startedAt);
      expect(back.endedAt, original.endedAt);
      expect(back.events.length, original.events.length);

      for (var i = 0; i < original.events.length; i++) {
        final a = original.events[i];
        final b = back.events[i];
        expect(b.label, a.label);
        expect(b.startSeconds, a.startSeconds);
        expect(b.durationSeconds, a.durationSeconds);
        expect(b.confidence, a.confidence);
        expect(b.snoreProbability, a.snoreProbability);
        expect(b.windowCount, a.windowCount);
        expect(b.clipPath, a.clipPath);
      }

      expect(back.stats.analyzedSeconds, original.stats.analyzedSeconds);
      expect(back.stats.windowsInferred, original.stats.windowsInferred);
      expect(back.stats.windowsLowConfidence, original.stats.windowsLowConfidence);
      expect(back.stats.snoreSeconds, original.stats.snoreSeconds);
    });

    test('id 不带出去，也不带进来', () {
      // 数据库插入时自己分配 id，原来那个进不来也留不下。
      // 带去带去只会让人以为它能保住。
      final json = jsonDecode(encodeSession(buildSession())) as Map<String, dynamic>;
      expect(json['session'], isNot(contains('id')));
      expect(decodeSession(encodeSession(buildSession())).id, isNull);
    });

    test('没有结束时间的会话也编得出来', () {
      final s = RecordingSession(
        id: 1,
        startedAt: DateTime(2026, 10, 7, 0, 23),
        endedAt: null,
        events: const [],
        stats: const SessionStats.empty(),
      );
      expect(decodeSession(encodeSession(s)).endedAt, isNull);
    });
  });

  group('类别序列化', () {
    test('存的是英文标识不是中文名', () {
      // ⚠️ 用 label（中文）的话，哪天改文案，历史导出文件就全部读不出来了。
      // 数据库那边也是这个规矩。
      final json = encodeSession(buildSession());
      expect(json, contains('"label": "snore"'));
      expect(json, isNot(contains('鼾声')));
    });

    test('未知类别抛异常而不是猜一个', () {
      // 猜的话会把一个没见过的类别悄悄变成别的——那是数据损坏，
      // 而且要到用户发现数据不对才会暴露。
      final raw = jsonDecode(encodeSession(buildSession())) as Map<String, dynamic>;
      (raw['session'] as Map)['events'][0]['label'] = 'something_new';
      expect(
        () => decodeSession(jsonEncode(raw)),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('坏文件', () {
    test('不是本应用的文件', () {
      expect(() => decodeSession('{"app":"something-else"}'),
          throwsA(isA<FormatException>()));
    });

    test('格式版本比本版本新 —— 明确报读不了，而不是猜着读', () {
      final raw = jsonDecode(encodeSession(buildSession())) as Map<String, dynamic>;
      raw['format'] = kArchiveFormat + 1;
      expect(() => decodeSession(jsonEncode(raw)),
          throwsA(isA<FormatException>()));
    });

    test('缺字段', () {
      expect(() => decodeSession('{"app":"sleep-secret","format":1}'),
          throwsA(isA<FormatException>()));
    });

    test('根本不是 JSON', () {
      expect(() => decodeSession('这不是 json'),
          throwsA(isA<FormatException>()));
    });
  });
}
