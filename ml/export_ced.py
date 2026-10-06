"""⚠️ 已废弃，不要用这个脚本产出的模型（2026-10-06）。

它从 `transformers` + `trust_remote_code` 路径加载 CED，而**那条路径本身产出的是垃圾**
（公鸡→Music 0.815，真实鼾声→Speech 0.812），怀疑是 transformers 5.1.0 与 CED 那份
为 4.x 写的 remote code 不兼容。从这里导出的 ONNX 继承了同一个病。

当时没发现，是因为验证方式错了：拿导出结果与 HF 实现比对，**余弦 1.000000**——
但两边是同一个坏模型，一致性验证完美掩盖了"双方都错"。

**现在用仓库里自带的 `model.onnx`**（吃原始波形，输出正确）。见
`C:/git-program/sleep-secret/PLAN.md` 与 memory 里的 `audioset-sigmoid-not-softmax`。

保留此文件仅为记录导出流程本身（有些坑仍然有效，比如 dynamo 导出器和
requires_grad_(False)）。

---

原文档：
导出 CED-tiny 为端到端 ONNX：原始波形 -> 527 logits。

上游仓库虽自带 model.onnx，但实测与官方 HF 实现对不上（余弦 0.08~0.17），
因此自己导出并逐位校验。

CED 的特征提取（照抄 feature_extraction_ced.py）：
    MelSpectrogram(f_min=0, sample_rate=16000, win_length=512, center=True,
                   n_fft=512, f_max=None, hop_length=160, n_mels=64)
    AmplitudeToDB(top_db=120)
"""
import pathlib

import numpy as np
import torch
import torch.nn as nn
import torchaudio.transforms as T

MODEL_ID = "mispeech/ced-tiny"
ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "models"
OUT.mkdir(exist_ok=True)

N_MELS = 64
N_FFT = 512
WIN = 512
HOP = 160
F_MIN = 0.0
F_MAX = None
TOP_DB = 120
AMIN = 1e-10


class CedFrontend(nn.Module):
    """mel 频谱 + 转 dB，与 CedFeatureExtractor 等价。"""

    def __init__(self):
        super().__init__()
        self.mel = T.MelSpectrogram(
            f_min=F_MIN, sample_rate=16000, win_length=WIN, center=True,
            n_fft=N_FFT, f_max=F_MAX, hop_length=HOP, n_mels=N_MELS,
        )

    def forward(self, waveform: torch.Tensor) -> torch.Tensor:
        """[B, N] -> [B, 64, T]"""
        x = self.mel(waveform)                       # [B, 64, T] 功率谱
        x = 10.0 * torch.log10(torch.clamp(x, min=AMIN))
        # AmplitudeToDB 的 top_db 是全局最大值下切 120dB
        x = torch.clamp(x, min=x.amax(dim=(-2, -1), keepdim=True) - TOP_DB)
        return x


class CedE2E(nn.Module):
    def __init__(self, frontend: CedFrontend, model: nn.Module):
        super().__init__()
        self.frontend = frontend
        self.model = model

    def forward(self, waveform: torch.Tensor) -> torch.Tensor:
        feat = self.frontend(waveform)               # [B, 64, T]
        return self.model(input_values=feat).logits


def main():
    from transformers import AutoFeatureExtractor, AutoModelForAudioClassification

    print("=== 1. 加载 CED-tiny ===", flush=True)
    fe = AutoFeatureExtractor.from_pretrained(MODEL_ID, trust_remote_code=True)
    model = AutoModelForAudioClassification.from_pretrained(
        MODEL_ID, trust_remote_code=True).eval()
    model.requires_grad_(False)
    print(f"类别数 {model.config.num_labels}")

    print("\n=== 2. 特征提取对齐 ===", flush=True)
    rng = np.random.default_rng(0)
    wav = (rng.standard_normal(16000 * 5) * 0.05).astype(np.float32)
    wav_t = torch.from_numpy(wav).unsqueeze(0)

    with torch.no_grad():
        ref_feat = fe(wav, sampling_rate=16000, return_tensors="pt").input_values
        my_feat = CedFrontend().eval()(wav_t)

    print("参考 mel:", tuple(ref_feat.shape), " 我的:", tuple(my_feat.shape))
    if ref_feat.shape == my_feat.shape:
        err = (my_feat - ref_feat).abs()
        print(f"mel 最大误差 {err.max():.5f}  平均 {err.mean():.6f}")
        print("mel 对齐:", "✅" if err.max() < 1e-3 else "❌")
    else:
        print("❌ 形状不一致")

    print("\n=== 3. 端到端 logits 对齐 ===", flush=True)
    frontend = CedFrontend().eval()
    e2e = CedE2E(frontend, model).eval()
    with torch.no_grad():
        ref_logits = model(input_values=ref_feat).logits
        my_logits = e2e(wav_t)
    cos = torch.nn.functional.cosine_similarity(ref_logits, my_logits, dim=-1).item()
    md = (ref_logits - my_logits).abs().max().item()
    print(f"余弦 {cos:.6f}  最大差 {md:.5f}  {'✅' if cos > 0.9999 else '❌'}")
    pr = ref_logits.softmax(-1)[0]
    print("参考 top5:", [(model.config.id2label[i], round(v, 4)) for v, i in
                        zip(pr.topk(5).values.tolist(), pr.topk(5).indices.tolist())])
    pm = my_logits.softmax(-1)[0]
    print("我的  top5:", [(model.config.id2label[i], round(v, 4)) for v, i in
                        zip(pm.topk(5).values.tolist(), pm.topk(5).indices.tolist())])

    if cos < 0.9999:
        print("\n⚠️ 未对齐，停止导出。")
        return

    print("\n=== 4. 导出 ONNX ===", flush=True)
    fp32_path = OUT / "ced-tiny-fp32.onnx"
    dummy = torch.zeros(1, 16000 * 10)
    torch.onnx.export(
        e2e, (dummy,), str(fp32_path),
        input_names=["waveform"], output_names=["logits"],
        dynamic_axes={"waveform": {0: "batch", 1: "n_samples"},
                      "logits": {0: "batch"}},
        dynamo=True,
    )
    import os
    print(f"FP32 体积 {os.path.getsize(fp32_path) / 1024 / 1024:.1f} MB")

    print("\n=== 5. ONNX 一致性 + 动态长度 ===", flush=True)
    import onnxruntime as ort
    sess = ort.InferenceSession(str(fp32_path), providers=["CPUExecutionProvider"])

    def run(samples):
        return sess.run(["logits"], {"waveform": samples[None, :].astype(np.float32)})[0][0]

    o = run(wav)
    c = float(np.dot(ref_logits.numpy()[0], o) /
              (np.linalg.norm(ref_logits.numpy()[0]) * np.linalg.norm(o)))
    print(f"ONNX vs PyTorch 余弦 {c:.6f}  最大差 {np.abs(ref_logits.numpy()[0] - o).max():.5f}")

    for n_sec in (1, 3, 5, 10):
        w = (rng.standard_normal(16000 * n_sec) * 0.05).astype(np.float32)
        with torch.no_grad():
            rr = model(input_values=fe(w, sampling_rate=16000,
                                       return_tensors="pt").input_values).logits.numpy()[0]
        oo = run(w)
        cc = float(np.dot(rr, oo) / (np.linalg.norm(rr) * np.linalg.norm(oo)))
        print(f"  动态长度 {n_sec:2d}s -> 余弦 {cc:.6f} {'✅' if cc > 0.999 else '❌'}")

    print("\n=== 6. INT8 量化 ===", flush=True)
    import onnx
    from onnxruntime.quantization import quantize_dynamic, QuantType
    m = onnx.load(str(fp32_path))
    del m.graph.value_info[:]                       # 否则 shape_inference 会报冲突
    cleaned = OUT / "ced-tiny-clean.onnx"
    onnx.save(m, str(cleaned), save_as_external_data=False)

    int8_path = OUT / "ced-tiny-int8.onnx"
    quantize_dynamic(str(cleaned), str(int8_path), weight_type=QuantType.QInt8)
    print(f"INT8 体积 {os.path.getsize(int8_path) / 1024 / 1024:.1f} MB")

    sess8 = ort.InferenceSession(str(int8_path), providers=["CPUExecutionProvider"])
    o8 = sess8.run(["logits"], {"waveform": wav[None, :]})[0][0]
    c8 = float(np.dot(ref_logits.numpy()[0], o8) /
               (np.linalg.norm(ref_logits.numpy()[0]) * np.linalg.norm(o8)))
    print(f"INT8 余弦 {c8:.6f}")
    p8 = torch.tensor(o8).softmax(-1)
    print("INT8 top5:", [(model.config.id2label[i], round(v, 4)) for v, i in
                        zip(p8.topk(5).values.tolist(), p8.topk(5).indices.tolist())])

    print("\n=== 7. 延迟基准 (PC CPU, 10s 窗口) ===", flush=True)
    import time
    w10 = (rng.standard_normal(16000 * 10) * 0.05).astype(np.float32)
    for label, s in [("FP32", sess), ("INT8", sess8)]:
        for _ in range(2):
            s.run(["logits"], {"waveform": w10[None, :]})
        ts = []
        for _ in range(5):
            t = time.time()
            s.run(["logits"], {"waveform": w10[None, :]})
            ts.append(time.time() - t)
        print(f"  {label}: 中位 {np.median(ts) * 1000:.0f}ms")

    print("\n=== 完成 ===")
    print(f"端侧模型: {int8_path}")


if __name__ == "__main__":
    main()
