param(
    [string]$Path = 'C:\git-program\sleep-secret\testdata\loud\snore_01_norm.wav',
    [int]$Seconds = 40
)
# 循环播放一个 WAV 直到超过指定秒数。
# 用 PlaySync 是为了让每次播放首尾相接——整夜录音的模拟需要连续不断的声音，
# 否则 VAD 会在一段段静音之间大量跳过窗口。
$deadline = (Get-Date).AddSeconds($Seconds)
$i = 0
while ((Get-Date) -lt $deadline) {
    $sp = New-Object System.Media.SoundPlayer $Path
    $sp.PlaySync()
    $i++
}
Write-Output "播放 $i 次"
