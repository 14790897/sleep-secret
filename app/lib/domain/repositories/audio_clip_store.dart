import 'dart:typed_data';

/// 事件音频片段的存储。
///
/// 接口放领域层：分析引擎要在事件定案时落片段，但它不该知道文件系统怎么用。
abstract interface class AudioClipStore {
  /// 写入一段事件音频，返回**相对路径**（绝对路径不进数据库——
  /// 应用的沙盒目录在重装或换设备后会变，存绝对路径会全部失效）。
  ///
  /// 返回 null 表示写入失败。落片段失败不该影响整夜录音，调用方只记数。
  Future<String?> save({
    required DateTime sessionStartedAt,
    required double startSeconds,
    required Float32List samples,
    required int sampleRate,
  });

  /// 把相对路径还原成可播放的绝对路径。文件不存在时返回 null。
  Future<String?> resolve(String relativePath);

  /// 删除某次会话的全部片段。
  Future<void> deleteSession(DateTime sessionStartedAt);

  /// 删除全部片段。
  Future<void> deleteAll();
}
