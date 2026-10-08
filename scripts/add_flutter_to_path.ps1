# 把 Flutter 的 bin 目录追加到「用户级」PATH（不动系统级）
# 用 .NET API 而不是 setx —— setx 有 1024 字符截断风险，会破坏 PATH
#
# 用法：默认找 PATH 里的 flutter；没装过就假定它在上游标准的
# <用户目录>\flutter。装在别处的话传 -FlutterRoot。
param(
    [string]$FlutterRoot
)
$ErrorActionPreference = 'Stop'

if (-not $FlutterRoot) {
    $cmd = Get-Command flutter -ErrorAction SilentlyContinue
    $FlutterRoot = if ($cmd) {
        Split-Path (Split-Path $cmd.Source -Parent) -Parent
    } else {
        Join-Path $env:USERPROFILE 'flutter'
    }
}
$target = Join-Path $FlutterRoot 'bin'
Write-Output "Flutter 根目录: $FlutterRoot"

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($null -eq $userPath) { $userPath = '' }

Write-Output "=== 修改前（用户级 PATH）==="
Write-Output $userPath

$parts = $userPath -split ';' | Where-Object { $_ -ne '' }
if ($parts -contains $target) {
    Write-Output "`n已存在，无需修改"
} else {
    $newPath = ($parts + $target) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
    Write-Output "`n=== 修改后（用户级 PATH）==="
    Write-Output ([Environment]::GetEnvironmentVariable('Path', 'User'))
    Write-Output "`n已追加: $target"
}
Write-Output "`n字符数: $(([Environment]::GetEnvironmentVariable('Path','User')).Length)"
