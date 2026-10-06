"""下游处理：校验已导出的 FP32 ONNX，并产出移动端可用的量化版本。

- 正确性校验：同一输入下 ONNX 与 PyTorch 必须一致
- 绕开 onnx.shape_inference 的 value_info 冲突（dynamo 导出的图会与推断形状打架）
- 产出 INT8 / FP16 两种候选，报告体积
"""
import pathlib
import shutil

import numpy as np
import onnx
import torch

OUT = pathlib.Path(__file__).parent / "out"
FP32 = OUT / "ast-e2e-fp32.onnx"
MODEL_ID = "MIT/ast-finetuned-audioset-10-10-0.4593"
N_SAMPLES = 164080


def mb(p):
    p = pathlib.Path(p)
    total = p.stat().st_size
    ext = pathlib.Path(str(p) + ".data")
    if ext.exists():
        total += ext.stat().st_size
    return total / 1024 / 1024


def main():
    import onnxruntime as ort
    from transformers import ASTFeatureExtractor, ASTForAudioClassification

    print("=== 1. 正确性校验（同一输入）===", flush=True)
    fe = ASTFeatureExtractor.from_pretrained(MODEL_ID)
    ast = ASTForAudioClassification.from_pretrained(MODEL_ID).eval()

    rng = np.random.default_rng(0)
    wav = (rng.standard_normal(N_SAMPLES) * 0.05).astype(np.float32)

    with torch.no_grad():
        ref = ast(fe(wav, sampling_rate=16000, return_tensors="pt").input_values).logits.numpy()

    sess = ort.InferenceSession(str(FP32), providers=["CPUExecutionProvider"])
    o = sess.run(["logits"], {"waveform": wav[None, :]})[0]

    cos = float(np.dot(ref[0], o[0]) / (np.linalg.norm(ref[0]) * np.linalg.norm(o[0])))
    print(f"最大绝对差 {np.abs(ref - o).max():.5f}   余弦相似度 {cos:.6f}")
    ok = cos > 0.9999
    print("ONNX 与 PyTorch 一致:", "✅" if ok else "❌")
    if not ok:
        print("⚠️ 图不可信，停止。")
        return

    # 顺带确认关键类别可被正确排序
    p = torch.tensor(o).softmax(-1)[0]
    top = p.topk(5)
    print("ONNX top5:", [(ast.config.id2label[i], round(v, 4)) for v, i in
                        zip(top.values.tolist(), top.indices.tolist())])

    print(f"\nFP32 总体积 {mb(FP32):.1f} MB（图 + .data 权重）")

    # ---- 2. 合并为单文件（移动端部署更省事）----
    print("\n=== 2. 合并为单文件 ===", flush=True)
    merged = OUT / "ast-single.onnx"
    m = onnx.load(str(FP32))          # 会自动加载 external data
    onnx.save(m, str(merged), save_as_external_data=False)
    print(f"单文件体积 {merged.stat().st_size / 1024 / 1024:.1f} MB")

    # ---- 3. 清掉 value_info，绕开 shape_inference 冲突 ----
    print("\n=== 3. 清理 value_info ===", flush=True)
    before = len(m.graph.value_info)
    del m.graph.value_info[:]
    cleaned = OUT / "ast-clean.onnx"
    onnx.save(m, str(cleaned), save_as_external_data=False)
    print(f"移除 {before} 条 value_info 记录 -> {cleaned.stat().st_size / 1024 / 1024:.1f} MB")

    # ---- 4. INT8 动态量化 ----
    print("\n=== 4. INT8 动态量化 ===", flush=True)
    from onnxruntime.quantization import quantize_dynamic, QuantType
    int8 = OUT / "ast-int8.onnx"
    try:
        quantize_dynamic(str(cleaned), str(int8), weight_type=QuantType.QInt8)
        print(f"INT8 体积 {int8.stat().st_size / 1024 / 1024:.1f} MB")
    except Exception as e:
        print(f"❌ 量化失败: {type(e).__name__}: {e}")
        int8 = None

    # ---- 5. FP16 转换（备选：精度损失更小）----
    print("\n=== 5. FP16 转换 ===", flush=True)
    fp16 = OUT / "ast-fp16.onnx"
    try:
        from onnxconverter_common import float16 as onnx_fp16
        mm = onnx_fp16.convert_float_to_float16(onnx.load(str(cleaned)), keep_io_types=True)
        onnx.save(mm, str(fp16), save_as_external_data=False)
        print(f"FP16 体积 {fp16.stat().st_size / 1024 / 1024:.1f} MB")
    except ImportError:
        print("(未安装 onnxconverter-common，跳过 FP16)")
        fp16 = None
    except Exception as e:
        print(f"FP16 失败: {type(e).__name__}: {e}")
        fp16 = None

    # ---- 6. 量化后精度对比 ----
    print("\n=== 6. 量化后精度 & 延迟 ===", flush=True)
    import time

    def bench(path, label):
        s = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
        r = s.run(["logits"], {"waveform": wav[None, :]})[0]
        c = float(np.dot(ref[0], r[0]) / (np.linalg.norm(ref[0]) * np.linalg.norm(r[0])))
        pr = torch.tensor(r).softmax(-1)[0]
        t = pr.topk(1)
        for _ in range(2):
            s.run(["logits"], {"waveform": wav[None, :]})
        ts = []
        for _ in range(5):
            st = time.time()
            s.run(["logits"], {"waveform": wav[None, :]})
            ts.append(time.time() - st)
        print(f"{label:6s} 体积 {mb(path):6.1f}MB  余弦 {c:.6f}  "
              f"top1={ast.config.id2label[int(t.indices[0])]}  延迟中位 {np.median(ts) * 1000:.0f}ms")
        return c

    bench(FP32, "FP32")
    if int8:
        bench(int8, "INT8")
    if fp16:
        bench(fp16, "FP16")


if __name__ == "__main__":
    main()
