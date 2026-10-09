import 'dart:typed_data';

/// 正在录的一段事件音频。
///
/// ## 为什么是流式，而不是录完一次性交出去
///
/// 事件可以长达几分钟——连续鼾声三五分钟很常见。16kHz 的 Float32 采样点
/// 三分钟就是 11MB，最长的那种攒在内存里再编码，对一个整夜挂着的进程
/// 是没必要的风险（手机上还可能被系统直接杀掉）。
///
/// 所以边录边往盘上追加，收尾时回填头部长度。内存里始终只有一个窗口。
abstract interface class ClipWriter {
  /// 追加采样点。写失败由实现记下，[finish] 会返回 null。
  Future<void> append(Float32List samples);

  /// 收尾并落定，返回**相对路径**。
  ///
  /// 返回 null 表示这段没留下来（一个采样点都没有、写失败、磁盘满）。
  Future<String?> finish();

  /// 这段不要了（不是鼾声、也不是高危信号），把临时文件删掉。
  Future<void> release();
}

/// 事件音频片段的存储。
///
/// 接口放领域层：分析引擎要在事件定案时落片段，但它不该知道文件系统怎么用。
abstract interface class AudioClipStore {
  /// 开始录一段事件音频。
  ///
  /// 返回 null 表示开不了（磁盘满、权限）。落片段失败不该影响整夜录音，
  /// 调用方只记数——和 [save] 一个口径。
  Future<ClipWriter?> begin({
    required DateTime sessionStartedAt,
    required double startSeconds,
    required int sampleRate,
  });

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

  /// 把片段存到**指定的相对路径**上。**导入专用。**
  ///
  /// 和 [save] 的区别：那个是从采样点编码 WAV 并存到一个由时间推导的路径，
  /// 这个是把一个已经存在的文件原样放进去。导入时相对路径**必须原样保留**——
  /// 数据库里存的就是它，换个名字就对不上了。
  ///
  /// 返回 false 表示写入失败（磁盘满、权限等），调用方只记数不中断。
  Future<bool> adopt({
    required String relativePath,
    required String localPath,
  });

  /// 把相对路径还原成可播放的绝对路径。文件不存在时返回 null。
  Future<String?> resolve(String relativePath);

  /// 删除某次会话的全部片段。
  Future<void> deleteSession(DateTime sessionStartedAt);

  /// 删除全部片段。
  Future<void> deleteAll();
}
