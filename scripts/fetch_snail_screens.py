"""从 App Store 页面抓蜗牛睡眠的界面截图 URL。"""
import re
import urllib.request

URL = 'https://apps.apple.com/cn/app/id1025313530'
HEADERS = {'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'}

req = urllib.request.Request(URL, headers=HEADERS)
html = urllib.request.urlopen(req, timeout=60).read().decode('utf-8', 'ignore')
print('页面长度', len(html))

pattern = r'https://is\d-ssl\.mzstatic\.com/image/thumb/[^"\\ ]+'
found = re.findall(pattern, html)

seen = set()
ordered = []
for u in found:
    u = u.split('\\')[0]
    if u not in seen:
        seen.add(u)
        ordered.append(u)

print('找到', len(ordered), '个图片 URL')
for u in ordered[:20]:
    print(' ', u[:170])
