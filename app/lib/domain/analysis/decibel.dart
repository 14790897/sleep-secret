/// 分贝换算。
///
/// ## ⚠️ 两种"分贝"是完全不同的东西，别混
///
/// **dBFS**（相对数字满量程）——**这个是准的**。它只由采样值决定，
/// 不需要任何校准：0 dBFS 是削顶，安静时在 -60 以下。同一个录音在任何
/// 设备上算出同一个数。
///
/// **dB SPL**（相对声压）——**手机测不了**。要得到它必须先知道麦克风的
/// 灵敏度和系统增益，而那是每台设备、每个 ROM、甚至每次系统更新都会变的东西。
/// 专业声级计要定期用活塞发生器校准，手机没有这个条件。
///
/// 所以 [estimatedDbSpl] 给的是**估算**，不是测量值。
library;

import 'dart:math' as math;

/// 满量程对应的声压级估算（dB SPL）。
///
/// 取 94 dB，也就是「1 帕斯卡 = 94 dB SPL」这个标准参考——它假设
/// 数字满量程大约对应 1 Pa 的声压。**这个假设对具体某台手机不一定成立**，
/// 误差可能有 ±10 dB。
///
/// 选这个值是因为它给出的数字**量级上说得通**：安静房间（RMS 0.001）
/// 算出来 34 dB，大声鼾声（RMS 0.3）算出来 84 dB——都和真实情形对得上。
/// 换成别的参考值也一样能凑出好看的数字，但那不叫校准。
const double kFullScaleDbSpl = 94;

/// 低于这个 dBFS 就认为是数字静音，不再往下算。
///
/// 不是为了好看：`log10(0)` 是负无穷，而极小的 RMS（比如 1e-8）算出来是
/// -160 dB 这种没有意义的数字。
const double kSilenceDbFs = -100;

/// RMS -> dBFS。**这个是准的。**
///
/// 0 dBFS = 满量程；1.0 的 RMS 就是 0，0.5 是 -6，0.1 是 -20。
double dbFs(double rms) {
  if (rms <= 0) return kSilenceDbFs;
  final db = 20 * (math.log(rms) / math.ln10);
  return db < kSilenceDbFs ? kSilenceDbFs : db;
}

/// RMS -> **估算的** dB SPL。见 [kFullScaleDbSpl] 的说明。
///
/// 界面上一律写成「约 XX 分贝」，别把它当测量值显示——
/// 用户会拿它跟真的声级计比，然后发现对不上。
double estimatedDbSpl(double rms) => dbFs(rms) + kFullScaleDbSpl;

/// 直接给界面用的整数。
///
/// 分贝带一位小数没有意义——估算本身的误差就有 ±10 dB，
/// 多出来的那位小数只是在制造"这很精确"的错觉。
int estimatedDbSplRounded(double rms) =>
    estimatedDbSpl(rms).clamp(0, 200).round();

/// [estimatedDbSpl] 的逆运算：从估算的 dB SPL 反推 RMS。
///
/// 只给「调门槛」用——用户在滑块上调的是分贝（和电平条、事件列表同一个
/// 单位），而真正参与门控比较的是 RMS。两个方向必须是同一个公式，
/// 否则"看到 38 分贝、调到 34 分贝"就不再是同一件事。
double rmsForEstimatedDbSpl(double db) =>
    math.pow(10, (db - kFullScaleDbSpl) / 20).toDouble();
