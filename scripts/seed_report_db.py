"""生成仿真数据，推进模拟器里的 App 数据库。

**仅用于界面截图。** 这不是真实分析结果——模拟器录不到有效声音，
没有数据就看不出报告页和趋势图的版式。

数据刻意做得像真实记录：鼾声成串出现、后半夜更密集，
整体呈"慢慢变好"的走势，这样趋势图才看得出方向。

    python scripts/seed_report_db.py [--locale en]

`--locale` 写进设置表的 `app_locale`（`zh` / `en` / 不写＝跟随系统），
用来拍两套语言的截图。**界面语言不必改模拟器的系统语言**——
App 自己那个「语言」开关读的就是这一行。

## 拍截图这一整套（2026-10-08 走通过一遍）

```bash
# 1. 起模拟器。headless 不会在桌面上弹窗。
emulator -avd sleep_light -no-window -no-audio -no-boot-anim -gpu swiftshader_indirect

# 2. 装**发布版**（截图就该截用户拿到的东西），x86_64 那个包
adb -s emulator-5554 install -r app-x86_64-release.apk

# 3. 先跑一次应用把目录建出来，然后推进去
python scripts/seed_report_db.py --locale en
adb -s emulator-5554 root
adb -s emulator-5554 push build/seed_report.db /data/local/tmp/seed.db
#    → cp 到 /data/data/<pkg>/databases/sleep_secret.db
#    → cp -r build/seed_clips 到 /data/data/<pkg>/files/clips
#    → chown -R <uid>:<uid> + chcon -R $(ls -Zd <目录> | awk '{print $1}')
#      ⚠️ restorecon 给的 category 和目录本身不一样，应用读不了

# 4. 演示状态栏：满电、固定 23:10、无通知
adb shell settings put global sysui_demo_allowed 1
adb shell am broadcast -a com.android.systemui.demo -e command enter
adb shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 2310
adb shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false
adb shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false
```

⚠️ **模拟器的时区要设成 Asia/Shanghai**，否则报告的日期差 8 小时
（会显示成前一晚，和中文那套截图对不上）。

⚠️ Git Bash 下 `adb push ... /data/...` 会被改写成 `C:/Program Files/Git/data/...`
——**加 `MSYS_NO_PATHCONV=1`**。

⚠️ 有多个设备时必须 `-s <serial>`：不指定的话 `adb shell` 直接报错，
而 `pidof`/`getprop` 之类的循环会因此永远等下去。

## 数据长什么样

`SCHEMA_VERSION` 必须与 `SessionDatabase.schemaVersion` 一致。
它曾经停在 2，而 App 已经到 5：版本号对不上时 sqflite 会当成**新库**
处理，表就在眼前却读不到数据；而缺的那几列（`signals_collected`、
`raw_label_counts`、`signal`、`peak_rms`）会让「详细视图」和高危信号卡
显示成「升级前的记录不收集这些」——截图里就成了空页面。
"""
import argparse
import datetime as dt
import json
import math
import pathlib
import random
import shutil
import sqlite3
import struct
import wave

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--locale', choices=['zh', 'en'], default=None,
                    help='写进设置表的界面语言；不写＝跟随系统')
args = parser.parse_args()

SCHEMA_VERSION = 5   # 必须与 SessionDatabase.schemaVersion 一致

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / 'build' / 'seed_report.db'
CLIPS = ROOT / 'build' / 'seed_clips'

# 标签计数从**真实的映射表**里取，不手写标签名：
# 手写的迟早会和 sleep_classes.py 对不上，而截图里那一页正是给人核对
# 「模型说了什么 vs 我们归到哪一类」的，用假的会误导。
_CLASS_MAP = json.loads(
    (ROOT / 'app' / 'assets' / 'models' / 'sleep_class_map.json')
    .read_text(encoding='utf-8'))
ID2LABEL = {int(k): v for k, v in _CLASS_MAP['id2label'].items()}
CATEGORY_LABELS = {
    cat: [ID2LABEL[i] for i in ids] for cat, ids in _CLASS_MAP['categories'].items()
}
MAPPED = {label for labels in CATEGORY_LABELS.values() for label in labels}
UNMAPPED = [label for label in ID2LABEL.values() if label not in MAPPED]

# 事件大类 → 用来生成「原始标签计数」的 AudioSet 标签（每个大类取前两个）
LABEL_POOL = {cat: labels[:2] for cat, labels in CATEGORY_LABELS.items()}

OUT.parent.mkdir(parents=True, exist_ok=True)
if OUT.exists():
    OUT.unlink()
if CLIPS.exists():
    shutil.rmtree(CLIPS)
CLIPS.mkdir(parents=True)


def write_snore_wav(path: pathlib.Path, seconds: float, seed: int) -> None:
    """合成一段低频周期性声音，只为验证"能存能播"这条链路。

    不是真实鼾声，听感上也不像——它存在的意义是让播放按钮有东西可放。
    """
    rng = random.Random(seed)
    rate = 16000
    n = int(rate * seconds)
    frames = bytearray()
    for i in range(n):
        t = i / rate
        # 约 0.3Hz 的呼吸包络 + 60~90Hz 的基频，加一点噪声
        env = 0.5 + 0.5 * math.sin(2 * math.pi * 0.3 * t)
        base = 60 + 30 * math.sin(2 * math.pi * 0.07 * t)
        v = 0.28 * env * math.sin(2 * math.pi * base * t)
        v += 0.02 * rng.uniform(-1, 1)
        frames += struct.pack('<h', int(max(-1.0, min(1.0, v)) * 32767))
    with wave.open(str(path), 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(frames))

conn = sqlite3.connect(OUT)
cur = conn.cursor()
cur.executescript("""
CREATE TABLE sessions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at INTEGER NOT NULL,
  ended_at INTEGER,
  analyzed_seconds REAL NOT NULL DEFAULT 0,
  windows_total INTEGER NOT NULL DEFAULT 0,
  windows_inferred INTEGER NOT NULL DEFAULT 0,
  windows_vad_skipped INTEGER NOT NULL DEFAULT 0,
  windows_low_confidence INTEGER NOT NULL DEFAULT 0,
  event_count INTEGER NOT NULL DEFAULT 0,
  snore_event_count INTEGER NOT NULL DEFAULT 0,
  snore_seconds REAL NOT NULL DEFAULT 0,
  signals_collected INTEGER,
  raw_label_counts TEXT
);
CREATE TABLE events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id INTEGER NOT NULL,
  label TEXT NOT NULL,
  start_seconds REAL NOT NULL,
  duration_seconds REAL NOT NULL,
  confidence REAL NOT NULL,
  snore_probability REAL NOT NULL,
  window_count INTEGER NOT NULL,
  clip_path TEXT,
  peak_rms REAL,
  signal TEXT
);
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
""")


def make_night(day: dt.datetime, severity: float, seed: int):
    """severity 0..1：越大鼾声越多越密。"""
    rng = random.Random(seed)
    duration = int((7 * 3600 + rng.randint(0, 90) * 60))
    events = []

    episode_count = max(1, round(2 + severity * 5))
    for k in range(episode_count):
        lo = 0.05 + (0.9 / episode_count) * k
        span = 0.9 / episode_count
        base = lo * duration
        width = span * duration * 0.7
        per_episode = max(1, round(2 + severity * 6))
        for i in range(per_episode):
            start = base + (width * i / max(per_episode - 1, 1))
            start += rng.uniform(-40, 40)
            dur = rng.choice([18, 25, 35, 50, 75, 110, 150, 210]) * (0.6 + severity)
            events.append(('snore', max(0.0, start), dur,
                           rng.uniform(0.5, 0.94), rng.uniform(0.45, 0.92), None))

    for label, count, dur_range, conf in [
        ('cough', 4 + int(severity * 4), (9, 24), (0.4, 0.8)),
        ('vocal', 2 + int(severity * 3), (18, 90), (0.35, 0.7)),
        ('movement', 8 + int(severity * 6), (6, 30), (0.3, 0.65)),
    ]:
        for _ in range(count):
            events.append((label, rng.uniform(0, duration - 120),
                           rng.uniform(*dur_range),
                           rng.uniform(*conf), rng.uniform(0, 0.25), None))

    for _ in range(5):
        events.append(('breathing', rng.uniform(0, duration - 400),
                       rng.uniform(120, 360), rng.uniform(0.4, 0.75), 0.05, None))

    # 高危信号：倒吸气。真实一晚就那么几声，而且很短（一两秒）——
    # 它们靠 SoundEvent.signal 豁免「事件最短时长」，报告里那张
    # 「疑似呼吸暂停的信号」卡就是拿它渲染的。没有它，那张卡是空的。
    for _ in range(rng.randint(1, 3)):
        events.append(('breathing', rng.uniform(200, duration - 200),
                       rng.uniform(1.2, 2.5), rng.uniform(0.45, 0.8), 0.02, 'Gasp'))

    events.sort(key=lambda e: e[1])
    return duration, events


def label_counts_for(events, rng):
    """这一晚每个 AudioSet 原始标签当冠军的次数——「详细视图」渲染的就是它。

    从事件反推：每条事件的窗口数记到它所属大类的一个标签上，再掺两个
    **没归进任何大类**的标签进去（真实数据里一定有，那一页的「未映射」
    列就是给它们准备的）。
    """
    counts = {}
    for label, _start, dur, _conf, _snore, _signal in events:
        pool = LABEL_POOL.get(label, [])
        if not pool:
            continue
        picked = pool[0] if rng.random() < 0.7 else pool[-1]
        counts[picked] = counts.get(picked, 0) + max(1, round(dur / 3))
    for unmapped in rng.sample(UNMAPPED, 2):
        counts[unmapped] = counts.get(unmapped, 0) + rng.randint(3, 40)
    return counts


# 两晚，第二晚明显更重——趋势图要能看出方向（截图里那条线是往上走的）
NIGHTS = [
    (dt.datetime(2026, 10, 7, 0, 23), 0.30),
    (dt.datetime(2026, 10, 8, 0, 37), 0.62),
]

for idx, (start_dt, severity) in enumerate(NIGHTS):
    duration, events = make_night(start_dt, severity, seed=1000 + idx)
    start_ms = int(start_dt.timestamp() * 1000)
    rng = random.Random(7000 + idx)

    snore_events = [e for e in events if e[0] == 'snore']
    snore_seconds = sum(e[2] for e in snore_events)
    windows_total = duration // 3
    windows_inferred = int(windows_total * (0.30 + severity * 0.08))
    counts = label_counts_for(events, rng)

    cur.execute("""
    INSERT INTO sessions (started_at, ended_at, analyzed_seconds, windows_total,
      windows_inferred, windows_vad_skipped, windows_low_confidence,
      event_count, snore_event_count, snore_seconds,
      signals_collected, raw_label_counts)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
    """, (start_ms, start_ms + duration * 1000, duration, windows_total,
          windows_inferred, windows_total - windows_inferred,
          int(windows_inferred * 0.82), len(events), len(snore_events),
          snore_seconds, 1, json.dumps(counts, ensure_ascii=False)))

    session_id = cur.lastrowid
    is_last_night = idx == len(NIGHTS) - 1

    for clip_index, (label, start, dur, conf, snore, signal) in enumerate(events):
        clip_path = None

        # 只给最近一晚的鼾声段生成片段，模拟"开着片段开关录的那一晚"。
        # 切片范围与 App 的 AnalysisConfig.clipRangeFor 一致：
        # 前后各留 1 秒余量，总长封顶 20 秒（从末尾往前推）。
        if is_last_night and label == 'snore':
            end_s = start + dur + 1.0
            begin_s = max(start - 1.0, end_s - 20.0, 0.0)
            length = end_s - begin_s
            if length >= 3:
                rel_dir = CLIPS / str(start_ms)
                rel_dir.mkdir(parents=True, exist_ok=True)
                file_name = f'{int(begin_s * 1000)}.wav'
                write_snore_wav(rel_dir / file_name, length,
                                seed=5000 + clip_index)
                clip_path = f'{start_ms}/{file_name}'

        cur.execute("""
        INSERT INTO events (session_id, label, start_seconds, duration_seconds,
          confidence, snore_probability, window_count, clip_path,
          peak_rms, signal)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """, (session_id, label, start, dur, conf, snore,
              max(1, round(dur / 3)), clip_path,
              rng.uniform(0.02, 0.35), signal))

    print(f'  {start_dt:%m-%d} severity={severity:.2f}  '
          f'{len(events):3d} 事件  鼾声 {len(snore_events):2d} 段 '
          f'{snore_seconds / 60:5.1f} 分钟  '
          f'指数 {snore_seconds / duration * 100:5.2f}%')

# sqflite 把 schema 版本存在 PRAGMA user_version 里。不设的话它会认为
# 版本为 0，与代码里的 version: 1 对不上，于是当成新库处理 —— 表就在眼前
# 却读不到任何数据。
# 默认开着片段记录，与应用默认值一致
cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('record_clips', 'true')")

# 界面语言。写的是 App 自己那个「语言」开关读的键（见 LocaleRepository），
# 所以不需要改模拟器的系统语言，也不用重启 zygote。
if args.locale:
    cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('app_locale', ?)",
                (args.locale,))

cur.execute(f'PRAGMA user_version = {SCHEMA_VERSION}')

conn.commit()
conn.close()
print(f'\n已生成 {OUT}（{len(NIGHTS)} 晚）'
      + (f'，界面语言 {args.locale}' if args.locale else '，界面语言跟随系统'))
