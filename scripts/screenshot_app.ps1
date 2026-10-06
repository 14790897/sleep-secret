param(
    [string]$ProcessName = 'sleep_secret',
    [string]$OutFile = 'C:\git-program\sleep-secret\screenshots\app.png',
    [int]$ClickX = -1,
    [int]$ClickY = -1,
    [int]$WaitMs = 1500
)

Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinCap {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
}
"@

# 必须声明 DPI 感知。否则拿到的是被系统缩放过的虚拟坐标，
# 截出来只有窗口左上角一块，内容还是放大的。
[void][WinCap]::SetProcessDPIAware()

$proc = Get-Process -Name $ProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1

if (-not $proc) {
    Write-Output "NOT_FOUND: 进程 $ProcessName 没有可见窗口"
    exit 1
}

$h = $proc.MainWindowHandle

function Get-Rect($h) {
    $r = New-Object WinCap+RECT
    [void][WinCap]::GetWindowRect($h, [ref]$r)
    return $r
}

# 必须用**真实输入注入**（鼠标真的移过去并按下），不能 PostMessage。
# Flutter 的 Windows 嵌入层只在窗口是激活状态时处理指针事件，
# 试过 PostMessage(WM_LBUTTONDOWN) —— 消息投递成功但按钮毫无反应。
#
# 而要让点击落到目标窗口上就得先把它切到前台。从后台进程直接调用
# SetForegroundWindow 会被 Windows 拒绝（只是任务栏闪一下），
# 先轻敲一下 ALT 可以解除这个前台锁定——这是老牌的可行做法。
function Send-Click($h, $x, $y) {
    # ShowWindow(SW_RESTORE) 不能省——窗口最小化时 SetForegroundWindow 无效。
    # 而单次调用经常抢不到前台（别的进程刚拿到焦点），所以要重试。
    $ok = $false
    for ($try = 0; $try -lt 8; $try++) {
        [WinCap]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)   # ALT down
        [WinCap]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)   # ALT up
        [void][WinCap]::ShowWindow($h, 9)                   # SW_RESTORE
        [void][WinCap]::SetForegroundWindow($h)
        Start-Sleep -Milliseconds 300
        if ([WinCap]::GetForegroundWindow() -eq $h) { $ok = $true; break }
    }
    if (-not $ok) {
        Write-Output "WARN_FG: 抢不到前台，点击可能落空"
        return
    }

    $r = Get-Rect $h
    [void][WinCap]::SetCursorPos($r.Left + $x, $r.Top + $y)
    Start-Sleep -Milliseconds 250
    [WinCap]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)  # LEFTDOWN
    Start-Sleep -Milliseconds 90
    [WinCap]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)  # LEFTUP
}

if ($ClickX -ge 0 -and $ClickY -ge 0) {
    Send-Click $h $ClickX $ClickY
    Start-Sleep -Milliseconds $WaitMs
}

$r = Get-Rect $h
$w = $r.Right - $r.Left
$ht = $r.Bottom - $r.Top
if ($w -le 0 -or $ht -le 0) { Write-Output "BAD_RECT: $w x $ht"; exit 1 }

$dir = Split-Path -Parent $OutFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

# 用 PrintWindow 让窗口把自己渲染到位图里，与窗口层级无关。
# PW_RENDERFULLCONTENT(2) 是必需的：Flutter 走 ANGLE/D3D 合成，
# 不带这个标志会得到一张纯黑图。
$bmp = New-Object System.Drawing.Bitmap $w, $ht
$g = [System.Drawing.Graphics]::FromImage($bmp)
$hdc = $g.GetHdc()
$null = [WinCap]::PrintWindow($h, $hdc, 2)
$g.ReleaseHdc($hdc)
$g.Dispose()

# 逐点抽样判断是不是纯黑（PrintWindow 在某些合成方式下会失败）
$dark = 0
$total = 0
for ($px = 10; $px -lt $w; $px += 40) {
    for ($py = 10; $py -lt $ht; $py += 40) {
        $c = $bmp.GetPixel($px, $py)
        $total++
        if ($c.R -lt 8 -and $c.G -lt 8 -and $c.B -lt 8) { $dark++ }
    }
}

$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()

$frac = if ($total -gt 0) { [math]::Round($dark / $total, 3) } else { 0 }
if ($frac -gt 0.97) {
    Write-Output "WARN_DARK: ${w}x${ht} -> $OutFile (纯黑比例 $frac，PrintWindow 可能没抓到内容)"
} else {
    Write-Output "OK: ${w}x${ht} -> $OutFile"
}
