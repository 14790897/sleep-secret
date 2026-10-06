"""逐级比对：我的 fbank 实现 vs torchaudio.compliance.kaldi 内部中间量。"""
import numpy as np
import torch
import torchaudio.compliance.kaldi as K

SR, N_MELS, FL, HOP, FFT = 16000, 128, 400, 160, 512
PREEMPH = 0.97

rng = np.random.default_rng(0)
wav_np = (rng.standard_normal(SR * 10) * 0.05).astype(np.float32)
wav = torch.from_numpy(wav_np)

# ---------- 参考：逐步调用 torchaudio 内部函数 ----------
waveform, window_shift, window_size, padded = K._get_waveform_and_window_properties(
    wav.unsqueeze(0), 0, SR, HOP, FL, True, PREEMPH)
print("参考窗口参数: shift", window_shift, "size", window_size, "padded", padded)

ref_strided, _ = K._get_window(waveform, padded, window_size, window_shift,
                               "hanning", 0.85, True, True, 0.0, 0.0, True, PREEMPH)
print("参考 strided:", tuple(ref_strided.shape))

ref_spec = torch.fft.rfft(ref_strided).abs().pow(2.0)
print("参考 power spectrum:", tuple(ref_spec.shape))

ref_banks, _ = K.get_mel_banks(N_MELS, padded, SR, 20.0, 0.0, 100.0, -500.0, 1.0)
print("参考 mel banks:", tuple(ref_banks.shape))
ref_banks_p = torch.nn.functional.pad(ref_banks, (0, 1))
ref_mel = torch.mm(ref_spec, ref_banks_p.T)
ref_logmel = torch.max(ref_mel, torch.finfo(torch.float32).eps).log()
print("参考 logmel:", tuple(ref_logmel.shape), f"值域[{ref_logmel.min():.2f},{ref_logmel.max():.2f}]")

# ---------- 我的实现 ----------
x = wav.unsqueeze(0) * 32768.0
n_frames = 1 + (x.shape[1] - FL) // HOP
print("\n我的 n_frames:", n_frames, " 参考:", ref_strided.shape[0])

my_frames = x.unfold(1, FL, HOP)                       # [1, m, 400]
# 1) DC offset
my_frames = my_frames - my_frames.mean(dim=-1, keepdim=True)
# 2) 逐帧 deltas（严格按 Kaldi：j=0 用自身，replicate padding）
padded_f = torch.nn.functional.pad(my_frames, (1, 0), mode="replicate")
my_frames = my_frames - PREEMPH * padded_f[..., :-1]
# 3) 加窗
my_window = K._feature_window_function("hanning", FL, 0.85, x.device, x.dtype)
my_frames = my_frames * my_window

print("\n--- 第1级: 加窗后帧 ---")
d = (my_frames[0] - ref_strided).abs()
print(f"最大误差 {d.max():.6f}  平均 {d.mean():.6f}")

# 4) pad + FFT
my_spec_in = torch.nn.functional.pad(my_frames, (0, FFT - FL))
my_spec = torch.fft.rfft(my_spec_in).abs().pow(2.0)
print("\n--- 第2级: power spectrum ---")
d = (my_spec[0] - ref_spec).abs()
print(f"最大误差 {d.max():.6f}  平均 {d.mean():.6f}")

# 5) mel banks 对比
my_banks = torch.from_numpy(
    __import__("importlib").import_module("spike.export_ast_e2e").kaldi_mel_banks(
        N_MELS, FFT, SR, 20.0, 0.0) if False else np.zeros((1, 1))
)
print("\n--- 第3级: mel banks (对比我手写的 vs 官方) ---")
sys_banks = ref_banks                                  # (128, 256)
# 我的手写版（在 export_ast_e2e 里）
import importlib.util, pathlib
spec = importlib.util.spec_from_file_location(
    "e2e", pathlib.Path(__file__).parent / "export_ast_e2e.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mine_banks = mod.kaldi_mel_banks(N_MELS, FFT, SR, 20.0, 0.0)[:, :FFT // 2]
print("我手写 banks:", tuple(mine_banks.shape), "官方:", tuple(sys_banks.shape))
db = (mine_banks - sys_banks).abs()
print(f"banks 最大误差 {db.max():.6f}  平均 {db.mean():.6f}")
print("  官方行和(前5):", sys_banks.sum(dim=1)[:5].tolist())
print("  我的行和(前5):", mine_banks.sum(dim=1)[:5].tolist())
