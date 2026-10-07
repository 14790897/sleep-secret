# 驱动 sleep_secret 窗口：模拟真实鼠标点击和按键。
#
# ## 这是最后手段，不是验证手段
#
# 验页面该用 `flutter test`（单元/widget）和 `flutter test integration_test/...`（真机）。
# 它们直接驱动控件树，不碰坐标、不碰焦点、能在 CI 上跑，而且**会是红的**。
#
# 这个脚本只在框架够不着的地方用：系统原生的目录选择框、
# 发布版二进制本身的行为。用它验页面会骗人——
# - 截图的 PrintWindow 直接问窗口要内容，不受遮挡影响，
#   所以**截图无法证明点击落到了哪儿**（点在盖住它的窗口上，截图照样正常）；
# - SetForegroundWindow 在别的进程是前台时会静默失败，得先按 ALT 解锁；
# - 必须临时置顶，否则点击会落到上层窗口。
#
# 为什么不用 PostMessage/SendMessage：那些消息到了窗口，但 Flutter 不认——
# 它走的是自己的输入管线，要的是真实输入队列里的事件。所以只能 SendInput。
param(
    [string]$Click = "",      # "x,y" 或 "x,y;x,y" 依次点
    [string]$Keys = "",       # 逗号分隔的键名：pgdn/end/down/up/tab/enter
    [int]$SettleMs = 700,
    [switch]$NoFocus
)

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class Drv {
    [StructLayout(LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx, dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public MOUSEINPUT mi; [FieldOffset(8)] public KEYBDINPUT ki; }
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int cb);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);

    // 截图用的是 PrintWindow，不受遮挡影响——**所以截图不能证明窗口在最上面**。
    // 要真的点到，就得先把它顶到最前。
    public static void Topmost(IntPtr h, bool on) {
        var HWND_TOPMOST = new IntPtr(-1);
        var HWND_NOTOPMOST = new IntPtr(-2);
        // SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE
        SetWindowPos(h, on ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0010);
    }

    static INPUT Mouse(uint flags, int data) {
        var i = new INPUT(); i.type = 0; i.mi.dwFlags = flags; i.mi.mouseData = (uint)data; return i;
    }
    static INPUT Key(ushort vk, bool up) {
        var i = new INPUT(); i.type = 1; i.ki.wVk = vk; i.ki.dwFlags = up ? 2u : 0u; return i;
    }

    public static void ClickAt(int x, int y) {
        SetCursorPos(x, y);
        System.Threading.Thread.Sleep(120);
        var down = new INPUT[] { Mouse(0x0002, 0) };  // LEFTDOWN
        var up   = new INPUT[] { Mouse(0x0004, 0) };  // LEFTUP
        SendInput(1, down, Marshal.SizeOf(typeof(INPUT)));
        System.Threading.Thread.Sleep(60);
        SendInput(1, up, Marshal.SizeOf(typeof(INPUT)));
    }

    public static void Press(ushort vk, int repeat) {
        for (int i = 0; i < repeat; i++) {
            var d = new INPUT[] { Key(vk, false) };
            var u = new INPUT[] { Key(vk, true) };
            SendInput(1, d, Marshal.SizeOf(typeof(INPUT)));
            System.Threading.Thread.Sleep(40);
            SendInput(1, u, Marshal.SizeOf(typeof(INPUT)));
            System.Threading.Thread.Sleep(80);
        }
    }

    public static string ForegroundTitle() {
        var h = GetForegroundWindow();
        int n = GetWindowTextLength(h);
        var sb = new System.Text.StringBuilder(n + 2);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }
}
"@

function Unlock-Foreground($h) {
    # SetForegroundWindow 在别的进程是前台时会静默失败。
    # 按一下 ALT 能解除这个限制——这是 Windows 的既定行为。
    [Drv]::keybd_event(0x12, 0, 0, [IntPtr]::Zero)
    [Drv]::keybd_event(0x12, 0, 2, [IntPtr]::Zero)
    [void][Drv]::ShowWindow($h, 9)   # SW_RESTORE
    for ($i = 0; $i -lt 10; $i++) {
        [void][Drv]::SetForegroundWindow($h)
        Start-Sleep -Milliseconds 200
        if ([Drv]::ForegroundTitle() -like "Sleep Secret*") { return $true }
    }
    return ([Drv]::ForegroundTitle() -like "Sleep Secret*")
}

$hwnd = [IntPtr]::Zero
if (-not $NoFocus) {
    $p = Get-Process -Name sleep_secret -ErrorAction SilentlyContinue |
         Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $p) { Write-Error "sleep_secret 没在跑"; exit 1 }
    $hwnd = $p.MainWindowHandle
    if (-not (Unlock-Foreground $hwnd)) {
        Write-Error "抢不到前台，当前前台是「$([Drv]::ForegroundTitle())」"; exit 2
    }
    # 顶到最前，否则点击可能落到盖在它上面的窗口上。
    # 截图上完全看不出来——PrintWindow 直接问窗口要内容，不问屏幕上谁在上面。
    [Drv]::Topmost($hwnd, $true)
    Start-Sleep -Milliseconds 400
}

if ($Click -ne "") {
    foreach ($pt in $Click.Split(";")) {
        $xy = $pt.Split(",")
        [Drv]::ClickAt([int]$xy[0], [int]$xy[1])
        Start-Sleep -Milliseconds $SettleMs
    }
}

$map = @{ "pgdn" = 0x22; "pgup" = 0x21; "end" = 0x23; "home" = 0x24;
          "down" = 0x28; "up" = 0x26; "tab" = 0x09; "enter" = 0x0D; "esc" = 0x1B }
if ($Keys -ne "") {
    foreach ($k in $Keys.Split(",")) {
        $k = $k.Trim().ToLower()
        $vk = $map[$k]
        if ($null -eq $vk) { Write-Error "不认识的键：$k"; exit 1 }
        [Drv]::Press([ushort]$vk, 1)
        Start-Sleep -Milliseconds 250
    }
}

# 别把用户的桌面一直占着
if ($hwnd -ne [IntPtr]::Zero) { [Drv]::Topmost($hwnd, $false) }
Write-Output "OK 操作完成"
