"""下载 ESC-50 里的真实鼾声样本，用来验证"模型认不认得出真实鼾声"。

之前所有验证都只用合成音频，模型对合成信号的响应接近均匀分布——
那验证的是"链路通不通"，不是"识别准不准"。真实鼾声样本能补上这一环。

ESC-50 是 CC BY-NC（署名-非商业性使用）。仅用于本地效果验证，不要商用。
"""
import pathlib

OUT = pathlib.Path(__file__).resolve().parent.parent / 'testdata' / 'snore_esc50'
OUT.mkdir(parents=True, exist_ok=True)

WANTED = 6

print('从 HuggingFace 流式拉取 ESC-50 的 snoring 类…', flush=True)

from datasets import Audio, load_dataset  # noqa: E402

ds = load_dataset('ashraq/esc50', split='train', streaming=True)
# 不装 torchcodec，直接拿原始文件字节自己解——省掉一个很重的依赖
ds = ds.cast_column('audio', Audio(decode=False))

saved = 0
checked = 0
for row in ds:
    checked += 1
    if row['category'] != 'snoring':
        continue

    raw = row['audio']
    data = raw.get('bytes')
    if not data:
        continue

    path = OUT / f'snore_{saved:02d}.wav'
    path.write_bytes(data)
    saved += 1
    if saved >= WANTED:
        break
    if checked > 4000:
        break

print(f'\n扫描 {checked} 条，保存 {saved} 段到 {OUT}')
for p in sorted(OUT.glob('*.wav')):
    import soundfile as sf
    info = sf.info(str(p))
    print(f'  {p.name}  {info.duration:.1f}s  {info.samplerate}Hz')
