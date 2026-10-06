param([int]$Seconds = 40)
$dir = 'C:\git-program\sleep-secret\testdata\loud'
$files = Get-ChildItem -Path $dir -Filter '*.wav' | Sort-Object Name
$deadline = (Get-Date).AddSeconds($Seconds)
$i = 0
while ((Get-Date) -lt $deadline) {
    $sp = New-Object System.Media.SoundPlayer $files[$i % $files.Count].FullName
    $sp.PlaySync()
    $i++
}
Write-Output "播放 $i 次"
