"""Spike: 验证 AST -> ONNX -> INT8 量化链路是否可行。

只做可行性验证，产出体积/延迟数据，不做任何训练。
"""
import os, time, json, pathlib

import numpy as np
import torch
from transformers import ASTFeatureExtractor, ASTForAudioClassification

MODEL_ID = "MIT/ast-finetuned-audioset-10-10-0.4593"
OUT = pathlib.Path(__file__).parent / "out"
OUT.mkdir(exist_ok=True)


def mb(p):
    return f"{os.path.getsize(p) / 1024 / 1024:.1f} MB"


print("=== 1. 加载模型与特征提取器 ===", flush=True)
t0 = time.time()
fe = ASTFeatureExtractor.from_pretrained(MODEL_ID)
model = ASTForAudioClassification.from_pretrained(MODEL_ID).eval()
print(f"加载耗时 {time.time() - t0:.1f}s")

n_params = sum(p.numel() for p in model.parameters())
print(f"参数量 {n_params / 1e6:.1f}M")
cfg = model.config
print(f"输入规格: sr={cfg.sampling_rate} mel={cfg.num_mel_bins} "
      f"max_len={cfg.max_length} patch={cfg.patch_size} hidden={cfg.hidden_size}")
print(f"类别数 {cfg.num_labels}")

# ---- 2. 特征提取验证 ----
print("\n=== 2. 特征提取 (16kHz, 10s) ===", flush=True)
sr = cfg.sampling_rate
audio = np.random.randn(sr * 10).astype(np.float32) * 0.01
feat = fe(audio, sampling_rate=sr, return_tensors="pt").input_values
print(f"mel 特征 shape: {tuple(feat.shape)}  (期望 [1, 1024, 128])")

with torch.no_grad():
    logits = model(feat).logits
print(f"logits shape: {tuple(logits.shape)}")
probs = logits.softmax(-1)[0]
top5 = probs.topk(5)
print("top5 随机输入预测:", [(cfg.id2label[i], round(v, 4))
                              for v, i in zip(top5.values.tolist(), top5.indices.tolist())])

# ---- 3. 导出 ONNX ----
print("\n=== 3. 导出 ONNX ===", flush=True)
onnx_path = OUT / "ast-audioset-fp32.onnx"


class Wrapper(torch.nn.Module):
    """只导出 backbone + 分类头，输入直接是 mel 特征，避开 numpy 特征提取。"""

    def __init__(self, m):
        super().__init__()
        self.m = m

    def forward(self, input_values):
        return self.m(input_values).logits


t0 = time.time()
torch.onnx.export(
    Wrapper(model),
    (feat,),
    str(onnx_path),
    input_names=["input_values"],
    output_names=["logits"],
    dynamic_axes={"input_values": {0: "batch"}, "logits": {0: "batch"}},
    opset_version=17,
    dynamo=False,
)
print(f"导出耗时 {time.time() - t0:.1f}s -> {mb(onnx_path)}")

# ---- 4. 校验 ONNX 数值一致性 ----
print("\n=== 4. ONNX vs PyTorch 数值一致性 ===", flush=True)
import onnxruntime as ort

sess = ort.InferenceSession(str(onnx_path), providers=["CPUExecutionProvider"])
onnx_logits = sess.run(["logits"], {"input_values": feat.numpy()})[0]
max_diff = float(np.abs(onnx_logits - logits.numpy()).max())
print(f"最大绝对误差 {max_diff:.6e}  {'✅ 一致' if max_diff < 1e-3 else '❌ 偏差过大'}")

# ---- 5. 延迟基准 (PC CPU) ----
print("\n=== 5. PC CPU 延迟基准 ===", flush=True)
for _ in range(2):
    sess.run(["logits"], {"input_values": feat.numpy()})
ts = []
for _ in range(5):
    t = time.time()
    sess.run(["logits"], {"input_values": feat.numpy()})
    ts.append(time.time() - t)
print(f"FP32 单次 10s 窗口: 中位 {np.median(ts) * 1000:.0f}ms  (min {min(ts) * 1000:.0f}ms)")

# ---- 6. INT8 动态量化 ----
print("\n=== 6. INT8 量化 ===", flush=True)
from onnxruntime.quantization import quantize_dynamic, QuantType

int8_path = OUT / "ast-audioset-int8.onnx"
t0 = time.time()
quantize_dynamic(str(onnx_path), str(int8_path), weight_type=QuantType.QInt8)
print(f"量化耗时 {time.time() - t0:.1f}s")
print(f"FP32 {mb(onnx_path)}  ->  INT8 {mb(int8_path)}  "
      f"(压缩 {os.path.getsize(onnx_path) / os.path.getsize(int8_path):.2f}x)")

sess8 = ort.InferenceSession(str(int8_path), providers=["CPUExecutionProvider"])
o8 = sess8.run(["logits"], {"input_values": feat.numpy()})[0]
print(f"INT8 相对 FP32 最大误差 {float(np.abs(o8 - onnx_logits).max()):.4f}")
p8 = torch.tensor(o8).softmax(-1)[0]
print("INT8 top5:", [(cfg.id2label[i], round(v, 4))
                     for v, i in zip(p8.topk(5).values.tolist(), p8.topk(5).indices.tolist())])

ts = []
for _ in range(5):
    t = time.time()
    sess8.run(["logits"], {"input_values": feat.numpy()})
    ts.append(time.time() - t)
print(f"INT8 单次 10s 窗口: 中位 {np.median(ts) * 1000:.0f}ms")

# ---- 7. 导出睡眠类别映射表 ----
print("\n=== 7. 生成睡眠类别映射 ===", flush=True)
SLEEP_MAP = {
    "鼾声":     ["Snoring", "Snort"],
    "呼吸声":   ["Breathing", "Wheeze", "Gasp", "Sigh"],
    "咳嗽清嗓": ["Cough", "Throat clearing", "Sneeze", "Sniff"],
    "人声梦话": ["Speech", "Male speech, man speaking", "Female speech, woman speaking",
                 "Child speech, kid speaking", "Whispering", "Laughter", "Crying, sobbing", "Groan"],
    "体动床响": ["Rustle", "Rustling leaves", "Tap", "Clicking"],
    "环境噪音": ["Noise", "Environmental noise", "White noise", "Traffic noise, roadway noise",
                 "Wind", "Rain", "Door", "Music"],
    "静音":     ["Silence"],
}
name2idx = {v: int(k) for k, v in cfg.id2label.items()}
mapping, missing = {}, []
for cat, names in SLEEP_MAP.items():
    idxs = []
    for n in names:
        if n in name2idx:
            idxs.append(name2idx[n])
        else:
            missing.append(n)
    mapping[cat] = idxs
if missing:
    print("⚠️ 未找到的类别名:", missing)
for cat, idxs in mapping.items():
    print(f"  {cat}: {idxs}")

(OUT / "sleep_class_map.json").write_text(
    json.dumps({"categories": mapping, "id2label": cfg.id2label}, ensure_ascii=False, indent=2),
    encoding="utf-8")

print("\n=== 结论 ===")
print(f"FP32 {mb(onnx_path)} / INT8 {mb(int8_path)}")
print(f"PC CPU 延迟 FP32 {np.median(ts) * 1000:.0f}ms 级 (手机端需实测)")
