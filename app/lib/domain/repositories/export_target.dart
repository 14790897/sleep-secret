/// 一个「可以往里写文件、也可以从里面读文件」的地方。
///
/// ## 为什么要这层抽象
///
/// Android 和桌面写文件的方式**根本不同**，但上层逻辑不该关心：
///
/// - **Android**：用户选目录走 SAF（存储访问框架），拿到的是 `content://`
///   树 URI，只能通过 `DocumentFile` 写。**没有普通文件路径可用**——
///   `file_picker.getDirectoryPath()` 会返回一个路径但不授予写权限，
///   照着写会静默失败。那是个已知的坑（issue 被关了，标记 not planned）。
/// - **桌面**：就是普通目录，`dart:io` 直接用。
///
/// 所以导出/导入的全部逻辑都只依赖这个接口，只有两个实现碰平台 API。
/// 这样**除了那两个实现，别的都能在电脑上测**——和录音那边把
/// `RecordAudioCapture` 隔离出来是同一个思路。
///
/// 路径一律用**相对目标根目录的 posix 风格**（`clips/1791278973396/24000.wav`），
/// 由各实现自己拆解成平台需要的形式。
abstract interface class ExportTarget {
  /// 给用户看的描述。SAF 下是个 URI，桌面上是路径。
  String get description;

  /// 存进设置里的标识，下次直接还原。
  ///
  /// 桌面存路径，Android 存树 URI。两种形状不同，所以带上类型前缀。
  String get serialized;

  /// 这个目标现在还能不能用。
  ///
  /// SAF 的授权可能被用户在系统设置里撤销，或者那个目录被删了。
  /// **每次导出/导入前都要查**，否则会撞上一堆看不懂的权限异常。
  Future<bool> isUsable();

  /// 确保目录存在（含父目录）。
  Future<void> ensureDirectory(String relativeDir);

  /// 写一个文本文件，已存在就覆盖。
  Future<void> writeText(String relativePath, String content);

  /// 读一个文本文件。不存在返回 null（不是抛异常——
  /// 「没有这个文件」在导入时是正常情况，不该当成错误）。
  Future<String?> readText(String relativePath);

  /// 把本地文件复制进去，已存在就覆盖。
  Future<void> copyIn(String localPath, String relativePath);

  /// 从里面复制到本地。文件不存在返回 false。
  Future<bool> copyOut(String relativePath, String localPath);

  /// 列出某个目录下的**文件名**（不含子目录、不含路径）。
  /// 目录不存在时返回空表而不是抛异常。
  Future<List<String>> listFiles(String relativeDir);
}

/// 选一个导出目标。取消时返回 null。
abstract interface class ExportTargetPicker {
  Future<ExportTarget?> pick();

  /// 从存下来的 [serialized] 还原。还原不了（比如授权失效）返回 null。
  Future<ExportTarget?> restore(String serialized);
}
