# 在主机上循环播放真实鼾声样本，喂给模拟器的虚拟麦克风。
# 模拟器以 -allow-host-audio 启动后，虚拟麦克风会使用主机的默认录音设备
# （这台机器上唯一启用的是「立体声混音」，即系统播放的回环）。
param([int]$Seconds = 60)

Add-Type -AssemblyName System.Windows.Forms
$dir = 'C:\git-program\sleep-secret\testdata\snore_esc50'
$files = Get-ChildItem -Path $dir -Filter '*.wav' | Sort-Object Name
if (-not $files) { Write-Output 'NO_FILES'; exit 1 }

Write-Output "播放 $($files.Count) 段鼾声，循环 ${Seconds}s"
$deadline = (Get-Date).AddSeconds($Seconds)
$i = 0
while ((Get-Date) -lt $deadline) {
    $f = $files[$i % $files.Count]
    try {
        $sp = New-Object System.Media.SoundPlayer $f.FullName
        $sp.PlaySync()
    } catch {
        Write-Output "play error: $_"
        Start-Sleep -Milliseconds 500
    }
    $i++
}
Write-Output "播放结束，共播 $i 次"
