"""Spike: 波形 -> logits 端到端 ONNX（Kaldi fbank 烘进图里）。

严格复刻 transformers ASTFeatureExtractor 使用的 torchaudio.compliance.kaldi.fbank，
使 App 端只需喂原始 16kHz PCM，无需任何音频 DSP 依赖。
"""
import json
import pathlib

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F
import torchaudio.compliance.kaldi as ta_kaldi

MODEL_ID = "MIT/ast-finetuned-audioset-10-10-0.4593"
OUT = pathlib.Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)

SR = 16000
N_MELS = 128
FRAME_LENGTH = 400        # 25ms
HOP_LENGTH = 160          # 10ms
FFT_LENGTH = 512
PREEMPH = 0.97
LOW_FREQ = 20.0
MAX_LENGTH = 1024
EPS = float(torch.finfo(torch.float32).eps)          # 1.1920928955078125e-07
N_SAMPLES = HOP_LENGTH * (MAX_LENGTH - 1) + FRAME_LENGTH      # 164080 ≈ 10.24s


def kaldi_window(window_type: str, window_size: int) -> torch.Tensor:
    """复用 torchaudio 的窗函数实现，避免自己推 periodic/symmetric。"""
    return ta_kaldi._feature_window_function(window_type, window_size, 0.85,
                                             torch.device("cpu"), torch.float32)


class KaldiFbank(nn.Module):
    """可导出 ONNX 的 Kaldi fbank。与 ta_kaldi.fbank 处理顺序严格一致。

    torchaudio 顺序: 分帧 -> remove_dc_offset -> preemphasis -> 加窗 -> FFT -> power -> mel -> log
    """

    def __init__(self, mel_banks: torch.Tensor, window: torch.Tensor):
        super().__init__()
        # (128, 256) -> 右补零成 (128, 257)，与 torchaudio 的 pad(0,1) 一致
        self.register_buffer("mel_banks", F.pad(mel_banks, (0, 1)))
        self.register_buffer("window", window)

    def forward(self, waveform: torch.Tensor) -> torch.Tensor:
        """waveform: [B, N] float32, 取值 [-1, 1] -> [B, 1024, 128]

        注意：当前 torchaudio 的 kaldi.fbank 已不再把波形放大到 16-bit 量纲，
        因此这里直接使用 [-1,1] 的浮点波形，否则 log 域会整体偏移 log(32768²)≈20.8。
        """
        frames = waveform.unfold(1, FRAME_LENGTH, HOP_LENGTH)        # [B, m, 400]

        frames = frames - frames.mean(dim=-1, keepdim=True)          # remove_dc_offset
        pf = F.pad(frames, (1, 0), mode="replicate")                 # j=0 用自身
        frames = frames - PREEMPH * pf[..., :-1]                     # preemphasis
        frames = frames * self.window                                # windowing

        spec = torch.fft.rfft(F.pad(frames, (0, FFT_LENGTH - FRAME_LENGTH)))
        power = spec.abs().pow(2.0)                                  # [B, m, 257]

        mel = power @ self.mel_banks.t()                             # [B, m, 128]
        mel = torch.clamp(mel, min=EPS).log()

        n = mel.shape[1]
        if n < MAX_LENGTH:
            mel = F.pad(mel, (0, 0, 0, MAX_LENGTH - n))
        else:
            mel = mel[:, :MAX_LENGTH, :]
        return mel


class AstE2E(nn.Module):
    """波形 -> logits。fbank + normalize + AST 全部在一个图里。"""

    def __init__(self, fbank: KaldiFbank, ast: nn.Module, mean: float, std: float):
        super().__init__()
        self.fbank = fbank
        self.ast = ast
        self.register_buffer("mean", torch.tensor(mean))
        self.register_buffer("std", torch.tensor(std))

    def forward(self, waveform: torch.Tensor) -> torch.Tensor:
        mel = self.fbank(waveform)
        mel = (mel - self.mean) / (self.std * 2)          # AST 官方 normalize
        return self.ast(input_values=mel).logits


def main():
    from transformers import ASTFeatureExtractor, ASTForAudioClassification

    print("=== 加载模型 ===", flush=True)
    fe = ASTFeatureExtractor.from_pretrained(MODEL_ID)
    ast = ASTForAudioClassification.from_pretrained(MODEL_ID).eval()
    # 必须关掉 requires_grad：否则导出器会把 86M 权重当成图输入而不是常量，
    # 产物只有几 MB 且推理结果错乱。
    ast.requires_grad_(False)
    print(f"mean={fe.mean} std={fe.std}")

    # ---- 1. 参考输出：transformers 官方特征提取 ----
    rng = np.random.default_rng(0)
    wav = (rng.standard_normal(SR * 10) * 0.05).astype(np.float32)
    wav[-1] = wav[-1]
    ref_feat = fe(wav, sampling_rate=SR, return_tensors="pt").input_values

    with torch.no_grad():
        ref_logits = ast(ref_feat).logits

    # ---- 2. 构造 fbank 模块 ----
    banks, _ = ta_kaldi.get_mel_banks(N_MELS, FFT_LENGTH, SR, LOW_FREQ, 0.0,
                                      100.0, -500.0, 1.0)     # (128, 256)
    window = kaldi_window("hanning", FRAME_LENGTH)
    fbank = KaldiFbank(banks, window).eval()

    # ---- 3. 对齐验证 ----
    print("\n=== 对齐验证 ===", flush=True)
    # 注意：喂原始未补零波形。AST 的 padding 发生在 mel 域（补 0），
    # 若在波形域补零，补出来的帧 logmel 是 log(eps)≈-15.9，与官方不一致。
    with torch.no_grad():
        my_raw = fbank(torch.from_numpy(wav).unsqueeze(0))
        my_feat = (my_raw - fe.mean) / (fe.std * 2)      # 对齐官方 normalize

    print("参考 mel:", tuple(ref_feat.shape), " 我的 mel:", tuple(my_feat.shape))
    n = min(ref_feat.shape[1], my_feat.shape[1])
    err = (my_feat[0, :n] - ref_feat[0, :n]).abs()
    print(f"mel 最大误差 {err.max():.5f}  平均 {err.mean():.6f}")
    ok_mel = err.max().item() < 0.05
    print("mel 对齐:", "✅" if ok_mel else "❌")

    # ---- 4. 端到端 logits ----
    e2e = AstE2E(fbank, ast, fe.mean, fe.std).eval()
    wav_t = torch.from_numpy(wav).unsqueeze(0)
    with torch.no_grad():
        my_logits = e2e(wav_t)
    d = (ref_logits - my_logits).abs().max().item()
    cos = torch.nn.functional.cosine_similarity(
        ref_logits, my_logits, dim=-1).item()
    print(f"\nlogits 最大差异 {d:.5f}  余弦相似度 {cos:.6f}  "
          f"{'✅' if cos > 0.999 else '❌ 需排查'}")

    pr = ref_logits.softmax(-1)[0]
    pm = my_logits.softmax(-1)[0]
    print("参考 top5:", [(ast.config.id2label[i], round(v, 4)) for v, i in
                        zip(pr.topk(5).values.tolist(), pr.topk(5).indices.tolist())])
    print("我的  top5:", [(ast.config.id2label[i], round(v, 4)) for v, i in
                        zip(pm.topk(5).values.tolist(), pm.topk(5).indices.tolist())])

    if not ok_mel:
        print("\n⚠️ mel 未对齐，先不导出。")
        return

    # ---- 5. 导出 ONNX ----
    print("\n=== 导出端到端 ONNX ===", flush=True)
    dummy = torch.zeros(1, N_SAMPLES)
    fp32_path = OUT / "ast-e2e-fp32.onnx"
    # 输入长度必须固定：分帧需要静态形状。
    # App 侧统一按 10.24s 窗口切分，不足的补零。
    # 必须用 dynamo 导出器（legacy 不支持 aten::fft_rfft）；
    # 且不能强降 opset 17——dynamo 生成的图带 axes-as-input 形式，降版本会失败。
    torch.onnx.export(
        e2e, (dummy,), str(fp32_path),
        input_names=["waveform"], output_names=["logits"],
        dynamo=True,
    )
    sz = fp32_path.stat().st_size / 1024 / 1024
    print(f"FP32 体积 {sz:.1f} MB")

    # ---- 6. ONNX 一致性 + 延迟 ----
    import onnxruntime as ort
    import time
    sess = ort.InferenceSession(str(fp32_path), providers=["CPUExecutionProvider"])

    def run(s, samples):
        """samples: 恰好 N_SAMPLES 个采样点"""
        assert len(samples) == N_SAMPLES, f"需要 {N_SAMPLES} 点，收到 {len(samples)}"
        return s.run(["logits"], {"waveform": samples[None, :].astype(np.float32)})[0]

    # 用恰好 10.24s 的波形测（不足则补零到 N_SAMPLES）
    wav_fixed = np.pad(wav, (0, N_SAMPLES - len(wav))).astype(np.float32)
    o = run(sess, wav_fixed)
    print(f"ONNX vs PyTorch 最大差异 {np.abs(o - my_logits.numpy()).max():.5f}")

    for _ in range(2):
        run(sess, wav_fixed)
    ts = []
    for _ in range(5):
        t = time.time()
        run(sess, wav_fixed)
        ts.append(time.time() - t)
    print(f"PC CPU 单次 10.24s 窗口: 中位 {np.median(ts) * 1000:.0f}ms")

    # ---- 7. INT8 量化 ----
    print("\n=== INT8 量化 ===", flush=True)
    from onnxruntime.quantization import quantize_dynamic, QuantType
    int8_path = OUT / "ast-e2e-int8.onnx"
    quantize_dynamic(str(fp32_path), str(int8_path), weight_type=QuantType.QInt8)
    print(f"FP32 {sz:.1f} MB -> INT8 {int8_path.stat().st_size / 1024 / 1024:.1f} MB")

    sess8 = ort.InferenceSession(str(int8_path), providers=["CPUExecutionProvider"])
    o8 = run(sess8, wav_fixed)
    p8 = torch.tensor(o8).softmax(-1)[0]
    print("INT8 top5:", [(ast.config.id2label[i], round(v, 4)) for v, i in
                        zip(p8.topk(5).values.tolist(), p8.topk(5).indices.tolist())])
    ts = []
    for _ in range(5):
        t = time.time()
        run(sess8, wav_fixed)
        ts.append(time.time() - t)
    print(f"INT8 延迟中位 {np.median(ts) * 1000:.0f}ms")

    print("\n=== 结论 ===")
    print(f"输入 float32[1, {N_SAMPLES}] (10.24s@16k) -> 输出 float32[1, 527]")


if __name__ == "__main__":
    main()
