"""下载蜗牛睡眠的界面截图（App Store 上的宣传图）。"""
import pathlib
import re
import urllib.request

URL = 'https://apps.apple.com/cn/app/id1025313530'
HEADERS = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}
OUT = pathlib.Path(__file__).resolve().parent.parent / 'screenshots' / 'snail'
OUT.mkdir(parents=True, exist_ok=True)

html = urllib.request.urlopen(
    urllib.request.Request(URL, headers=HEADERS), timeout=60
).read().decode('utf-8', 'ignore')

# base 路径本身含斜杠（PurpleSource211/v4/e1/30/11/...），
# 所以要用非贪婪匹配跨越到文件名前
bases = re.findall(
    r'https://is\d-ssl\.mzstatic\.com/image/thumb/(.+?)/(5-8_\d+\.jpg)/',
    html,
)
seen = {}
for base, name in bases:
    seen.setdefault(name, base)

print(f'共 {len(seen)} 张不同的宣传截图')

for name, base in sorted(seen.items()):
    url = f'https://is1-ssl.mzstatic.com/image/thumb/{base}/{name}/600x1300bb.jpg'
    target = OUT / name
    try:
        data = urllib.request.urlopen(
            urllib.request.Request(url, headers=HEADERS), timeout=60
        ).read()
        target.write_bytes(data)
        print(f'  {name}  {len(data) / 1024:.0f} KB')
    except Exception as e:
        print(f'  {name}  FAIL {type(e).__name__}: {e}')

print(f'\n保存到 {OUT}')
