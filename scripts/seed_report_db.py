"""生成多晚仿真数据，推进模拟器里的 App 数据库。

**仅用于界面截图。** 这不是真实分析结果——模拟器录不到有效声音，
没有数据就看不出报告页和趋势图的版式。

数据刻意做得像真实记录：鼾声成串出现、后半夜更密集，
整体呈"慢慢变好"的走势，这样趋势图才看得出方向。
"""
import datetime as dt
import math
import pathlib
import random
import sqlite3
import struct
import wave

SCHEMA_VERSION = 2   # 必须与 SessionDatabase.schemaVersion 一致

OUT = pathlib.Path(__file__).resolve().parent.parent / 'build' / 'seed_report.db'
CLIPS = pathlib.Path(__file__).resolve().parent.parent / 'build' / 'seed_clips'
OUT.parent.mkdir(parents=True, exist_ok=True)
if OUT.exists():
    OUT.unlink()
if CLIPS.exists():
    import shutil
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
  snore_seconds REAL NOT NULL DEFAULT 0
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
  clip_path TEXT
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
                           rng.uniform(0.5, 0.94), rng.uniform(0.45, 0.92)))

    for label, count, dur_range, conf in [
        ('cough', 4 + int(severity * 4), (9, 24), (0.4, 0.8)),
        ('vocal', 2 + int(severity * 3), (18, 90), (0.35, 0.7)),
        ('movement', 8 + int(severity * 6), (6, 30), (0.3, 0.65)),
    ]:
        for _ in range(count):
            events.append((label, rng.uniform(0, duration - 120),
                           rng.uniform(*dur_range),
                           rng.uniform(*conf), rng.uniform(0, 0.25)))

    for _ in range(5):
        events.append(('breathing', rng.uniform(0, duration - 400),
                       rng.uniform(120, 360), rng.uniform(0.4, 0.75), 0.05))

    events.sort(key=lambda e: e[1])
    return duration, events


# 7 晚，鼾声程度逐步下降
NIGHTS = [
    (dt.datetime(2026, 9, 30, 23, 15), 0.95),
    (dt.datetime(2026, 10, 1, 23, 40), 0.88),
    (dt.datetime(2026, 10, 2, 22, 55), 0.92),
    (dt.datetime(2026, 10, 3, 23, 30), 0.70),
    (dt.datetime(2026, 10, 4, 23, 55), 0.62),
    (dt.datetime(2026, 10, 5, 23, 20), 0.45),
    (dt.datetime(2026, 10, 6, 23, 12), 0.38),
]

for idx, (start_dt, severity) in enumerate(NIGHTS):
    duration, events = make_night(start_dt, severity, seed=1000 + idx)
    start_ms = int(start_dt.timestamp() * 1000)

    snore_events = [e for e in events if e[0] == 'snore']
    snore_seconds = sum(e[2] for e in snore_events)
    windows_total = duration // 3
    windows_inferred = int(windows_total * (0.30 + severity * 0.08))

    cur.execute("""
    INSERT INTO sessions (started_at, ended_at, analyzed_seconds, windows_total,
      windows_inferred, windows_vad_skipped, windows_low_confidence,
      event_count, snore_event_count, snore_seconds)
    VALUES (?,?,?,?,?,?,?,?,?,?)
    """, (start_ms, start_ms + duration * 1000, duration, windows_total,
          windows_inferred, windows_total - windows_inferred,
          int(windows_inferred * 0.82), len(events), len(snore_events),
          snore_seconds))

    session_id = cur.lastrowid
    is_last_night = idx == len(NIGHTS) - 1

    for clip_index, (label, start, dur, conf, snore) in enumerate(events):
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
          confidence, snore_probability, window_count, clip_path)
        VALUES (?,?,?,?,?,?,?,?)
        """, (session_id, label, start, dur, conf, snore,
              max(1, round(dur / 3)), clip_path))

    print(f'  {start_dt:%m-%d} severity={severity:.2f}  '
          f'{len(events):3d} 事件  鼾声 {len(snore_events):2d} 段 '
          f'{snore_seconds / 60:5.1f} 分钟  '
          f'指数 {snore_seconds / duration * 100:5.2f}%')

# sqflite 把 schema 版本存在 PRAGMA user_version 里。不设的话它会认为
# 版本为 0，与代码里的 version: 1 对不上，于是当成新库处理 —— 表就在眼前
# 却读不到任何数据。
# 默认开着片段记录，与应用默认值一致
cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES ('record_clips', 'true')")

cur.execute(f'PRAGMA user_version = {SCHEMA_VERSION}')

conn.commit()
conn.close()
print(f'\n已生成 {OUT}（{len(NIGHTS)} 晚）')
