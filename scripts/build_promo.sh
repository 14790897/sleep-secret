#!/usr/bin/env bash
# 把模拟器录屏拼成宣传视频。
#
# 分两步：先把每段渲成**参数一致**的 mp4（720×1560 / 30fps / yuv420p），
# 再 concat。一步到位写成一个 filter_complex 也能做，但出问题时根本没法查
# 是哪一段坏了。
#
#   用法：bash scripts/build_promo.sh
set -e

FF=/c/Users/13963/AppData/Local/Microsoft/WinGet/Packages/Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe/ffmpeg-8.1.1-full_build/bin/ffmpeg
P=build/promo
OUT=$P/sleep-secret-promo.mp4

# 每段的公共编码参数。不加 -an 的话 concat 会因为音轨不一致失败。
ENC=(-c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -r 30 -an)

# 字幕统一叠在这儿：底部往上一点，避开发丝线，也不挡时间/波形。
CAP_Y=1240

cap() { echo "$P/$1.png"; }

echo "① 标题卡"
"$FF" -v error -y -loop 1 -t 3 -i "$P/card_title.png" \
  -vf "scale=720:1560,format=yuv420p" "${ENC[@]}" "$P/seg1.mp4"

echo "② 睡眠页 → 报告列表（1.2 倍速）"
"$FF" -v error -y -ss 0 -i "$P/takeA.mp4" -i "$(cap cap_sleep)" -i "$(cap cap_morning)" \
  -filter_complex "[0:v]setpts=PTS/1.2,scale=720:1560[base];\
[base][1:v]overlay=(W-w)/2:$CAP_Y:enable='between(t,0.4,4.0)'[v1];\
[v1][2:v]overlay=(W-w)/2:$CAP_Y:enable='between(t,4.6,8.8)'[v]" \
  -map "[v]" -t 9.2 "${ENC[@]}" "$P/seg2.mp4"

echo "③ 评分 → 构成 → 信号（1.2 倍速）"
"$FF" -v error -y -ss 11 -i "$P/takeA.mp4" -i "$(cap cap_score)" -i "$(cap cap_breakdown)" -i "$(cap cap_signals)" \
  -filter_complex "[0:v]setpts=PTS/1.2,scale=720:1560[base];\
[base][1:v]overlay=(W-w)/2:$CAP_Y:enable='between(t,0.4,2.3)'[v1];\
[v1][2:v]overlay=(W-w)/2:$CAP_Y:enable='between(t,2.7,4.7)'[v2];\
[v2][3:v]overlay=(W-w)/2:$CAP_Y:enable='between(t,5.2,7.3)'[v]" \
  -map "[v]" -t 7.5 "${ENC[@]}" "$P/seg3.mp4"

echo "④ 事件明细 + 鼾声录音卡（1.2 倍速）"
"$FF" -v error -y -ss 20 -i "$P/takeA.mp4" -i "$(cap cap_events)" \
  -filter_complex "[0:v]setpts=PTS/1.2,scale=720:1560[base];\
[base][1:v]overlay=(W-w)/2:$CAP_Y:enable='between(t,0.4,4.6)'[v]" \
  -map "[v]" -t 5 "${ENC[@]}" "$P/seg4.mp4"

echo "⑤ 详细视图（静帧缓慢推近）"
"$FF" -v error -y -loop 1 -t 2.5 -i docs/screenshots/5-detailed-view.png -i "$(cap cap_detailed)" \
  -filter_complex "[0:v]scale=792:1716,crop=720:1560:x='(iw-ow)/2':y='(ih-oh)*t/2.5',format=yuv420p[base];\
[base][1:v]overlay=(W-w)/2:$CAP_Y:enable='between(t,0.15,2.4)'[v]" \
  -map "[v]" "${ENC[@]}" "$P/seg5.mp4"

echo "⑥ 播放面板：波形 + 3:05（1.2 倍速）"
"$FF" -v error -y -ss 2 -i "$P/takeB.mp4" -i "$(cap cap_player)" \
  -filter_complex "[0:v]setpts=PTS/1.2,scale=720:1560[base];\
[base][1:v]overlay=(W-w)/2:$CAP_Y:enable='between(t,2.5,9.5)'[v]" \
  -map "[v]" -t 10 "${ENC[@]}" "$P/seg6.mp4"

echo "⑦ 片尾卡"
"$FF" -v error -y -loop 1 -t 3 -i "$P/card_end.png" \
  -vf "scale=720:1560,format=yuv420p" "${ENC[@]}" "$P/seg7.mp4"

echo "⑧ 拼接"
rm -f "$P/list.txt"
for i in 1 2 3 4 5 6 7; do echo "file 'seg$i.mp4'" >> "$P/list.txt"; done
"$FF" -v error -y   -i "$P/seg1.mp4" -i "$P/seg2.mp4" -i "$P/seg3.mp4" -i "$P/seg4.mp4"   -i "$P/seg5.mp4" -i "$P/seg6.mp4" -i "$P/seg7.mp4"   -filter_complex "[0:v][1:v][2:v][3:v][4:v][5:v][6:v]concat=n=7:v=1:a=0[v]"   -map "[v]" "${ENC[@]}" "$OUT"

echo
echo "完成：$OUT"
"$FF" -hide_banner -i "$OUT" 2>&1 | grep -E "Duration|Stream #0" | head -3
