# Sleep Secret · 比赛项目介绍

## 一句话

**Sleep Secret 是一个完全端侧的睡眠声音记录与分析 App：整夜录音，所有推理都在手机上完成，早上给出一份「什么时候有声音、是什么声音、持续多久」的报告——默认情况下，音频一个字节都不出设备。**

- 开源代码：<https://github.com/14790897/sleep-secret>
- 许可：GPL-3.0-or-later
- 文档：<https://mygithub.sixiangjia.de/sleep-secret/>
- F-Droid：<https://f-droid.org/packages/com.sleepsecret.sleep_secret/>

## 要解决的问题

睡眠类 App 普遍有两个问题：

1. **隐私**：整夜音频上传云端，用户无法验证数据去了哪里；
2. **不可查**：闭源实现，用户只能相信厂商的承诺。

而睡眠声音——鼾声、梦话、咳嗽——恰恰是最私密的数据之一。Sleep Secret 的出发点很简单：**这份数据没有必要离开手机。**

## 我们做了什么

- **整夜录音 + 端侧推理**：CED-tiny（5.5M 参数，AudioSet 预训练）转成 ONNX，在手机上用 ONNX Runtime 推理，不依赖网络。
- **可读的报告**：九大类（鼾声 / 呼吸声 / 咳嗽清嗓 / 喷嚏 / 人声梦话 / 体动床响 / 环境噪音 / 设备噪音 / 静音）、整夜声音时间线、鼾声指数、类别与每小时分布、事件明细与置信度。
- **可回放的片段**：鼾声、高危信号（倒吸气等）和梦话的音频整段保留，不是截一段；听完之后可以**只删音频、保留报告**。
- **同一晚自动合并**：半夜醒来停止再录，会被合并成同一晚，并在报告里标出「中间醒过几次」。
- **可选的自有云同步**：用户自己配置坚果云 / WebDAV，数据只去用户自己的网盘；App 没有自己的服务器。

## 技术亮点

- **完全端侧**：模型 6.6 MB，2 线程 CPU 推理。真实使用实测：Redmi K80 整夜 6.5 小时耗电 9%，前台服务整夜存活。
- **可复现构建**：F-Droid 构建出的 APK 与我们发布的 APK **逐字节相同**（清零 ELF build ID、固定构建路径）。用户可以在 GitHub 版和 F-Droid 版之间无缝切换、覆盖升级，不会丢数据。
- **数据诚实**：不引入未经真实数据验证的判据——删掉了实测拦截数为 0 的固定置信度门控；鼾声展示门槛只影响显示，并明确写出筛掉了多少；界面上严格区分「没数据」和「没有」。
- **可验证的工程**：555 个单元测试、28 个设备集成测试，以及需要真实硬件的 E2E（真实录音回放、音频焦点被抢时录音不中断、音频片段完整性）。

## 已上线与验证

- 已在 **F-Droid** 上架（可复现构建，与 GitHub 版同签名）。
- F-Droid 的收录 MR 已完成评审并合并，构建服务器的三个 ABI 都通过了逐字节比对。
- 用真实用户数据校准过展示口径：例如鼾声时长只计实际有声时间，不计合并间隔里的安静段（实测一晚约 24% 的空白曾被误计）。
- Android 为主，Windows 桌面版可用于测试。

## 开源与可持续

采用 **GPL-3.0-or-later**。这个 App 的核心主张是「音频不出设备」——而这句话只有**代码可查**的时候才可信。GPL 保证任何人拿到的版本都能被审阅、也能被继续改进；换成闭源分支就没法验证了。

项目的开发过程也尽量公开可查：每次改动走 issue + PR、CI 全绿才合并、发布由 semantic-release 自动完成、F-Droid 配方和可复现构建的修法都记录在仓库里。

## 视频介绍

- [基于本地小模型的打鼾睡眠记录开源软件](https://www.bilibili.com/video/BV1etxk65Ea7/)（2:45）——项目总览：动机、端侧推理与报告。
- [Sleep Secret｜把夜晚听清楚：整夜录音，手机本地分析](https://www.bilibili.com/video/BV1gWWY6uEjQ/)（3:24）——功能演示与使用流程。

## 链接汇总

| | |
|---|---|
| GitHub | <https://github.com/14790897/sleep-secret> |
| 文档站 | <https://mygithub.sixiangjia.de/sleep-secret/> |
| F-Droid | <https://f-droid.org/packages/com.sleepsecret.sleep_secret/> |
| 视频 1 | <https://www.bilibili.com/video/BV1etxk65Ea7/> |
| 视频 2 | <https://www.bilibili.com/video/BV1gWWY6uEjQ/> |
