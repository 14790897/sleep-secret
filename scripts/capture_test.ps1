# 一次完整的「开始录音 → 播放指定音频 → 停止录音」，用于端到端验证。
#
# 之所以单独成脚本而不是在命令行里拼：后台播放和主流程的时序很关键，
# 在 bash 里用 `&` 会把整条命令链都丢进后台，导致「停止」紧接着「开始」执行。
param(
    [string]$AudioPath = 'C:\git-program\sleep-secret\testdata\loud\snore_90s.wav',
    [int]$PlaySeconds = 45,
    [string]$OutDir = 'C:\git-program\sleep-secret\screenshots'
)

$shot = 'C:\git-program\sleep-secret\scripts\screenshot_app.ps1'
$play = 'C:\git-program\sleep-secret\scripts\play_wav_loop.ps1'

# 录音按钮在窗口内的相对坐标（窗口 2560x1440 时测出）
$BTN_X = 1275
$BTN_Y = 388

Write-Output '--- 开始录音 ---'
& powershell -NoProfile -ExecutionPolicy Bypass -File $shot `
    -OutFile "$OutDir\_cap_start.png" -ClickX $BTN_X -ClickY $BTN_Y -WaitMs 4000

Write-Output "--- 播放 $AudioPath 共 $PlaySeconds 秒 ---"
$player = Start-Process powershell -ArgumentList @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $play,
    '-Path', $AudioPath, '-Seconds', "$PlaySeconds"
) -WindowStyle Hidden -PassThru

$deadline = (Get-Date).AddSeconds($PlaySeconds + 3)
while ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
if (-not $player.HasExited) { $player.Kill() }

Write-Output '--- 停止录音 ---'
& powershell -NoProfile -ExecutionPolicy Bypass -File $shot `
    -OutFile "$OutDir\_cap_stop.png" -ClickX $BTN_X -ClickY $BTN_Y -WaitMs 6000

Write-Output '--- 完成 ---'
