"""抓取测试用的音频素材。**全部是 CC0（公共领域）的真实录音。**

    python scripts/fetch_test_audio.py [--check]

从 Openverse 的 API 找 CC0 授权的音频，下载、按模型打分挑，写进
`app/assets/testdata/real/`，同时把出处记进 `scripts/test_audio_sources.json`。

## 为什么不用现成的样本

原来这 6 个文件**全部来自 ESC-50**（CC BY-NC，署名-非商业）：

    snore_01/02/05.wav      ESC-50 的 snoring 类
    rain.wav / rooster.wav  ESC-50 的对照组
    bandlimited_snore.wav   拿 ESC-50 外放之后再录的（衍生作品）

三个问题：**不能进 F-Droid**（只收自由许可的内容）、**打进了 release APK**
（2.3 MB）、非商业限制本身就跟"这 App 是给人用的"别扭。

## 为什么不用合成音频

试过了，**不行**。三种合成方式（抖动脉冲串、扫频共振噪声、两者混合）
× 三个基频，模型给的鼾声概率全是 **0.000~0.015**，最高的判断是
"Music" / "Machine gun" / "Explosion"。

原因不难理解：真实鼾声是软腭拍打产生的**强抖动、带湍流的低频声**，
不是一个稳定的和声堆叠——合成出来的东西在频谱上太"干净"，
CED 模型（AudioSet 上训的）认得出那不是鼾声。

所以**只能用真实录音**，那就必须挑自由许可的。CC0 是最好的：没有署名义务，
没有非商业限制，F-Droid 也不会有意见。

## 挑法

不是随便挑一个就用——**每个候选都先喂给 App 用的那个模型打分**，
只留模型确实判成鼾声的（否则测试断言本身就不成立）。
对照组（雨声、鸡叫）反过来：只留模型**没有**判成鼾声的。

## ⚠️ 高危信号用的是另一套判据，而且这套判据是**循环的**

鼾声那几段验的是"模型觉得它像鼾声"（鼾声那一维的分数 > 0.5）。
信号不一样：它验的是**模型认为这一窗最像的标签就是那个标签**
（527 维里取 argmax == `Gasp` / `Wheeze` / `Pant` / `Snort`），而且分数要够高。
判据必须和 App 一致——App 里信号正是按 `topLabels.first` 取的。

**这是在用模型自己挑样本。** 所以这批 fixture 只能说明一件事：
**这条链路是通的**——真音频进来、模型给出那个标签、信号事件能成立、
能落盘、能回放。它**不能**说明模型在真实睡眠里认得出倒吸气；
那要整夜数据，不是几段素材能回答的问题。写断言时别把这两件事混起来。

另外，**宁缺勿假**：真人喘气/哮鸣的 CC0 素材本来就少，凑不齐就不凑。
拿狗喘气或猪打喷嚏冒充，只会让 fixture 看起来比实际更可信。

## 为什么只存 5 秒、只存 16kHz 单声道

和 App 实际采集的格式一致（`AnalysisConfig.sampleRate`），
测试里就不用再做重采样。5 秒够跑满一个窗口还有余量。
"""

import argparse
import json
import pathlib
import subprocess
import sys
import urllib.parse
import urllib.request

import numpy as np
import soundfile as sf

SR = 16000
CLIP_SECONDS = 5.0
OUT = pathlib.Path(__file__).resolve().parent.parent / 'app' / 'assets' / 'testdata'
SOURCES = pathlib.Path(__file__).resolve().parent / 'test_audio_sources.json'

# 抓下来打分的候选池。宁可多抓几个，因为**能不能用由模型说了算**，
# 不是看标题写得好不好——实测 20 个候选里只有 12 个模型认。
CANDIDATES = [
    ('snore', 'snoring', 'keep'),
    ('rain', 'rain', 'reject'),
    ('rooster', 'rooster crowing', 'reject'),
    # 高危信号。query 挑的是能搜到**真人**素材的说法：
    # 直接搜 'pant' / 'snort' 会翻出成堆的狗和别的东西。
    ('gasp', 'gasping', ('label', 'Gasp')),
    ('wheeze', 'wheezing', ('label', 'Wheeze')),
    ('pant', 'heavy breathing', ('label', 'Pant')),
    ('snort', 'snort', ('label', 'Snort')),
]

# 信号 fixture 的分数下限。比 App 的门槛（lowConfidenceThreshold = 0.25）高一倍，
# 是为了留余量：fixture 要能在模型小幅波动之后还过得了 App 那道闸，
# 卡在门槛上的样本不算好样本。
SIGNAL_MIN_SCORE = 0.5

UA = {'User-Agent': 'sleep-secret-fixtures/1.0 (+https://github.com/14790897/sleep-secret)'}


def api(url):
    return json.load(urllib.request.urlopen(
        urllib.request.Request(url, headers=UA), timeout=40))


def download(url, dest):
    """用 curl 而不是 urllib：这套环境里 urllib 对 cdn.freesound.org
    报证书过期（API 域名却是好的），curl 走系统证书库没这个问题。"""
    return subprocess.run(
        ['curl', '-sS', '--max-time', '90', '-o', str(dest), url],
        capture_output=True).returncode == 0


def load_16k_mono(path):
    x, sr = sf.read(str(path), dtype='float32')
    if x.ndim > 1:
        x = x.mean(axis=1)
    if sr != SR:
        n = int(len(x) * SR / sr)
        x = np.interp(np.linspace(0, len(x) - 1, n), np.arange(len(x)), x)
    return x


def loudest_window(x, seconds=CLIP_SECONDS):
    """取能量最高的那一段。

    抓来的录音动辄一分多钟，里面有大量安静段。随便截一段很可能什么都测不到，
    所以要挑**真的在发声**的那 5 秒。
    """
    win = int(SR * seconds)
    if len(x) <= win:
        return np.pad(x, (0, win - len(x)))
    best, at = -1.0, 0
    for s in range(0, len(x) - win, win // 4):
        e = float((x[s:s + win] ** 2).mean())
        if e > best:
            best, at = e, s
    return x[at:at + win]


def snore_score(model, x):
    return float(model.run(None, {'waveform': x[None, :].astype(np.float32)})[0][0][43])


def score_all(model, id2label, x):
    """跑一次，返回 (argmax 标签名, 该标签的分数)。

    信号验收要的是 **argmax**，不是某一维的分数——App 里信号正是按
    `prediction.topLabels.first` 取的，两边必须用同一套判据，
    否则 fixture 过得了脚本、过不了 App。
    """
    r = model.run(None, {'waveform': x[None, :].astype(np.float32)})[0][0]
    top = int(np.argmax(r))
    return id2label[str(top)], float(r[top])


def make_bandlimited(rng, x):
    """把低频削掉、再压上房间噪声——模拟"手机没放在枕边、隔着半米"的情形。

    鼾声的能量集中在 60~300 Hz，一旦这条被削掉，模型能拿到的只剩谐波和失真。
    原来那个 `mic_farfield_snore.wav` 是把鼾声从笔记本扬声器放出来再隔着房间录，
    得到的是同样的困难；这里直接把这个困难造出来，省掉一次录音。
    """
    def bp(sig, lo, hi):
        X = np.fft.rfft(sig)
        f = np.fft.rfftfreq(len(sig), 1 / SR)
        w = max((hi - lo) * 0.15, 20.0)
        return np.fft.irfft(X * (np.clip((f - lo) / w, 0, 1) *
                                 np.clip((hi - f) / w, 0, 1)), n=len(sig))

    limited = bp(x, 320, 4000)
    room = bp(rng.normal(0, 1, len(limited)), 100, 5000)
    rms = np.sqrt((limited ** 2).mean())
    room *= rms / (np.sqrt((room ** 2).mean()) + 1e-9)
    mix = limited + 0.5 * room
    return mix * (0.5 / (np.abs(mix).max() + 1e-9))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true', help='跑模型把结果打出来')
    ap.add_argument('--slots', default='', help='只抓这几个槽位（逗号分隔），默认全部。'
                                               '加素材时用它，别顺手把现有素材重挑一遍')
    args = ap.parse_args()

    import onnxruntime as ort

    model = ort.InferenceSession(
        str((OUT / '..' / 'models' / 'ced-tiny.onnx').resolve()),
        providers=['CPUExecutionProvider'])
    cmap = json.loads((OUT / '..' / 'models' / 'sleep_class_map.json')
                      .resolve().read_text(encoding='utf-8'))

    work = pathlib.Path(__file__).resolve().parent.parent / 'build' / 'test_audio'
    work.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(20261007)
    picked = {}
    raw = {}

    # 出处文件是**累计**的，不是每次重写。只抓某几个槽位时，其余槽位的出处
    # 必须原地保留——否则跑一次 `--slots gasp`，鼾声那几段的出处就没了，
    # 而许可证信息丢了是**没法从音频文件本身找回来**的。
    sources = (json.loads(SOURCES.read_text(encoding='utf-8'))
               if SOURCES.exists() else {})

    wanted_slots = {s.strip() for s in args.slots.split(',') if s.strip()}
    todo = [c for c in CANDIDATES if not wanted_slots or c[0] in wanted_slots]

    id2label = cmap['id2label']

    for slot, query, want in todo:
        is_signal = isinstance(want, tuple)
        keep_upto = 3 if want == 'keep' else 1
        # 这一槽位重挑，出处也重记——不能和上一次的结果累加
        sources[slot] = []
        print(f'\n== {slot}（{query}）==')
        # ⚠️ `page_size` 上限是 **20**（匿名调用），写大了会直接 401，
        # 而不是返回一个错误信息——第一次改这个脚本就栽在这儿。
        # 想要更多候选就翻页。
        results = []
        for page in (1, 2 if is_signal else 1):
            try:
                results += api('https://api.openverse.org/v1/audio/'
                               f'?q={urllib.parse.quote(query)}&license=cc0'
                               f'&page_size=20&page={page}')['results']
            except Exception as e:
                print(f'  第 {page} 页取不到（{e}），已有的接着用')
                break
        found = 0
        for r in results:
            url = r.get('url') or ''
            # ⚠️ 不能只收 .mp3：真人喘息/倒吸气的 CC0 素材里 .wav 占一大半，
            # 只认 mp3 会把好不容易搜到的样本全滤掉。
            if not url.lower().endswith(('.mp3', '.wav', '.flac', '.ogg')) \
                    or found >= keep_upto:
                continue
            tmp = work / f'{r["id"]}{pathlib.Path(url).suffix.lower()}'
            if not tmp.exists() and not download(url, tmp):
                continue
            try:
                x = loudest_window(load_16k_mono(tmp))
            except Exception:
                continue
            if float(np.abs(x).max()) < 1e-4:
                continue
            if is_signal:
                target = want[1]
                top, top_score = score_all(model, id2label, x)
                s = top_score if top == target else 0.0
                ok = top == target and top_score >= SIGNAL_MIN_SCORE
                print(f'  {"✓" if ok else " "} 想要={target:7s} 实得={top:24s}'
                      f' {top_score:.3f}  {r["title"][:28]:30s} {r["creator"][:16]}')
            else:
                s = snore_score(model, x)
                ok = (s > 0.5) if want == 'keep' else (s < 0.1)
                print(f'  {"✓" if ok else " "} 鼾声={s:.3f}  {r["title"][:34]:36s}'
                      f' {r["creator"][:18]}')
            if not ok:
                continue
            picked.setdefault(slot, []).append(x)
            raw.setdefault(slot, []).append(tmp)
            sources.setdefault(slot, []).append({
                'title': r['title'], 'creator': r['creator'],
                'license': r['license'].upper(), 'license_version': r['license_version'],
                'source': r['foreign_landing_url'],
                # 信号槽位记的是「模型把它认成了什么、多少分」，鼾声槽位记的是
                # 鼾声那一维的分数——这两件事不是一回事，键名不能混。
                **({'matched_label': top, 'score': round(s, 3)} if is_signal
                   else {'snore_score': round(s, 3)}),
            })
            found += 1

    # 只在真的重抓鼾声时才卡这条。加信号素材的时候不该被它挡住——
    # 那会让「只补一段喘气」变成「必须把鼾声素材也重挑一遍」。
    if (not wanted_slots or 'snore' in wanted_slots) \
            and len(picked.get('snore', [])) < 3:
        print('\n✗ 鼾声样本不够 3 个，没凑齐就别改素材')
        return 1

    names = {'snore': ['snore_01', 'snore_02', 'snore_05'], 'rain': ['rain'],
             'rooster': ['rooster'],
             # 每个信号只留一段——它们验的是同一条链路，
             # 多留几段的价值有限，而每多一段就往 APK 里多塞 160 KB。
             'gasp': ['real_gasp'], 'wheeze': ['real_wheeze'],
             'pant': ['real_pant'], 'snort': ['real_snort']}
    written = {}
    for slot, clips in picked.items():
        for name, x in zip(names[slot], clips):
            p = OUT / 'real' / f'{name}.wav'
            p.parent.mkdir(parents=True, exist_ok=True)
            sf.write(p, x.astype(np.float32), SR, subtype='PCM_16')
            written[name] = p
            print(f'写出 {p.relative_to(OUT.parent.parent.parent)}')

    # 远场那个是从一段真实鼾声加工来的，出处跟着原样本。
    # 只在这次真的抓了鼾声时才重造——`--slots gasp` 不该动它。
    if 'snore' in picked:
        far = OUT / 'real' / 'bandlimited_snore.wav'
        far.parent.mkdir(parents=True, exist_ok=True)
        # 这段要 **30 秒**而不是 5 秒：测它的那条用例要跑满十几个窗口，
        # 5 秒只够跑一两个，覆盖不到"长时间低信噪比输入"这件事。
        long_snore = loudest_window(load_16k_mono(raw['snore'][0]), seconds=30.0)
        sf.write(far, make_bandlimited(rng, long_snore).astype(np.float32),
                 SR, subtype='PCM_16')
        sources['bandlimited_snore'] = [{
            'derived_from': sources['snore'][0]['source'],
            'note': '削掉 320Hz 以下再压上 -6dB 房间噪声，模拟手机不放在枕边',
        }]
        print(f'写出 {far.relative_to(OUT.parent.parent.parent)}')

    # 没抓到信号的槽位不写空条目——「没找到」和「找到了但没用」得分开，
    # 所以宁可在输出里明说，也不留个空数组让人以为查过。
    sources = {k: v for k, v in sources.items() if v}

    SOURCES.write_text(json.dumps(sources, ensure_ascii=False, indent=2),
                       encoding='utf-8')
    print(f'\n出处记在 {SOURCES.relative_to(SOURCES.parent.parent)}')

    if args.check:
        print('\n各文件最终得分：')
        for name in ['snore_01', 'snore_02', 'snore_05', 'rain', 'rooster',
                     'bandlimited_snore', 'real_gasp', 'real_wheeze',
                     'real_pant', 'real_snort']:
            path = OUT / 'real' / f'{name}.wav'
            if not path.exists():
                continue
            x = load_16k_mono(path)
            # ⚠️ 截到 10 秒再喂。模型在 17 万~25 万采样点这个区间**会崩**
            # （ONNX 的广播形状对不上，App 那边也踩过同一个坑，见
            # `SleepAnalysisRepository` 里的 _maxInputSamples）。
            # 不截的话，30 秒的 bandlimited_snore 一跑就抛异常，
            # 而它一抛，**后面所有文件的分数都打不出来**——第一次就是这样
            # 白等了一轮。
            x = x[:SR * 10]
            r = model.run(None, {'waveform': x[None, :].astype(np.float32)})[0][0]
            cat = {k: float(max(r[i] for i in v))
                   for k, v in cmap['categories'].items()}
            top_i = int(np.argmax(r))
            print(f'  {name:20s} 最高={id2label[str(top_i)]:22s} {r[top_i]:.3f}  '
                  f'核心鼾声={r[43]:.3f}  ' +
                  '  '.join(f'{k}={v:.2f}' for k, v in cat.items()))
    return 0


if __name__ == '__main__':
    sys.exit(main())
