import 'dart:async';

import 'package:sleep_secret/domain/models/recording_session.dart';
import 'package:sleep_secret/domain/models/recording_state.dart';
import 'package:sleep_secret/domain/repositories/recording_controller.dart';

/// 可编程的假录音控制器——测试环境没有麦克风也没有前台服务。
class FakeRecordingController implements RecordingController {
  FakeRecordingController({this.sessions = const []});

  List<RecordingSession> sessions;

  RecordingState _state = const RecordingState();
  final _controller = StreamController<RecordingState>.broadcast();

  int startCount = 0;
  int stopCount = 0;
  int deleteCount = 0;
  int listCount = 0;
  bool clipRecording = true;
  bool vad = false;
  int vadDb = 54;

  /// 让 listSessions 挂起，用来观察"加载中"的界面。
  Completer<void>? blockList;

  @override
  RecordingState get state => _state;

  @override
  Stream<RecordingState> get states => _controller.stream;

  void push(RecordingState s) {
    _state = s;
    _controller.add(s);
  }

  @override
  bool get recordClips => clipRecording;

  @override
  Future<void> setRecordClips(bool enabled) async {
    clipRecording = enabled;
  }

  @override
  bool get vadEnabled => vad;

  @override
  Future<void> setVadEnabled(bool enabled) async {
    vad = enabled;
  }

  @override
  int get vadThresholdDb => vadDb;

  @override
  Future<void> setVadThresholdDb(int db) async {
    vadDb = db;
  }

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Future<void> start() async {
    startCount++;
    push(_state.copyWith(
      isRecording: true,
      startedAt: DateTime(2026, 10, 6, 23),
    ));
  }

  @override
  Future<RecordingSession?> stop() async {
    stopCount++;
    if (!_state.isRecording) return null;
    push(_state.copyWith(isRecording: false));
    return null;
  }

  @override
  Future<List<RecordingSession>> listSessions() async {
    listCount++;
    if (blockList != null) await blockList!.future;
    return sessions;
  }

  @override
  Future<RecordingSession?> loadSession(int id) async =>
      sessions.where((s) => s.id == id).firstOrNull;

  @override
  Future<void> deleteSession(int id) async {
    deleteCount++;
    sessions = sessions.where((s) => s.id != id).toList();
  }

  @override
  Future<void> dispose() async => _controller.close();
}
