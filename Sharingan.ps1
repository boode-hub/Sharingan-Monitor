# Sharingan CPU/RAM System Tray Monitor
# Native PowerShell script using .NET System.Drawing (GDI+) and NotifyIcon

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# 1. Declare Win32 Metrics and DestroyIcon API with high-accuracy Performance Counter
$MetricsSignature = @"
using System;
using System.Runtime.InteropServices;
using System.Diagnostics;

public class Win32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPage;
        public ulong ullAvailPage;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool DestroyIcon(IntPtr hIcon);

    private static PerformanceCounter cpuCounter;

    static Win32() {
        try {
            // Using standard WMI-backed PerformanceCounter which exactly matches Windows Task Manager
            cpuCounter = new PerformanceCounter("Processor", "% Processor Time", "_Total");
            cpuCounter.NextValue(); // Initial sample (will read 0)
        } catch {
            cpuCounter = null;
        }
    }

    public static double GetCPULoad() {
        if (cpuCounter == null) return 0.0;
        try {
            return (double)cpuCounter.NextValue();
        } catch {
            return 0.0;
        }
    }

    public static double GetRAMLoad() {
        MEMORYSTATUSEX mem = new MEMORYSTATUSEX();
        mem.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        if (!GlobalMemoryStatusEx(ref mem)) return 0;
        return mem.dwMemoryLoad;
    }
}
"@
Add-Type -TypeDefinition $MetricsSignature

# 1b. Modern menu look: a flat, minimal renderer and a custom-drawn slider.
# Written in C# because per-pixel painting from PowerShell event handlers is slow
# and flickers; everything here only paints, all logic stays in the script.
$ModernUiSource = @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class SharinganMenuTheme {
    public Color Back, Text, TextDim, Hover, Line, Border, Accent, Thumb;
    public static SharinganMenuTheme Create(bool dark) {
        SharinganMenuTheme t = new SharinganMenuTheme();
        t.Accent = Color.FromArgb(220, 38, 38);
        if (dark) {
            t.Back = Color.FromArgb(32, 32, 32);   t.Text = Color.FromArgb(242, 242, 242);
            t.TextDim = Color.FromArgb(150, 150, 150); t.Hover = Color.FromArgb(55, 55, 55);
            t.Line = Color.FromArgb(62, 62, 62);    t.Border = Color.FromArgb(58, 58, 58);
            t.Thumb = Color.FromArgb(245, 245, 245);
        } else {
            t.Back = Color.FromArgb(251, 251, 251); t.Text = Color.FromArgb(26, 26, 26);
            t.TextDim = Color.FromArgb(120, 120, 120); t.Hover = Color.FromArgb(234, 234, 234);
            t.Line = Color.FromArgb(222, 222, 222); t.Border = Color.FromArgb(214, 214, 214);
            t.Thumb = Color.White;
        }
        return t;
    }
}

// Outline of a tomoe tail from a head-relative profile (see $global:TomoeA/I/O).
public static class SharinganTomoe {
    public static PointF[] Tail(double[] a, double[] rin, double[] rout, double hx, double hy, double outward, double hr) {
        int n = a.Length;
        PointF[] p = new PointF[n * 2];
        for (int i = 0; i < n; i++) {
            double ang = outward + a[i], c = Math.Cos(ang), s = Math.Sin(ang);
            p[i] = new PointF((float)(hx + rout[i] * hr * c), (float)(hy + rout[i] * hr * s));
            p[2 * n - 1 - i] = new PointF((float)(hx + rin[i] * hr * c), (float)(hy + rin[i] * hr * s));
        }
        return p;
    }
}

public class SharinganMenuRenderer : ToolStripProfessionalRenderer {
    readonly SharinganMenuTheme t;
    readonly HashSet<IntPtr> rounded = new HashSet<IntPtr>();
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    public SharinganMenuRenderer(SharinganMenuTheme theme) { t = theme; RoundedEdges = false; }

    protected override void OnRenderToolStripBackground(ToolStripRenderEventArgs e) {
        using (SolidBrush b = new SolidBrush(t.Back)) e.Graphics.FillRectangle(b, e.AffectedBounds);
        // Windows 11 rounds the menu window itself; older Windows ignores this.
        ToolStripDropDown dd = e.ToolStrip as ToolStripDropDown;
        if (dd != null && dd.IsHandleCreated && !rounded.Contains(dd.Handle)) {
            int round = 2;
            try { DwmSetWindowAttribute(dd.Handle, 33, ref round, 4); } catch { }
            rounded.Add(dd.Handle);
        }
    }
    protected override void OnRenderToolStripBorder(ToolStripRenderEventArgs e) {
        using (Pen p = new Pen(t.Border)) e.Graphics.DrawRectangle(p, 0, 0, e.ToolStrip.Width - 1, e.ToolStrip.Height - 1);
    }
    protected override void OnRenderImageMargin(ToolStripRenderEventArgs e) { }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        Rectangle r = new Rectangle(4, 1, e.Item.Width - 8, e.Item.Height - 2);
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (GraphicsPath gp = Round(r, 5)) using (SolidBrush b = new SolidBrush(t.Hover)) e.Graphics.FillPath(b, gp);
    }
    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        int y = e.Item.Height / 2;
        using (Pen p = new Pen(t.Line)) e.Graphics.DrawLine(p, 12, y, e.Item.Width - 12, y);
    }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        e.TextColor = e.Item.Enabled ? t.Text : t.TextDim;
        base.OnRenderItemText(e);
    }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
        Rectangle r = e.ArrowRectangle;
        float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (Pen p = new Pen(t.TextDim, 1.4f)) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round;
            e.Graphics.DrawLines(p, new PointF[] { new PointF(cx - 2f, cy - 4f), new PointF(cx + 2f, cy), new PointF(cx - 2f, cy + 4f) });
        }
    }
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        Rectangle r = e.ImageRectangle;
        float cx = r.X + r.Width / 2f, cy = r.Y + r.Height / 2f;
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (Pen p = new Pen(t.Accent, 1.8f)) {
            p.StartCap = LineCap.Round; p.EndCap = LineCap.Round; p.LineJoin = LineJoin.Round;
            e.Graphics.DrawLines(p, new PointF[] { new PointF(cx - 4f, cy), new PointF(cx - 1.2f, cy + 3f), new PointF(cx + 4.5f, cy - 3.5f) });
        }
    }
    internal static GraphicsPath Round(RectangleF r, float rad) {
        GraphicsPath gp = new GraphicsPath();
        float d = rad * 2;
        if (r.Width < d) d = r.Width;
        if (r.Height < d) d = r.Height;
        if (d <= 0) { gp.AddRectangle(r); return gp; }
        gp.AddArc(r.X, r.Y, d, d, 180, 90);
        gp.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        gp.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        gp.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        gp.CloseFigure();
        return gp;
    }
}

// Flat slider: thin rounded track, filled to the value in the accent colour, round thumb.
public class SharinganSlider : Control {
    int val = 50, min = 0, max = 100;
    bool drag, hover;
    readonly SharinganMenuTheme t;
    public string Caption = "";
    public string ValueText = "";
    public event EventHandler ValueChanged;
    public event EventHandler ValueCommitted;

    public SharinganSlider(SharinganMenuTheme theme) {
        t = theme;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint |
                 ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
        Size = new Size(260, 58);
        BackColor = t.Back;
        TabStop = true;
        Cursor = Cursors.Hand;
    }
    public int Minimum { get { return min; } set { min = value; if (val < min) val = min; Invalidate(); } }
    public int Maximum { get { return max; } set { max = value; if (val > max) val = max; Invalidate(); } }
    public int Value {
        get { return val; }
        set {
            int v = Math.Max(min, Math.Min(max, value));
            if (v == val) return;
            val = v; Invalidate();
            if (ValueChanged != null) ValueChanged(this, EventArgs.Empty);
        }
    }
    public void Step(int delta) { Value = val + delta; Commit(); }
    void Commit() { if (ValueCommitted != null) ValueCommitted(this, EventArgs.Empty); }
    RectangleF Track { get { return new RectangleF(16f, 38f, Width - 32f, 4f); } }
    int ValueAt(int px) {
        RectangleF tr = Track;
        float f = (px - tr.X) / tr.Width;
        return (int)Math.Round(min + Math.Max(0f, Math.Min(1f, f)) * (max - min));
    }
    protected override void OnPaint(PaintEventArgs e) {
        Graphics g = e.Graphics;
        g.Clear(t.Back);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        TextRenderer.DrawText(g, Caption, Font, new Point(14, 9), t.Text, TextFormatFlags.NoPadding);
        Size vs = TextRenderer.MeasureText(ValueText, Font, Size.Empty, TextFormatFlags.NoPadding);
        TextRenderer.DrawText(g, ValueText, Font, new Point(Width - 16 - vs.Width, 9), t.TextDim, TextFormatFlags.NoPadding);
        RectangleF tr = Track;
        float frac = (val - min) / (float)(max - min);
        float x = tr.X + frac * tr.Width;
        using (SolidBrush b = new SolidBrush(t.Line)) using (GraphicsPath gp = SharinganMenuRenderer.Round(tr, 2f)) g.FillPath(b, gp);
        if (x - tr.X > 0.5f)
            using (SolidBrush b = new SolidBrush(t.Accent)) using (GraphicsPath gp = SharinganMenuRenderer.Round(new RectangleF(tr.X, tr.Y, x - tr.X, tr.Height), 2f)) g.FillPath(b, gp);
        float r = (drag || hover || Focused) ? 8f : 7f;
        float cy = tr.Y + tr.Height / 2f;
        using (SolidBrush b = new SolidBrush(Color.FromArgb(45, 0, 0, 0))) g.FillEllipse(b, x - r, cy - r + 1.2f, r * 2, r * 2);
        using (SolidBrush b = new SolidBrush(t.Thumb)) g.FillEllipse(b, x - r, cy - r, r * 2, r * 2);
        using (Pen p = new Pen(t.Accent, 2f)) g.DrawEllipse(p, x - r + 1f, cy - r + 1f, r * 2 - 2f, r * 2 - 2f);
    }
    protected override void OnMouseDown(MouseEventArgs e) { base.OnMouseDown(e); if (e.Button != MouseButtons.Left) return; drag = true; Capture = true; Focus(); Value = ValueAt(e.X); Invalidate(); }
    protected override void OnMouseMove(MouseEventArgs e) { base.OnMouseMove(e); if (!hover) { hover = true; Invalidate(); } if (drag) Value = ValueAt(e.X); }
    protected override void OnMouseUp(MouseEventArgs e) { base.OnMouseUp(e); if (!drag) return; drag = false; Capture = false; Invalidate(); Commit(); }
    protected override void OnMouseLeave(EventArgs e) { base.OnMouseLeave(e); hover = false; Invalidate(); }
    protected override void OnMouseWheel(MouseEventArgs e) { base.OnMouseWheel(e); Step(e.Delta > 0 ? 1 : -1); }
    protected override bool IsInputKey(Keys k) { return k == Keys.Left || k == Keys.Right || k == Keys.Up || k == Keys.Down || base.IsInputKey(k); }
    protected override void OnKeyDown(KeyEventArgs e) {
        base.OnKeyDown(e);
        int d = 0;
        if (e.KeyCode == Keys.Left || e.KeyCode == Keys.Down) d = -1;
        else if (e.KeyCode == Keys.Right || e.KeyCode == Keys.Up) d = 1;
        else if (e.KeyCode == Keys.PageDown) d = -10;
        else if (e.KeyCode == Keys.PageUp) d = 10;
        else if (e.KeyCode == Keys.Home) d = min - val;
        else if (e.KeyCode == Keys.End) d = max - val;
        if (d != 0) { Step(d); e.Handled = true; }
    }
    protected override void OnGotFocus(EventArgs e) { base.OnGotFocus(e); Invalidate(); }
    protected override void OnLostFocus(EventArgs e) { base.OnLostFocus(e); Invalidate(); }
}
'@
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition $ModernUiSource

# Follow Windows' light/dark setting for the tray menu.
$global:MenuDark = $false
try {
    $global:MenuDark = ((Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -ErrorAction Stop).SystemUsesLightTheme -eq 0)
}
catch { }
$global:MenuTheme = [SharinganMenuTheme]::Create($global:MenuDark)
$global:MenuFont = New-Object System.Drawing.Font("Segoe UI", 9.5)
[System.Windows.Forms.ToolStripManager]::Renderer = New-Object SharinganMenuRenderer($global:MenuTheme)

# 2. Global State Variables
$global:running = $true
$global:monitoringModeIsRAM = $false       # False = CPU, True = RAM
$global:currentLoadPercent = [Win32]::GetCPULoad()
$global:selectedEyeStyle = "Itachi"        # Default set to Itachi

$global:currentStage = 0.0                 # From 0.0 to 4.0
$global:rotationAngle = 0.0

# Two eye sets, both always built in:
#   Classic - the original hand-drawn eyes
#   V1      - drawn from the original artwork in .\eyes\ (offered only for the
#             eyes whose file is there; with no eyes\ folder only Classic shows)
# An eye is identified as "Set:Name", e.g. "V1:Itachi" or "Classic:Obito".
$global:EyeSets = [ordered]@{
    "Classic" = @("Itachi", "Obito", "Kakashi", "Madara", "Madara Eternal", "Izuna", "Sasuke",
        "Sasuke Eternal", "Shisui", "Indra", "Shin", "Sarada", "Naka", "Baru", "Rai", "Naori",
        "Fugaku", "Fugaku Eternal", "Nanashi", "BOoD3")
    "V1"      = @("Itachi", "Kakashi/Obito", "Madara", "Madara Eternal", "Izuna", "Sasuke", "Sasuke Eternal",
        "Shisui", "Indra", "Shin", "Sarada", "Naka", "Baru", "Rai", "Naori", "Fugaku",
        "Fugaku Eternal", "Nanashi", "BOoD", "BOoD2", "BOoD3")
}

$global:EyesDir = Join-Path $PSScriptRoot "eyes"
# V1 eye -> artwork file in .\eyes\ (SVG = vector, PNG = picture)
$global:EyeFiles = @{
    "Itachi" = "Itachi.svg"; "Kakashi/Obito" = "Kakashi-Obito.svg"; "Madara" = "Madara.svg"
    "Madara Eternal" = "Madara-Eternal.svg"; "Izuna" = "Izuna.svg"; "Sasuke" = "Sasuke.svg"
    "Sasuke Eternal" = "Sasuke-Eternal.png"; "Shisui" = "Shisui.svg"; "Indra" = "Indra.svg"
    "Shin" = "Shin.svg"; "Sarada" = "Sarada.svg"; "Naka" = "Naka.svg"; "Baru" = "Baru.svg"
    "Rai" = "Rai.svg"; "Naori" = "Naori.svg"; "Fugaku" = "Fugaku.svg"; "Nanashi" = "Nanashi.svg"
    "Fugaku Eternal" = "Fugaku-Eternal.png"; "BOoD" = "BOoD.png"; "BOoD2" = "BOoD2.png"
    "BOoD3" = "BOoD3.png"
}
$global:EyeSets["V1"] = @($global:EyeSets["V1"] | Where-Object { Test-Path (Join-Path $global:EyesDir $global:EyeFiles[$_]) })
if ($global:EyeSets["V1"].Count -eq 0) { $global:EyeSets.Remove("V1") }

# Every selectable eye, in menu order. Also what the shuffle draws from.
$global:SharinganStyles = @(foreach ($set in $global:EyeSets.Keys) { foreach ($n in $global:EyeSets[$set]) { "${set}:$n" } })
$global:DefaultStyle = "Classic:Itachi"
if ($global:EyeSets.Contains("V1")) { $global:DefaultStyle = "V1:Itachi" }
$global:selectedEyeStyle = $global:DefaultStyle

# Settings and profiles from older builds stored a bare name ("Itachi"). Prefer
# the artwork version when it exists, otherwise the hand-drawn one.
function Resolve-StyleKey([string]$v) {
    $v = $v -replace '(Madara|Sasuke) Eye 2$', '$1 Eternal'      # renamed: the Eternal Mangekyou
    if ($global:SharinganStyles -contains $v) { return $v }
    foreach ($set in @("V1", "Classic")) {
        if ($global:SharinganStyles -contains "${set}:$v") { return "${set}:$v" }
    }
    return $null
}

# Factory defaults. Reset restores exactly these.
$global:Defaults = @{
    Thresholds     = @(15.0, 35.0, 55.0, 75.0)   # load % that unlocks tomoe 1, 2, 3, Mangekyou
    ColorR         = 195      # #c30000, the mid stop of the eyes' red gradient
    ColorG         = 0
    ColorB         = 0
    Glow           = $false
    GlowPulse      = $true    # heartbeat pulse; off = a steady glow
    PulseLevel     = 50       # pulse speed 1..100; 50 = normal
    SpeedLevel     = 50       # 0..100 slider; 0 = paused, 50 = 1.0x (the original speed)
    Direction      = 1        # 1 clockwise, -1 counter-clockwise
    Invert         = $false   # swap tomoe/pattern colour with the eye colour
    Shuffle        = $false
    ShuffleSeconds = 10
    Style          = $global:DefaultStyle
}

# Live settings (populated by Reset-Defaults, then overwritten by the saved file if present)
$global:thresholds = @(15.0, 35.0, 55.0, 75.0)
$global:eyeColor = [System.Drawing.Color]::FromArgb(195, 0, 0)
$global:glowOn = $false
$global:glowPulse = $true
$global:pulseLevel = 50
$global:speedLevel = 50
$global:speedMult = 1.0
$global:rotationDir = 1
$global:invertOn = $false
$global:shuffleOn = $false
$global:shuffleSeconds = 10

$global:SettingsPath = Join-Path $PSScriptRoot "settings.json"

# Slider 1..100 -> rotation multiplier. Exponential so each notch feels the same:
# 1 = 0.17x, 50 = 1.00x (original speed), 100 = 6.00x.
function Get-SpeedMult([int]$level) {
    if ($level -le 0) { return 0.0 }                 # 0 = paused
    return [Math]::Pow(6.0, ($level - 50) / 50.0)
}

# Pulse speed 1..100 -> heart-rate multiplier: 1 = 0.25x, 50 = 1.00x, 100 = 4.00x.
function Get-PulseMult([int]$level) { return [Math]::Pow(4.0, ($level - 50) / 50.0) }

function Update-PulseText {
    if ($global:PulseTrack) {
        $global:PulseTrack.ValueText = ("{0}   {1:N2}{2}" -f $global:pulseLevel, (Get-PulseMult $global:pulseLevel), [char]0x00D7)
        $global:PulseTrack.Invalidate()
    }
}

function Get-SpeedText {
    if ($global:speedLevel -le 0) { return "Paused" }
    return ("{0}   {1:N2}{2}" -f $global:speedLevel, $global:speedMult, [char]0x00D7)
}

function Update-SpeedText {
    if ($global:SpeedTrack) { $global:SpeedTrack.ValueText = Get-SpeedText; $global:SpeedTrack.Invalidate() }
}

function Set-SpeedLevel([int]$level) {
    $global:speedLevel = [Math]::Max(0, [Math]::Min(100, $level))
    $global:speedMult = Get-SpeedMult $global:speedLevel
}

# 2b. Settings Persistence
$global:ProfilesDir = Join-Path $PSScriptRoot "profiles"

function Get-SettingsObject {
    [PSCustomObject]@{
        Thresholds     = $global:thresholds
        ColorR         = $global:eyeColor.R
        ColorG         = $global:eyeColor.G
        ColorB         = $global:eyeColor.B
        Glow           = $global:glowOn
        GlowPulse      = $global:glowPulse
        PulseLevel     = $global:pulseLevel
        SpeedLevel     = $global:speedLevel
        Direction      = $global:rotationDir
        Invert         = $global:invertOn
        Shuffle        = $global:shuffleOn
        ShuffleSeconds = $global:shuffleSeconds
        Style          = $global:selectedEyeStyle
    }
}

# Apply a settings object (from settings.json or a profile). Every field is
# optional and validated, so older files and hand-edited profiles still load.
function Set-SettingsFromObject($s) {
    $has = { param($n) $null -ne $s.PSObject.Properties[$n] }
    if ((& $has 'Thresholds') -and @($s.Thresholds).Count -eq 4) {
        $t = @($s.Thresholds | ForEach-Object { [double]$_ })
        if ($t[0] -ge 0 -and $t[3] -le 100 -and $t[0] -lt $t[1] -and $t[1] -lt $t[2] -and $t[2] -lt $t[3]) { $global:thresholds = $t }
    }
    if ((& $has 'ColorR') -and (& $has 'ColorG') -and (& $has 'ColorB')) {
        $c = { param($v) [Math]::Max(0, [Math]::Min(255, [int]$v)) }
        $global:eyeColor = [System.Drawing.Color]::FromArgb((& $c $s.ColorR), (& $c $s.ColorG), (& $c $s.ColorB))
    }
    if (& $has 'Glow') { $global:glowOn = [bool]$s.Glow }
    if (& $has 'GlowPulse') { $global:glowPulse = [bool]$s.GlowPulse }
    if (& $has 'PulseLevel') { $global:pulseLevel = [Math]::Max(1, [Math]::Min(100, [int]$s.PulseLevel)) }
    if (& $has 'SpeedLevel') { Set-SpeedLevel ([int]$s.SpeedLevel) }
    elseif (& $has 'Speed') {
        # settings.json written before the slider existed stored a multiplier
        $m = [Math]::Max(0.05, [double]$s.Speed)
        Set-SpeedLevel ([int][Math]::Round(50 + 50 * [Math]::Log($m) / [Math]::Log(6.0)))
    }
    if (& $has 'Direction') { if ([int]$s.Direction -lt 0) { $global:rotationDir = -1 } else { $global:rotationDir = 1 } }
    if (& $has 'Invert') { $global:invertOn = [bool]$s.Invert }
    if (& $has 'Shuffle') { $global:shuffleOn = [bool]$s.Shuffle }
    if (& $has 'ShuffleSeconds') { $global:shuffleSeconds = [Math]::Max(1, [int]$s.ShuffleSeconds) }
    if (& $has 'Style') {
        $st = Resolve-StyleKey ([string]$s.Style)
        if ($st) { $global:selectedEyeStyle = $st }
    }
}

function Save-Settings {
    try {
        Get-SettingsObject | ConvertTo-Json | Set-Content -Path $global:SettingsPath -Encoding UTF8
    }
    catch {
        # A read-only folder should never take the tray icon down with it.
    }
}

function Load-Settings {
    if (-not (Test-Path $global:SettingsPath)) { return }
    try {
        Set-SettingsFromObject (Get-Content -Path $global:SettingsPath -Raw | ConvertFrom-Json)
    }
    catch {
        # Corrupt file: fall back to whatever defaults are already loaded.
    }
}

# Profiles: one compact single-line JSON file per profile in .\profiles\
function Get-ProfileFileName([string]$name) {
    $clean = ($name.Trim() -replace '[\\/:*?"<>|]', '').Trim()
    if (-not $clean) { return $null }
    return (Join-Path $global:ProfilesDir ($clean + ".json"))
}

function Save-Profile([string]$name) {
    $path = Get-ProfileFileName $name
    if (-not $path) { return $null }
    if (-not (Test-Path $global:ProfilesDir)) { New-Item -ItemType Directory -Path $global:ProfilesDir | Out-Null }
    Get-SettingsObject | ConvertTo-Json -Compress | Set-Content -Path $path -Encoding UTF8
    return $path
}

function Import-Profile([string]$path) {
    try {
        Set-SettingsFromObject (Get-Content -Path $path -Raw | ConvertFrom-Json)
        return $true
    }
    catch { return $false }
}

function Reset-Defaults {
    $d = $global:Defaults
    $global:thresholds = @($d.Thresholds)
    $global:eyeColor = [System.Drawing.Color]::FromArgb($d.ColorR, $d.ColorG, $d.ColorB)
    $global:glowOn = $d.Glow
    $global:glowPulse = $d.GlowPulse
    $global:pulseLevel = $d.PulseLevel
    Set-SpeedLevel $d.SpeedLevel
    $global:rotationDir = $d.Direction
    $global:invertOn = $d.Invert
    $global:shuffleOn = $d.Shuffle
    $global:shuffleSeconds = $d.ShuffleSeconds
    Set-EyeStyle $d.Style
}

# 3. GUI Elements Setup
$NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$NotifyIcon.Visible = $true
$NotifyIcon.Text = "Sharingan Monitor"

# Context Menu
$ContextMenu = New-Object System.Windows.Forms.ContextMenuStrip

$ToggleItem = New-Object System.Windows.Forms.ToolStripMenuItem("Swap to RAM Tracking")
$StyleItem = New-Object System.Windows.Forms.ToolStripMenuItem("Eyes")
$CustomItem = New-Object System.Windows.Forms.ToolStripMenuItem("Customize")
$SupportItem = New-Object System.Windows.Forms.ToolStripMenuItem("Buy me a coffee")
$ExitItem = New-Object System.Windows.Forms.ToolStripMenuItem("Exit")

# Build the Sharingan style menu from the list above so the menu, the shuffle pool
# and the check marks can never drift out of sync.
$global:StyleMenuItems = @{}
$global:SetMenuItems = @{}
foreach ($set in $global:EyeSets.Keys) {
    $parent = $StyleItem
    if ($global:EyeSets.Count -gt 1) {
        $parent = New-Object System.Windows.Forms.ToolStripMenuItem($set)
        $global:SetMenuItems[$set] = $parent
        $StyleItem.DropDownItems.Add($parent) | Out-Null
    }
    foreach ($name in $global:EyeSets[$set]) {
        $key = "${set}:$name"
        $item = New-Object System.Windows.Forms.ToolStripMenuItem($name)
        $item.Tag = $key
        $item.add_Click({ Set-EyeStyle $this.Tag })
        $global:StyleMenuItems[$key] = $item
        $parent.DropDownItems.Add($item) | Out-Null
    }
}

$ContextMenu.Items.Add($ToggleItem) | Out-Null
$ContextMenu.Items.Add($StyleItem) | Out-Null
$ContextMenu.Items.Add($CustomItem) | Out-Null
$ContextMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$ContextMenu.Items.Add($SupportItem) | Out-Null
$ContextMenu.Items.Add($ExitItem) | Out-Null
$NotifyIcon.ContextMenuStrip = $ContextMenu

# Event Bindings
$ToggleItem.add_Click({
        $global:monitoringModeIsRAM = -not $global:monitoringModeIsRAM
        if ($global:monitoringModeIsRAM) {
            $ToggleItem.Text = "Swap to CPU Tracking"
        }
        else {
            $ToggleItem.Text = "Swap to RAM Tracking"
        }
    })

function Set-EyeStyle($styleName) {
    if (-not $global:StyleMenuItems.ContainsKey($styleName)) { return }
    foreach ($mi in $global:StyleMenuItems.Values) { $mi.Checked = $false }
    $global:StyleMenuItems[$styleName].Checked = $true
    $global:selectedEyeStyle = $styleName
    # tick the set (Classic / V1) the current eye belongs to
    $current = ($styleName -split ':', 2)[0]
    foreach ($set in $global:SetMenuItems.Keys) { $global:SetMenuItems[$set].Checked = ($set -eq $current) }
}

# Shuffle stays within the set of the current eye.
function Get-ShufflePick {
    $set = ($global:selectedEyeStyle -split ':', 2)[0]
    $pool = @($global:SharinganStyles | Where-Object { $_ -like "${set}:*" -and $_ -ne $global:selectedEyeStyle })
    if ($pool.Count -eq 0) { return $global:selectedEyeStyle }
    return ($pool | Get-Random)
}

$SupportItem.add_Click({
        # One menu entry, opened only when clicked. No popups, no reminders -
        # the README promises no nags and this has to stay true to that.
        try { Start-Process "https://buymeacoffee.com/boode" } catch {}
    })

$ExitItem.add_Click({
        $global:running = $false
        [System.Windows.Forms.Application]::ExitThread()   # stops the message pump in section 6
    })

# Apply saved settings (or stay on defaults), then sync the menu check mark.
Load-Settings
Set-EyeStyle $global:selectedEyeStyle


# 3b. Customize Submenu
# Everything lives in the tray context menu itself. A tray app has no main window,
# so a pop-up Form has nothing to own it: Windows refuses to activate it while
# another app holds the foreground, and it lands wherever the last screen was.
# ToolStripMenuItems have none of those problems - the shell owns the menu window.

# Turn an existing menu item into a radio-style list: one entry per value, the
# current one check-marked. $values is a list of @{ Text = "..."; Value = ... }.
function Fill-ChoiceMenu($menuItem, $values, $getCurrent, $onPick) {
    foreach ($v in $values) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem($v.Text)
        $mi.Tag = $v.Value
        $mi.add_Click({
                & $this.Owner.Tag.OnPick $this.Tag
                Save-Settings
                Sync-CustomMenu
            })
        $menuItem.DropDownItems.Add($mi) | Out-Null
    }
    # Stash the handlers on the dropdown so each item can reach them via $this.Owner.
    $menuItem.DropDown.Tag = @{ OnPick = $onPick; GetCurrent = $getCurrent }
    $global:ChoiceMenus += $menuItem
    return $menuItem
}

# Same, but creates the submenu under $parent first.
function Add-ChoiceMenu($parent, $label, $values, $getCurrent, $onPick) {
    $sub = New-Object System.Windows.Forms.ToolStripMenuItem($label)
    $parent.DropDownItems.Add($sub) | Out-Null
    return (Fill-ChoiceMenu $sub $values $getCurrent $onPick)
}

# Re-tick every check mark from current state. Cheap, and keeps one source of truth.
function Sync-CustomMenu {
    foreach ($sub in $global:ChoiceMenus) {
        $current = & $sub.DropDown.Tag.GetCurrent
        foreach ($mi in $sub.DropDownItems) {
            $mi.Checked = ($mi.Tag -eq $current)
        }
    }
    $global:GlowItem.Checked = $global:glowOn
    $global:PulseItem.Checked = $global:glowPulse
    if ($global:PulseTrack -and $global:PulseTrack.Value -ne $global:pulseLevel) {
        $global:SyncingPulse = $true
        $global:PulseTrack.Value = $global:pulseLevel
        $global:SyncingPulse = $false
    }
    Update-PulseText
    $global:InvertItem.Checked = $global:invertOn
    $global:ShuffleToggle.Checked = $global:shuffleOn
    if ($global:SpeedTrack -and $global:SpeedTrack.Value -ne $global:speedLevel) {
        $global:SyncingSpeed = $true
        $global:SpeedTrack.Value = $global:speedLevel
        $global:SyncingSpeed = $false
    }
    Update-SpeedText
    $global:ColorSwatchItem.Text = "Current: $(Get-ColorName $global:eyeColor)"
}

$global:ColorPresets = @(
    @{ Text = "Sharingan Red"; Value = @(195, 0, 0) }
    @{ Text = "Classic Red";   Value = @(220, 10, 15) }
    @{ Text = "Crimson";       Value = @(160, 0, 20) }
    @{ Text = "Orange";        Value = @(240, 110, 20) }
    @{ Text = "Gold";          Value = @(230, 180, 30) }
    @{ Text = "Green";         Value = @(40, 190, 80) }
    @{ Text = "Cyan";          Value = @(0, 190, 210) }
    @{ Text = "Blue";          Value = @(40, 120, 240) }
    @{ Text = "Violet";        Value = @(150, 80, 230) }
    @{ Text = "Magenta";       Value = @(230, 60, 170) }
    @{ Text = "White";         Value = @(240, 240, 240) }
)

function Get-ColorName($c) {
    foreach ($p in $global:ColorPresets) {
        if ($c.R -eq $p.Value[0] -and $c.G -eq $p.Value[1] -and $c.B -eq $p.Value[2]) { return $p.Text }
    }
    return "$($c.R), $($c.G), $($c.B)"
}

$global:ChoiceMenus = @()

# --- Thresholds ----------------------------------------------------------
# Percentages offered per stage. 5% steps is plenty for a tray toy and keeps
# the menu to a readable length.
$percentChoices = @(0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 90, 95 |
    ForEach-Object { @{ Text = "$_%"; Value = [double]$_ } })

$ThresholdsItem = New-Object System.Windows.Forms.ToolStripMenuItem("Thresholds")
$CustomItem.DropDownItems.Add($ThresholdsItem) | Out-Null

$stageLabels = @("1st Tomoe", "2nd Tomoe", "3rd Tomoe", "Mangekyou")
for ($i = 0; $i -lt 4; $i++) {
    $idx = $i
    $global:ChoiceMenus += Add-ChoiceMenu $ThresholdsItem $stageLabels[$i] $percentChoices `
    { $global:thresholds[$idx] }.GetNewClosure() `
    {
        param($v)
        $t = @($global:thresholds)
        # Clamp the picked value so the stages below and above it still have room
        # for a 5% step each. Without this, dragging the top stage down squashes
        # the lower ones together and a stage becomes unreachable.
        $lo = $idx * 5.0
        $hi = 100.0 - ((3 - $idx) * 5.0)
        $t[$idx] = [Math]::Max($lo, [Math]::Min([double]$v, $hi))
        # Keep the four strictly ascending by pushing the neighbours out of the way.
        for ($j = $idx + 1; $j -lt 4; $j++) { if ($t[$j] -le $t[$j - 1]) { $t[$j] = $t[$j - 1] + 5.0 } }
        for ($j = $idx - 1; $j -ge 0; $j--) { if ($t[$j] -ge $t[$j + 1]) { $t[$j] = $t[$j + 1] - 5.0 } }
        $global:thresholds = $t
    }.GetNewClosure()
}

# --- Color ---------------------------------------------------------------
$ColorItem = New-Object System.Windows.Forms.ToolStripMenuItem("Color")
$CustomItem.DropDownItems.Add($ColorItem) | Out-Null

$global:ColorSwatchItem = New-Object System.Windows.Forms.ToolStripMenuItem("Current: ")
$global:ColorSwatchItem.Enabled = $false
$ColorItem.DropDownItems.Add($global:ColorSwatchItem) | Out-Null
$ColorItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

foreach ($preset in $global:ColorPresets) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem($preset.Text)
    $mi.Tag = $preset.Value
    $mi.add_Click({
            $global:eyeColor = [System.Drawing.Color]::FromArgb($this.Tag[0], $this.Tag[1], $this.Tag[2])
            Save-Settings
            Sync-CustomMenu
        })
    $ColorItem.DropDownItems.Add($mi) | Out-Null
}

$ColorItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$PickColorItem = New-Object System.Windows.Forms.ToolStripMenuItem("Pick a Color...")
$PickColorItem.add_Click({
        # ColorDialog is a shell-owned modal dialog, so it activates correctly even
        # though we have no main window. The animation pauses while it is open.
        $dlg = New-Object System.Windows.Forms.ColorDialog
        $dlg.FullOpen = $true
        $dlg.Color = $global:eyeColor
        if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $global:eyeColor = $dlg.Color
            Save-Settings
            Sync-CustomMenu
        }
        $dlg.Dispose()
    })
$ColorItem.DropDownItems.Add($PickColorItem) | Out-Null

# --- Speed ---------------------------------------------------------------
# Custom-drawn 0..100 slider in the menu: 0 pauses the spin, 50 is the original
# speed. Drag, click, mouse wheel or arrow keys (PageUp/Down = 10); saved on release.
$SpeedItem = New-Object System.Windows.Forms.ToolStripMenuItem("Speed")
$CustomItem.DropDownItems.Add($SpeedItem) | Out-Null
$global:SpeedTrack = New-Object SharinganSlider($global:MenuTheme)
$global:SpeedTrack.Font = $global:MenuFont
$global:SpeedTrack.Caption = "Speed"
$global:SyncingSpeed = $true
$global:SpeedTrack.Value = $global:speedLevel
$global:SyncingSpeed = $false
$global:SpeedTrack.add_ValueChanged({
        if ($global:SyncingSpeed) { return }
        Set-SpeedLevel $global:SpeedTrack.Value
        Update-SpeedText
    })
$global:SpeedTrack.add_ValueCommitted({ Save-Settings })
$speedHost = New-Object System.Windows.Forms.ToolStripControlHost($global:SpeedTrack)
$speedHost.AutoSize = $false
$speedHost.Size = $global:SpeedTrack.Size
$speedHost.Margin = New-Object System.Windows.Forms.Padding(0)
$SpeedItem.DropDownItems.Add($speedHost) | Out-Null
$SpeedItem.DropDown.ShowImageMargin = $false     # no check-mark gutter beside the slider
Update-SpeedText

# --- Direction -----------------------------------------------------------
$DirectionItem = New-Object System.Windows.Forms.ToolStripMenuItem("Direction")
$CustomItem.DropDownItems.Add($DirectionItem) | Out-Null
Fill-ChoiceMenu $DirectionItem @(
    @{ Text = "Clockwise"; Value = 1 }
    @{ Text = "Counter-clockwise"; Value = -1 }
) `
{ $global:rotationDir } `
{ param($v) $global:rotationDir = [int]$v } | Out-Null

# --- Invert ----------------------------------------------------------------
# Swaps the tomoe/pattern colour with the eye colour: a dark eye with
# coloured tomoe instead of a coloured eye with dark tomoe.
$global:InvertItem = New-Object System.Windows.Forms.ToolStripMenuItem("Invert Colors")
$global:InvertItem.add_Click({
        $global:invertOn = -not $global:invertOn
        Save-Settings
        Sync-CustomMenu
    })
$CustomItem.DropDownItems.Add($global:InvertItem) | Out-Null

# --- Shuffle -------------------------------------------------------------
$ShuffleItem = New-Object System.Windows.Forms.ToolStripMenuItem("Shuffle")
$CustomItem.DropDownItems.Add($ShuffleItem) | Out-Null

$global:ShuffleToggle = New-Object System.Windows.Forms.ToolStripMenuItem("Randomly Cycle Eyes")
$global:ShuffleToggle.add_Click({
        $global:shuffleOn = -not $global:shuffleOn
        Save-Settings
        Sync-CustomMenu
    })
$ShuffleItem.DropDownItems.Add($global:ShuffleToggle) | Out-Null
$ShuffleItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$intervalChoices = @(
    @{ Text = "Every 5 seconds";  Value = 5 }
    @{ Text = "Every 10 seconds"; Value = 10 }
    @{ Text = "Every 30 seconds"; Value = 30 }
    @{ Text = "Every minute";     Value = 60 }
    @{ Text = "Every 5 minutes";  Value = 300 }
    @{ Text = "Every 15 minutes"; Value = 900 }
)
Add-ChoiceMenu $ShuffleItem "Interval" $intervalChoices `
{ $global:shuffleSeconds } `
{ param($v) $global:shuffleSeconds = [int]$v } | Out-Null

# --- Glow ----------------------------------------------------------------
# On/off, the heartbeat pulse (off = a steady glow) and the pulse speed.
$GlowMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Glow")
$CustomItem.DropDownItems.Add($GlowMenu) | Out-Null
$global:GlowItem = New-Object System.Windows.Forms.ToolStripMenuItem("On")
$global:GlowItem.add_Click({
        $global:glowOn = -not $global:glowOn
        Save-Settings
        Sync-CustomMenu
    })
$GlowMenu.DropDownItems.Add($global:GlowItem) | Out-Null
$global:PulseItem = New-Object System.Windows.Forms.ToolStripMenuItem("Heartbeat pulse")
$global:PulseItem.add_Click({
        $global:glowPulse = -not $global:glowPulse
        Save-Settings
        Sync-CustomMenu
    })
$GlowMenu.DropDownItems.Add($global:PulseItem) | Out-Null
$GlowMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$global:PulseTrack = New-Object SharinganSlider($global:MenuTheme)
$global:PulseTrack.Font = $global:MenuFont
$global:PulseTrack.Caption = "Pulse speed"
$global:PulseTrack.Minimum = 1
$global:SyncingPulse = $true
$global:PulseTrack.Value = $global:pulseLevel
$global:SyncingPulse = $false
$global:PulseTrack.add_ValueChanged({
        if ($global:SyncingPulse) { return }
        $global:pulseLevel = $global:PulseTrack.Value
        Update-PulseText
    })
$global:PulseTrack.add_ValueCommitted({ Save-Settings })
$pulseHost = New-Object System.Windows.Forms.ToolStripControlHost($global:PulseTrack)
$pulseHost.AutoSize = $false
$pulseHost.Size = $global:PulseTrack.Size
$pulseHost.Margin = New-Object System.Windows.Forms.Padding(0)
$GlowMenu.DropDownItems.Add($pulseHost) | Out-Null
Update-PulseText

# --- Profiles ------------------------------------------------------------
# A profile is the whole settings set in one small JSON file under .\profiles\.
# The list is rebuilt each time the submenu opens, so files dropped in by hand show up.
$ProfilesItem = New-Object System.Windows.Forms.ToolStripMenuItem("Profiles")
$CustomItem.DropDownItems.Add($ProfilesItem) | Out-Null

function Build-ProfilesMenu {
    $ProfilesItem.DropDownItems.Clear()
    $save = New-Object System.Windows.Forms.ToolStripMenuItem("Save current settings as...")
    $save.add_Click({
            try {
                Add-Type -AssemblyName Microsoft.VisualBasic
                $name = [Microsoft.VisualBasic.Interaction]::InputBox("Name for this profile:", "Save profile", "My profile")
            }
            catch { $name = "Profile " + (Get-Date -Format "yyyy-MM-dd HH-mm-ss") }
            if ($name -and $name.Trim()) { Save-Profile $name | Out-Null }
        })
    $ProfilesItem.DropDownItems.Add($save) | Out-Null
    $files = @()
    if (Test-Path $global:ProfilesDir) { $files = @(Get-ChildItem -Path $global:ProfilesDir -Filter *.json | Sort-Object Name) }
    if ($files.Count -gt 0) {
        $ProfilesItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
        foreach ($f in $files) {
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem($f.BaseName)
            $mi.Tag = $f.FullName
            $mi.add_Click({
                    if (Import-Profile $this.Tag) { Set-EyeStyle $global:selectedEyeStyle; Save-Settings; Sync-CustomMenu }
                })
            $ProfilesItem.DropDownItems.Add($mi) | Out-Null
        }
    }
    $ProfilesItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
    $open = New-Object System.Windows.Forms.ToolStripMenuItem("Open profiles folder")
    $open.add_Click({
            if (-not (Test-Path $global:ProfilesDir)) { New-Item -ItemType Directory -Path $global:ProfilesDir | Out-Null }
            Start-Process explorer.exe $global:ProfilesDir
        })
    $ProfilesItem.DropDownItems.Add($open) | Out-Null
}
$ProfilesItem.add_DropDownOpening({ Build-ProfilesMenu; Set-ModernMenu $ProfilesItem.DropDownItems })
Build-ProfilesMenu

# --- Reset ---------------------------------------------------------------
$CustomItem.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$ResetItem = New-Object System.Windows.Forms.ToolStripMenuItem("Reset to Defaults")
$ResetItem.add_Click({
        Reset-Defaults
        Save-Settings
        Sync-CustomMenu
    })
$CustomItem.DropDownItems.Add($ResetItem) | Out-Null

# Roomier, consistent items everywhere (the look itself comes from the renderer).
function Set-ModernMenu($items) {
    foreach ($it in $items) {
        if ($it -is [System.Windows.Forms.ToolStripMenuItem]) {
            $it.Padding = New-Object System.Windows.Forms.Padding(2, 5, 2, 5)
            $it.DropDown.Font = $global:MenuFont
            Set-ModernMenu $it.DropDownItems
        }
    }
}
$ContextMenu.Font = $global:MenuFont
Set-ModernMenu $ContextMenu.Items

Sync-CustomMenu

# Warm up CPU counter
Start-Sleep -Milliseconds 200
[Win32]::GetCPULoad() | Out-Null

# 4b. SVG eye engine (renders the files in .\eyes\ straight from their paths)
# Minimal SVG -> GDI+ engine for the Mangekyou eye files.
# Supports what those files use: circle, path (M L H V C S Z), g, use, transform
# (matrix/rotate/translate/scale), solid fills/strokes and one radial gradient.
$script:CI = [Globalization.CultureInfo]::InvariantCulture
$script:XLINK = 'http://www.w3.org/1999/xlink'
$script:SkipTags = @('defs','metadata','title','namedview','clipPath','radialGradient','linearGradient','rect')

function Get-Num([string]$s) { [double]::Parse(($s.Trim() -replace 'px$', ''), $script:CI) }

function ConvertTo-SvgColor([string]$v) {
    if (-not $v) { return $null }
    $v = $v.Trim().ToLower()
    if ($v -eq 'none') { return $null }
    if ($v -eq 'black') { return [Drawing.Color]::Black }
    if ($v -eq 'white') { return [Drawing.Color]::White }
    if ($v -match '^#([0-9a-f])([0-9a-f])([0-9a-f])$') {
        return [Drawing.Color]::FromArgb([Convert]::ToInt32("$($Matches[1])$($Matches[1])", 16), [Convert]::ToInt32("$($Matches[2])$($Matches[2])", 16), [Convert]::ToInt32("$($Matches[3])$($Matches[3])", 16))
    }
    if ($v -match '^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$') {
        return [Drawing.Color]::FromArgb([Convert]::ToInt32($Matches[1], 16), [Convert]::ToInt32($Matches[2], 16), [Convert]::ToInt32($Matches[3], 16))
    }
    return $null
}

function ConvertTo-SvgMatrix([string]$t) {
    $m = New-Object Drawing.Drawing2D.Matrix
    if (-not $t) { return $m }
    foreach ($mt in [regex]::Matches($t, '(\w+)\s*\(([^)]*)\)')) {
        $a = @([regex]::Split($mt.Groups[2].Value.Trim(), '[\s,]+') | Where-Object { $_ -ne '' } | ForEach-Object { [double]::Parse($_, $script:CI) })
        $e = New-Object Drawing.Drawing2D.Matrix
        switch ($mt.Groups[1].Value) {
            'matrix' { $e = New-Object Drawing.Drawing2D.Matrix([single]$a[0], [single]$a[1], [single]$a[2], [single]$a[3], [single]$a[4], [single]$a[5]) }
            'rotate' {
                if ($a.Count -ge 3) { $e.RotateAt([single]$a[0], (New-Object Drawing.PointF([single]$a[1], [single]$a[2]))) }
                else { $e.Rotate([single]$a[0]) }
            }
            'translate' { $ty = 0.0; if ($a.Count -gt 1) { $ty = $a[1] }; $e.Translate([single]$a[0], [single]$ty) }
            'scale' { $sy = $a[0]; if ($a.Count -gt 1) { $sy = $a[1] }; $e.Scale([single]$a[0], [single]$sy) }
        }
        # list order "A B": B hits the points first, so each later one is prepended.
        $m.Multiply($e, [Drawing.Drawing2D.MatrixOrder]::Prepend)
    }
    return $m
}

function ConvertTo-GdiPath([string]$d) {
    $tk = [regex]::Matches($d, '[MmLlHhVvCcSsZz]|-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?')
    $gp = New-Object Drawing.Drawing2D.GraphicsPath([Drawing.Drawing2D.FillMode]::Winding)
    $i = 0; $n = $tk.Count
    $cx = 0.0; $cy = 0.0; $sx = 0.0; $sy = 0.0; $cmd = ''
    $c2x = 0.0; $c2y = 0.0; $prevCubic = $false; $needStart = $false
    while ($i -lt $n) {
        $s = $tk[$i].Value
        if ($s -match '^[A-Za-z]$') { $cmd = $s; $i++ }
        if ($cmd -ceq 'Z' -or $cmd -ceq 'z') {
            $gp.CloseFigure(); $cx = $sx; $cy = $sy; $needStart = $true; $prevCubic = $false
            if ($i -lt $n -and $tk[$i].Value -notmatch '^[A-Za-z]$') { $cmd = 'L' }  # stray numbers
            continue
        }
        $rel = ($cmd -cmatch '[a-z]')
        $up = $cmd.ToUpper()
        $ox = 0.0; $oy = 0.0
        if ($rel) { $ox = $cx; $oy = $cy }
        if ($up -eq 'M') {
            $x = $ox + [double]::Parse($tk[$i].Value, $script:CI); $y = $oy + [double]::Parse($tk[$i + 1].Value, $script:CI); $i += 2
            $gp.StartFigure(); $cx = $x; $cy = $y; $sx = $x; $sy = $y; $needStart = $false; $prevCubic = $false
            if ($rel) { $cmd = 'l' } else { $cmd = 'L' }
        }
        elseif ($up -eq 'L') {
            $x = $ox + [double]::Parse($tk[$i].Value, $script:CI); $y = $oy + [double]::Parse($tk[$i + 1].Value, $script:CI); $i += 2
            if ($needStart) { $gp.StartFigure(); $needStart = $false }
            $gp.AddLine([single]$cx, [single]$cy, [single]$x, [single]$y); $cx = $x; $cy = $y; $prevCubic = $false
        }
        elseif ($up -eq 'H') {
            $x = $ox + [double]::Parse($tk[$i].Value, $script:CI); $i++
            if ($needStart) { $gp.StartFigure(); $needStart = $false }
            $gp.AddLine([single]$cx, [single]$cy, [single]$x, [single]$cy); $cx = $x; $prevCubic = $false
        }
        elseif ($up -eq 'V') {
            $y = $oy + [double]::Parse($tk[$i].Value, $script:CI); $i++
            if ($needStart) { $gp.StartFigure(); $needStart = $false }
            $gp.AddLine([single]$cx, [single]$cy, [single]$cx, [single]$y); $cy = $y; $prevCubic = $false
        }
        elseif ($up -eq 'C' -or $up -eq 'S') {
            if ($up -eq 'C') {
                $x1 = $ox + [double]::Parse($tk[$i].Value, $script:CI); $y1 = $oy + [double]::Parse($tk[$i + 1].Value, $script:CI); $i += 2
            }
            else {
                if ($prevCubic) { $x1 = 2 * $cx - $c2x; $y1 = 2 * $cy - $c2y } else { $x1 = $cx; $y1 = $cy }
            }
            $x2 = $ox + [double]::Parse($tk[$i].Value, $script:CI); $y2 = $oy + [double]::Parse($tk[$i + 1].Value, $script:CI)
            $x = $ox + [double]::Parse($tk[$i + 2].Value, $script:CI); $y = $oy + [double]::Parse($tk[$i + 3].Value, $script:CI); $i += 4
            if ($needStart) { $gp.StartFigure(); $needStart = $false }
            $gp.AddBezier([single]$cx, [single]$cy, [single]$x1, [single]$y1, [single]$x2, [single]$y2, [single]$x, [single]$y)
            $c2x = $x2; $c2y = $y2; $cx = $x; $cy = $y; $prevCubic = $true
        }
        else { throw "Unsupported path command '$cmd'" }
    }
    return $gp
}

function Get-StyleMap($node, $inherit) {
    $s = @{}
    foreach ($k in $inherit.Keys) { $s[$k] = $inherit[$k] }
    foreach ($a in 'fill', 'stroke', 'stroke-width') {
        if ($node.HasAttribute($a)) { $s[$a] = $node.GetAttribute($a) }
    }
    if ($node.HasAttribute('style')) {
        foreach ($pair in $node.GetAttribute('style').Split(';')) {
            $kv = $pair.Split(':', 2)
            if ($kv.Count -eq 2) { $s[$kv[0].Trim()] = $kv[1].Trim() }
        }
    }
    return $s
}

function Get-GradientSpec($ids, [string]$ref) {
    $id = $ref -replace '^url\(#', '' -replace '\)$', ''
    $gn = $ids[$id]
    if (-not $gn) { return $null }
    $stops = @()
    $pos = 0
    foreach ($st in $gn.ChildNodes) {
        if ($st.LocalName -ne 'stop') { continue }
        $off = 0.0
        if ($st.HasAttribute('offset')) { $off = Get-Num $st.GetAttribute('offset') }
        $col = $null
        if ($st.HasAttribute('stop-color')) { $col = ConvertTo-SvgColor $st.GetAttribute('stop-color') }
        if ($st.HasAttribute('style')) {
            foreach ($pair in $st.GetAttribute('style').Split(';')) {
                $kv = $pair.Split(':', 2)
                if ($kv.Count -eq 2 -and $kv[0].Trim() -eq 'stop-color') { $col = ConvertTo-SvgColor $kv[1] }
            }
        }
        $stops += , @{ O = $off; C = $col }
        $pos++
    }
    $spec = @{ Stops = $stops; User = ($gn.GetAttribute('gradientUnits') -eq 'userSpaceOnUse'); Cx = 0.5; Cy = 0.5; R = 0.5; M = (ConvertTo-SvgMatrix $gn.GetAttribute('gradientTransform')) }
    if ($gn.HasAttribute('cx')) { $spec.Cx = Get-Num $gn.GetAttribute('cx') }
    if ($gn.HasAttribute('cy')) { $spec.Cy = Get-Num $gn.GetAttribute('cy') }
    if ($gn.HasAttribute('r')) { $spec.R = Get-Num $gn.GetAttribute('r') }
    return $spec
}

function Add-SvgItems($node, $inh, $mat, $ids, $items) {
    $tag = $node.LocalName
    if ($script:SkipTags -contains $tag) { return }
    $style = Get-StyleMap $node $inh
    $m = $mat.Clone()
    if ($node.HasAttribute('transform')) {
        $m.Multiply((ConvertTo-SvgMatrix $node.GetAttribute('transform')), [Drawing.Drawing2D.MatrixOrder]::Prepend)
    }
    switch ($tag) {
        'g' { foreach ($c in $node.ChildNodes) { if ($c.NodeType -eq 'Element') { Add-SvgItems $c $style $m $ids $items } }; return }
        'use' {
            $ref = $node.GetAttribute('href', $script:XLINK) -replace '^#', ''
            if ($ids.ContainsKey($ref)) { Add-SvgItems $ids[$ref] $style $m $ids $items }
            return
        }
        'svg' { foreach ($c in $node.ChildNodes) { if ($c.NodeType -eq 'Element') { Add-SvgItems $c $style $m $ids $items } }; return }
        'circle' {
            $cx = Get-Num $node.GetAttribute('cx'); $cy = Get-Num $node.GetAttribute('cy'); $r = Get-Num $node.GetAttribute('r')
            $gp = New-Object Drawing.Drawing2D.GraphicsPath
            $gp.AddEllipse([single]($cx - $r), [single]($cy - $r), [single]($r * 2), [single]($r * 2))
        }
        'path' { $gp = ConvertTo-GdiPath $node.GetAttribute('d') }
        default { return }
    }
    $gp.Transform($m)
    $el = $m.Elements
    $scale = [Math]::Sqrt([Math]::Abs($el[0] * $el[3] - $el[1] * $el[2]))
    $fillV = 'black'
    if ($style.ContainsKey('fill')) { $fillV = $style['fill'] }
    $item = @{ Path = $gp; Fill = $null; Grad = $null; Stroke = $null; Width = 0.0; Brush = $null }
    if ($fillV -like 'url(*') {
        $g = Get-GradientSpec $ids $fillV
        if ($g) {
            $b = $gp.GetBounds()
            if ($g.User) {
                $p = New-Object Drawing.PointF([single]$g.Cx, [single]$g.Cy)
                $pr = New-Object Drawing.PointF([single]($g.Cx + $g.R), [single]$g.Cy)
                $arr = [Drawing.PointF[]]@($p, $pr)
                $g.M.TransformPoints($arr)
                $item.GCx = $arr[0].X; $item.GCy = $arr[0].Y
                $item.GR = [Math]::Abs($arr[1].X - $arr[0].X)
            }
            else {
                $item.GCx = $b.X + $b.Width / 2; $item.GCy = $b.Y + $b.Height / 2; $item.GR = $b.Width / 2
            }
            $item.Grad = $g
        }
    }
    else { $item.Fill = ConvertTo-SvgColor $fillV }
    if ($style.ContainsKey('stroke')) { $item.Stroke = ConvertTo-SvgColor $style['stroke'] }
    if ($item.Stroke) {
        $w = 1.0
        if ($style.ContainsKey('stroke-width')) { $w = Get-Num $style['stroke-width'] }
        $item.Width = $w * $scale
    }
    $items.Add($item) | Out-Null
}

function Import-SvgEye([string]$file) {
    $xml = New-Object Xml.XmlDocument
    $xml.Load($file)
    $ids = @{}
    foreach ($n in $xml.SelectNodes('//*[@id]')) { $ids[$n.GetAttribute('id')] = $n }
    $items = New-Object Collections.Generic.List[object]
    Add-SvgItems $xml.DocumentElement @{} (New-Object Drawing.Drawing2D.Matrix) $ids $items
    # The iris is the first gradient-filled shape; everything after it is the pattern.
    $iris = $null; $pattern = New-Object Collections.Generic.List[object]
    foreach ($it in $items) {
        if (-not $iris -and $it.Grad) { $iris = $it } elseif ($iris) { $pattern.Add($it) | Out-Null }
    }
    if (-not $iris) { throw "No gradient iris found in $file" }
    return @{ Iris = $iris; Pattern = $pattern; File = $file }
}

# Tint: SVG reds are all shades of #c30000. Map a colour to the user's eye
# colour by brightness (R/195), so the default reproduces the artwork exactly
# and any other colour is the same picture in that hue.
function Get-ArtTint([System.Drawing.Color]$c, [System.Drawing.Color]$tint) {
    $f = $c.R / 195.0
    return [System.Drawing.Color]::FromArgb($c.A,
        [int][Math]::Min(255, [Math]::Round($tint.R * $f)),
        [int][Math]::Min(255, [Math]::Round($tint.G * $f)),
        [int][Math]::Min(255, [Math]::Round($tint.B * $f)))
}

function Get-ArtGradientBrush($item, [System.Drawing.Color]$tint) {
    $key = "$($tint.R),$($tint.G),$($tint.B)"
    if ($item.Brush -and $item.BrushKey -eq $key) { return $item.Brush }
    if ($item.Brush) { $item.Brush.Dispose() }
    $r = $item.GR
    $ep = New-Object System.Drawing.Drawing2D.GraphicsPath
    $ep.AddEllipse([single]($item.GCx - $r), [single]($item.GCy - $r), [single]($r * 2), [single]($r * 2))
    $pb = New-Object System.Drawing.Drawing2D.PathGradientBrush($ep)
    $stops = $item.Grad.Stops
    $cb = New-Object System.Drawing.Drawing2D.ColorBlend($stops.Count)
    $cols = New-Object 'System.Drawing.Color[]' $stops.Count
    $pos = New-Object 'single[]' $stops.Count
    for ($k = 0; $k -lt $stops.Count; $k++) {
        $st = $stops[$stops.Count - 1 - $k]        # PathGradientBrush runs edge(0) -> centre(1)
        $cols[$k] = Get-ArtTint $st.C $tint
        $pos[$k] = [single](1.0 - $st.O)
    }
    $pos[0] = 0.0; $pos[$stops.Count - 1] = 1.0
    $cb.Colors = $cols; $cb.Positions = $pos
    $pb.InterpolationColors = $cb
    $item.Brush = $pb; $item.BrushKey = $key
    return $pb
}

$script:StdIris = $null
# The red iris disc shared by every eye: r=145 plus a 10-wide black rim.
function Write-StdIris($g, [System.Drawing.Color]$tint) {
    if (-not $script:StdIris) {
        $gp = New-Object System.Drawing.Drawing2D.GraphicsPath
        $gp.AddEllipse(5, 5, 290, 290)
        $script:StdIris = @{
            Path = $gp; GCx = 150.0; GCy = 150.0; GR = 145.0; Brush = $null; BrushKey = $null
            Grad = @{ Stops = @(
                    @{ O = 0.0; C = [System.Drawing.Color]::FromArgb(102, 0, 0) },
                    @{ O = 0.5; C = [System.Drawing.Color]::FromArgb(195, 0, 0) },
                    @{ O = 1.0; C = [System.Drawing.Color]::FromArgb(160, 0, 0) }) }
        }
    }
    $it = $script:StdIris
    $eb = New-Object System.Drawing.SolidBrush((Get-ArtTint ([System.Drawing.Color]::FromArgb(160, 0, 0)) $tint))
    $g.FillPath($eb, $it.Path); $eb.Dispose()                  # no hairline gap at the rim
    $g.FillPath((Get-ArtGradientBrush $it $tint), $it.Path)
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 10.0)
    $g.DrawPath($pen, $it.Path); $pen.Dispose()
}

# Draw an eye's pattern items (already in 300x300 SVG space).
function Write-ArtPattern($g, $art, [System.Drawing.Color]$tint, [double]$alpha = 1.0) {
    $a255 = [int][Math]::Round(255.0 * [Math]::Max(0.0, [Math]::Min(1.0, $alpha)))
    if ($art.Raster) {
        # Pictures: use the red channel as brightness, shift it toward the eye
        # colour. At the default colour this is the identity, so the picture is exact.
        $key = "$($tint.R),$($tint.G),$($tint.B),$a255"
        if ($art.AttrKey -ne $key) {
            if ($art.Attr) { $art.Attr.Dispose() }
            $cm = New-Object System.Drawing.Imaging.ColorMatrix
            $cm.Matrix00 = $tint.R / 195.0; $cm.Matrix01 = $tint.G / 195.0; $cm.Matrix02 = $tint.B / 195.0
            $cm.Matrix11 = 1.0; $cm.Matrix22 = 1.0; $cm.Matrix33 = $a255 / 255.0; $cm.Matrix44 = 1.0
            $ia = New-Object System.Drawing.Imaging.ImageAttributes
            $ia.SetColorMatrix($cm)
            $art.Attr = $ia; $art.AttrKey = $key
        }
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $w = $art.Raster.Width; $h = $art.Raster.Height
        $g.DrawImage($art.Raster, (New-Object System.Drawing.Rectangle(0, 0, 300, 300)), 0, 0, $w, $h, [System.Drawing.GraphicsUnit]::Pixel, $art.Attr)
        return
    }
    foreach ($it in $art.Pattern) {
        if ($it.Fill) {
            $br = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb($a255, (Get-ArtTint $it.Fill $tint)))
            $g.FillPath($br, $it.Path); $br.Dispose()
        }
        elseif ($it.Grad) {
            $g.FillPath((Get-ArtGradientBrush $it $tint), $it.Path)
        }
        if ($it.Stroke -and $it.Width -gt 0) {
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb($a255, (Get-ArtTint $it.Stroke $tint)), [single]$it.Width)
            $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Miter; $pen.MiterLimit = 4
            $g.DrawPath($pen, $it.Path); $pen.Dispose()
        }
    }
}

function Import-RasterEye([string]$path) {
    $raw = New-Object System.Drawing.Bitmap($path)
    $bmp = New-Object System.Drawing.Bitmap($raw)              # detach: do not keep the file locked
    $raw.Dispose()
    return @{ Raster = $bmp; Pattern = $null; Attr = $null; AttrKey = $null }
}

# 4c. Eye artwork loader. The files are listed in $global:EyeFiles (section 2).
# If a V1 file is missing or unreadable, that eye falls back to a hand-drawn one.
$global:ArtFallback = @{ "Kakashi/Obito" = "Kakashi"; "BOoD" = "Itachi"; "BOoD2" = "Itachi" }
$script:EyeArtCache = @{}

# Classic eyes: each Mangekyou pattern traced from its V1 design into outlines in
# the same 300-unit space. Per outline: point count (2 bytes), then one byte each
# for x and y over 10..290. Filled black with the alternate rule (holes stay red).
# BEGIN CLASSIC SHAPES (generated by _local/tools/eye-trace/trace-eyes.ps1)
$global:ClassicShapes = @{
    'Itachi' = 'AE6YAZkBkguNE4cghCeCMII4g0CFSIhOi1SPWJRem2KmabRywn3Hgc+J1ZDbmd6e46jmsOa55sHmx+PR4NbbytbB0rvLssetvae2o6ygqKCgoJuhlKOMpneyZbpWv0jDOMQswyXBH78ZvBS5DLIFqhqrJ6oxqDqmQqFJnE6VUZJUjFeAWXZaXVxKYDhjLmYnaiBtGnITeQ2ACIcFkAIAHn5tem52cHVxcXVwdW56bX5tgW6FcIlzjHWOepF+koGShZGJj4yNjoqRhZKBkn6Re492jHOKcYlvhW6BbQ=='
    'Obito' = 'AEGAAIUAhwCQBZ0LqRSyG7skwSzIN89C1E3ZWtxq3XTegd2Q253nq/C28rztxerG4szX0s3Yxtu73rLhpOOW5IfjdeBl21vXU9NLzkTKQMY5wCPEFMUSxQ28DroNrAyfDZUPixCBFHYZax9fJlQuSzdCPzpIM1UrXyZrI3EQdAp4AHoAABRoKlsuUzNMOEk6QUM7SzhRNFgxYTBmLm8ueC6AL4gxjkZ7W2tgTGM9ABiaNZ5FoFKka7B0vX/HidaW15DYidh+13fWctNp0WLNWsdSwky8RrZCrzyoOKA2mjQAIH5meGdzam9ra29qc2d4Zn5mgWeIaoxskXCUc5Z4mH2ZgpmHmIyWkJOTkJaMmIeZgpl9mHeVc5NukGuMaodngWYAFn+qcbBct0G+RMJNyFTMW9Bi0mrUcNV31YDVh9OP0ZjPoMuoxq/As7yXs4Cq'
    'Kakashi' = 'AEGAAIUAhwCQBZ0LqRSyG7skwSzIN89C1E3ZWtxq3XTegd2Q253nq/C28rztxerG4szX0s3Yxtu73rLhpOOW5IfjdeBl21vXU9NLzkTKQMY5wCPEFMUSxQ28DroNrAyfDZUPixCBFHYZax9fJlQuSzdCPzpIM1UrXyZrI3EQdAp4AHoAABRoKlsuUzNMOEk6QUM7SzhRNFgxYTBmLm8ueC6AL4gxjkZ7W2tgTGM9ABiaNZ5FoFKka7B0vX/HidaW15DYidh+13fWctNp0WLNWsdSwky8RrZCrzyoOKA2mjQAIH5meGdzam9ra29qc2d4Zn5mgWeIaoxskXCUc5Z4mH2ZgpmHmIyWkJOTkJaMmIeZgpl9mHeVc5NukGuMaodngWYAFn+qcbBct0G+RMJNyFTMW9Bi0mrUcNV31YDVh9OP0ZjPoMuoxq/As7yXs4Cq'
    'Madara' = 'AEiAC4cMig6SEZsUphmtHbckvSrEL8o40EDTRdlQ3FngZONw5HjlguWX55/pqOit57LmtuK93MPWx8zQxtS+2bPdqeGe5JfliuaA5XLjZuBb3FDZRdM4yy/JKscmxiPCH78buhq2F64XqBSZE4wThRV4GG0bYiFYJk4sRzQ9QTFHLVAmYRxiG2YXbBFzDnUNegwAIH4aehp1G3MdbyFtJGsoayxrL2szbThwO3I9dUB6Qn1CgkKFQopAjD2POpI4lDOUMJQrlCiSJI8gjB2KHIUagRoAWFovVzBSNEk7P0U4UDJbMGMvay9xMXU0fDiDPIdCiEeKS4tQkFSUVpdZnlqkW6har1i0V7hUvU/CTMVMx03JUMtZz2HRbdR41YDVhtWN05bQm8ygxqS/qLamsaWrpaeloaibqpWtkrGPtIu7ib+Hx4fPiNaK14nYhdh913XUatFhzVnHUL9Iu0W2QrJBrUCoQKJBm0KXRpNKjE2KToJPfU94T3JMbEpqSGVDYT5gOV0vAB+AZoVniWiNapJtlHGXdZh6mYCYhZeKlI6Rk46UipeFmICZeph2l3OVbpJrjmiKZ4VmgGd4aXRrb29rdGl6ZwAfN5QylS6WLJkpnCaeJKMkpySqJK0lsSi0K7guujK8Nr07vT69QrtFuUm1TLFMrU2oTKRMoEmdRplDlz6UOpQAHsWUwZS8l7ebtJ+zorKmsquyr7Syt7a6uL27wb3Evcm9zL3Ru9S417TZstut26vbp9qg15zUmdGXzpXKlA=='
    'Izuna' = 'AD2AAI4AlQCeAp8vqTStNrI6uT/CSMdPylTOW9Fi1HDVdtaA1Yz8o/ex8MDqyebP3Nrb2rXDqcue0ZXTjtWH1oDWeNZx1WrTYtFazlbLSsMj2hvRE8YOvQixA6MqjCmAKXkqcyxrLmExWzRWOE4/RUk8UzZgL2ECagBxAAAffm96cHhxdXNzdXF4cHpvfm+BcIRxiHOKdYx3jnuPfpCBkIWPiY2Mio2Jj4SQgZB+j3uOd4x1inOIcYVwgW8='
    'Sasuke' = 'AECAAIsAmAGkBLEIvQ7JFdQd3CXmMOw58UL3Tvtb/mf/dP+A/4v+mPuk+K/xvezG5s/d2dTiyeq98bH3pPuY/ov/gP90/2f+W/tO90LxNuor4iPaGs8Txg69CLEEpAGYAIsAgAB0AWcEWwdQDkITORowIiYrHTYVQg5OCFsEZwF0AAAQgAB8A3YLbRpmKmI0X0BrQoBLlEOgQJ0zmSqRGowPhwgAEiA9Fj4QPxNHGFEhYC5xNns3fDh8Q3FRZVVUWENXQkxBOj4xPQARzj3APrZAqUKnQ6pUrmW8cMd8zXbUbuBd6E/sSO9A6T7fPQAIXURZVFdhX1xnV3pMakddQwAIoUSVR4VMmFegW6hhpVCiRAAYgE95UmpaX2FWaFV0VIBVi1aXXZ5qpXmtgLCGrZSmnqCpl6qMq4Cqc6loo2OWWopUAAZRa0R2OoBHjFGUUIAABq5rr4CvlLyIxYC6dQAbgG2Dbodvi3KOdZB4kXuSgJGGj4qMjIeQg5KAknySeZF1jnGKb4duhG2AbnxveHJ0dXF4b3xuABE3gyuSH6IYrxO3EMAYwR/CKMIywki/Vr1YvFWsUZpEjziDABTHg7uQrpqqq6e9qb23v83C18LgwunB78Dvv+686bLkqN+h2pjRjsiEAAdXnlmuXbxtt3qyaKhfowAHqJ6gpJeohbKWuKK8pqsADoC1cLtfwGbVbuZz73j3gP+I9pHnmdSgwKC/lLw='
    'Shisui' = 'ADCVApITkB2OKo04nUGqS7lWx2HUbOJ48If9lO+S4o/VjceMvpu0qam4nsaS1Ynefepq/G7tcOFy03PHYr1XtEeoOp4skh+GD3YDaQ9sHG8scThyQmRMVFZGYjhuKn0aigwAIH5id2NyZmxqamxmcmN3Yn5igWOIZo5pkm2WcZl2nHydg52JnI2ZkpaWkpmOnImdgp19nHaZcZZtkmmOZohjgWIAFIB1g3WHd4l6inyKgIqDiIeGiYOKgIp9inmJdoV1g3WAdXx3eHh3e3U='
    'Indra' = 'ASN7GooclR6eIaQkrii2LbswxDnIPs5E1FDaW9ti3Wvfd96F3I/ZnNKoy7PDvLvDssipzKHPltGM04DSddFqzmDJWcZRv0u4RLBApzudOZQ4jDiDOXs8cj9rQmNIXU1XVFFaTWBKakdxRXtEgESIRo5HlEqYTJ5Po1SoWqxfsGaybLNxtHu0gLOGsoyulKqYpp6fo5mmlKiPqIqpgal4p3SkcKJrnmeYZJFiimKFZH5memh2bXJyb3Vue21/bYNvh3GJc4p2jHyLf4qDiIeDioCKfIp4iXWFdYN1gHV+dnl5dnh2dHhwe22Aa4Vrim2Pb5RzmHWbe55/n4WgiqCOoJSenZmjlKeNqYerfqt2qnCoa6Zmo2GfXZtZlVWSU45Rh06ATXtNcE5rUGVSYFRZWFZbT2FMZUlrRXJCekKAQodCj0OYR6FKqE2tUbJXuF+9ZcJtxnTHgMmHypLJnMejxajDsr26uMGxxqvLpNCa05DVhdZ81XHTZtBcy1LGSsBCuDqvM6UunSqUJ4olgCRzJGklXShSLUYyPjg0QS1JJlIgXhtqGXUXgReNGJYaoB2sIbMkuyvFMMwz0DzZReBN5VToXu1p8HLyevOD9I/zmPKg8anvsuy86Mfi0Nzb0+LM5sfuvPSy+aj7nvye/Z76qPex8MDqyebP4NbZ3dHky+jE7rzyq/ih+pr7jvyA/HH7afpf9lLxSu0/5jfgLtgn0B/DGbgUrRGhD5gOjA6DD3YRaxVhGlUhSilAMTc6MEUoTyRYIGMdbBs='
    'Shin' = 'ADaBCJMxnDSgNqg5sT+2Q71Lw1PGV8lfzWjPcdB40YDQic+QzJnmvbi6s72uwqbHn8qXzZDPh9CA0XjQcM9ozWHKWsdUw0m7GsAZwDOaMZMvii6AL3kwbzJoNWA4WT1SQ0lJQ08/VjpeNmM0bzA='
    'Sarada' = 'AAmABJk+kjuLOoA4eTlxOms8Zj4ACSgnYz9ZQ1RHT0xJUkVXP2IoKAAJ1yjAYr1cuVe1UrBMp0WgQZw/ACCAZYVmimeOapJslXGYdpl6moCahJiKlo6UkY+VipiEmoCae5p2mHGWbZRqj2eKZoVlgGZ6Z3Vpcmxtcml1Z3pmAAbBZfp/wZjFi8aAxXMACT1mOnI5eDiAOYo7kj6ZPZkEgAAJP5xCoUWoSa1OslS3WLpivyjXAAq/nNXU1tbW15u/pbuus7KvuKi9ogAKmcCA+mbBa8JzxHfFf8WHxYzElMI='
    'Naka' = 'AC+AAI4AmwGoBbYKxBHPGtki4ivqNvFC9077W/5n/3b/hf+T+oX1e+9w5mLeWdZQzknFQro9szqsOKI2lTSINHw1bTdrNWgzYy1hKV8hXxhgE2ENYwllBWoCawBtAHQAAC5QB0gSPx84LTM3L0ArTSlXKGEoail0K3wuhzOSOZ5AqEqzSblIvUTFP8o6zjPRLtIo0yHSG9EXyxHEDr0JtAWqA6EAkgCJAIAAcQJiBFsHUA5CFTYdKykfNBdCDgAggGiEaYlqi2uPbZNylXaWepeAloWViZSMkZCNk4mVg5eAl3yXd5V0lHGSbI5qiWmEaIBpe2p2a3VtcHFsdWt7aQAgfmp5a3VscW9vcWx1a3pqfmqCa4Vsim6NcpF1k3mUfZWClYeUipOOkJGNk4qUhpWClX2UeZN1kXKNbopshWuBagAUgHKFc4d1inaMe42AjIWKiIiKhYyAjXqMdop1iXOFcoBzenV2d3V6cwAy1ZHckuKT6JbumvKf9aT4q/iu+LDxve7E6Mvg1tndz+bG7L3xtvWt+aT7m/6S/4X/ev90/2v/Yv1X+k73P/A26i/lPuZM517naOZx5X3iiN6S2pvUo86sxbG/uLa+qcSex5TOkg=='
    'Baru' = 'AFKBAIoAlQChA6oFtAm9DsYTzxrWH9wl4y7pN+9A9Ev4VPxh6EzeQtM5yTTBMb0wty+sMaYyoTTyvO7E6Mvk0d3Z0eTL6MTutvWv+KT7nv2V/4P/d/9v/mP8XPpx9oPxjO6T65zmo+Co2KvTrc6xwhDBDr0IsQWqA6EAkgCJAIAAdAFnA10HUQ5EFTgdLiYjIDgcSBpWGWAaaxxzH3gkfymFLIh+AAAFgAUvihO97b2CCQAfgGmEaolrjGyQb5NzlHaVe5aAlYWUiZKMj5GLk4mUg5aAlnqVdpRzk3CQbYxriWqEaYBqeGt1bnFxbnZre2o='
    'Rai' = 'AKpcA1UQUBpNI0oxSEBIUUllTHZSiVGAUnVVbVllX19iW2hXbVV1U39Rf1CARYM8iTCOJpQfmxakDqoJrQeuCK0JpQ+cGJQhjiqKMoU+gkeAUIFRh1KLUJNPo06yTr9QzlLfV+9b/WH/av9x/4D/jv+V/Z/1ku+K6oPfedFvxWe8YrJeoFeVVY9Ul1eeXKNhp2epa6tvrXaugK2HrIurj6iWsp65psCwxrrLx8/R0dzR4dHi0OPQ4c7XzM3HwcK3vKu4p7CeqJeknaKioKiZtpLBiNB93nDrZPVc+1f6Tvc/8DbqMOYl3CzcN9tH2lbVZs9ty3bGhruQspqonqKZp5Crh619rnitc6xsqWioYKFcnleXTZxAnjefKp8dnhGcB5gBlAKTBZULlxKaGJsjnS+eO55EnEyaV5ZUkE2KSYNDezpoNl8wTyxCKDMmIzAaNhU/D04IACR8U3NVbldqWGJeXmJYalduVXNTfFODVIlVjFiVXZxjomqnc6p8rIOsjaqVp5yiopynlaiSqoysg6x8qnOnaqJjnV2WWY1VhVMAG4Btg26Hb4tyjnWQeJF7koCRho+KjIyHkIOSgJJ8knmRdY5xim+HboRtgG58b3hydHVxeG98bg=='
    'Naori' = 'AJyXAKEDrwe9DsYTzxrZIuIr6jbwQPZL+lf+ZP9x/4D/i/6Y/KL7lvqL9oDwdexs5mTdXNlZ1VfTWJV6loCWg5SJk4uRj46Si5OHlYbYhtuH3YrgjeOS5ZbmnOak56/mvuTK39ba4tLd2dbgyeq98bT2qvqb/pL/if+A/3b/Z/5e/FX6S/ZC8TnsMOYp4CTbJNou3zjjQ+ZQ51nnXuZp5XHidt543XmVdZRxkm+Pa4priGqEaYBpei5XLFcqVyZYIlseXhlkEm0OeAqBB5IGngarBagCnQCUAIkAgAB2AWcDXgVVCUsOQhc0Gy4iJikfMBo2FT8PTghXBV8CXwNSDEsSRBo9JDcuMzsxRTJJM0twb3Jtdmt7aoBph2qKa45uj27MTM1JzkPOPs06yjHEJrwdsRKoDKMHlgE='
    'Fugaku' = 'AFwwLzYvPTBEMk01VzhlQXBIe1CBUIlRkVSXV55cpGGpaq1zsnW3dr52x3XRcdhs4GbnXu9U9Ur1TfNW8F7tY+lo43Heddd8z4HEiLmNq5Snm6GgnqSXqJOrja2Fr3yvc65vsWu1aLtlw2TKZNVm4WnrbvZz/2/9afZl8mHqXuRb3FjUV81XxFe3V6tZnFWUU45Rh1CAUXZUbFhlXl9eWl1XWlFWSk9ES0FEPjg5LjchNRY1GzMiMSkvABu9RMNFxkfIScpLzE7NUM5VzFvKX8dhw2O9ZLpkt2O0YbJfsF2vWq5XrVSuUa9OsUuzSLhFu0QAFztQPlBCUUVTSFZKWUtgS2RIakVsQm4+bztvN28xbC5pLWYsYCxdLVkvVjFUNlEAIX1UeFVzVmpZZF5eZFlqVnNUelSDVoxZlF6bZKFrpnOpfKuDq4yplaaboqCdppWpjKuDq3ypc6ZroWSbXpRYjFaFVAAfgGmEaolrjGyQb5NzlHaVe5aAlYWUiZKMj5GLk4mUg5aAlnqVdpRzk3CQbYxriWqEaYBqeGt1bnFxbnZre2oAGYa7ibuMvJG/k8GUxZbLlNGT1JDXjdmK24bbg9uA2nzXedR30XbLdsd3xHnBfL6AvIO7'
    'Fugaku Eternal' = 'AECAAIsAmAGkBLEIvQ7JFdQd3CXmMOw58UL3Tvtb/mf/dP+A/4v+mPuk+K/xvezG5s/d2dTiyeq98bH3pPuY/ov/gP90/2f+W/tO90LxNuor4iPaGs8Txg69CLEEpAGYAIsAgAB0AWcEWwdQDkITORowIiYrHTYVQg5OCFsEZwF0AAA1dwBpAlwFUwdEDjsTLhwoIh4uGDUPQgpNBVcCZgBxAH4Ahgd/DXkUdRtwJGspajJnPWRBXUNXS05OS1dEW0JiPmc8bjl5OIo4jjSTMJYvmy6eLqMuqC+sMa0wsCiyHbITsgyxCaUFlgKIAAAUgA6FD4kRixWNGY0bjCGKI4klhSiAKXkndSRzIXIbcxZ1E3USeA96DwAyug+8FL0dvya/Lr82vUC5VL1bwWLFbMZyx3rHhcaNxJe+orirurK7trq7ub+3xLTIrs6w0bLUutvD4M3l1t3d1ubM77/1svqk/Zb/h/97/3X8ZPhU9EzwQ+g33irTH80axRS8DwAbejpyPGk+XUNXSE9OSFdCX0FjQWRHZUxmUGlVbFdnXGFhXGZYbFV1Un5RhVGDSYRFhUCHO4Q6ABeeO5k8lj6UQJJEkkmSTJJOlFKWVJpWnlelVqhUqlGsTq1MrUmtRaxDqkKoPqQ8ABy3V7Rbr2CqYqZkqmysc654roCuh6yOqJamm6uer5+yo7eovKG+nMGUxIrFhsWAxXrEdcFqvV+4VwAXPnI6czh1NXgzfTOAM4M1hzeKOYs9jUONR4xJikyHToJOgE59TXlMdkh0RXNDcgAVfnJ6c3d0dHhyfXKDdYl2inmMfo2DjYWMiYqLh42CjX6MeYp2iXWFc4FyADckgB+AGIIShQqKAZAClgSgB6wOuxTFG9Ai1y7jOOpD8Ez1XPps/nf/f/+H/5L+mP2k+q33uPLF68Xqu+ix5aPdndmU0orHiceEx3jHccZlwmDAWLxTuE60SK1CpT2bNpkyly+VLJIpjieKJYUlgAAfVJNQlkqZRptBm0GcQ6FIqEyuUrNXt128Zr9rwXXEesWExYfEhb+Eu4O2ha+EroCuda1vq2ioYqRdnliYVpQAFyijLqQyqDWrNq82sTayNbYyujC8Lr0oviO9ILweuhu1GrMasRquG6seqCCmI6QAEtWj26Tfp+Kr463jseK237rbvdW+0L3MvMq5yLbHsciry6jQpAAWnqiYqZarlK2SsZG2kryUvpXAl8Kbw5/EosSlw6jBqr6svK22rLGprKSpoKg='
    'BOoD3' = 'AH6bJKUlsii9LMoy0TfbP+ZK7FLuVu1W7FbhTdtK1UfKQsNBuECtQahCpESfRp1JnUqiTadRrVeyXrhoumy8db16vYPBh8aLyJLKl8uhyqjJsce4xL7Bxb3MtdWx2qjhnOiT7IrwgvF68230bfNt8nTwe+2A64fmjt+W15vQn8egv6G6oLSgs5+znbWVuIy7hb2AvXq9c7tsumi4XrJZtFS2TLZJtUKzPLA4rTOpLKEmmyCQG4UZehdtF2EYXBpPHEggPiQ2JTckPyNNJFooZS1vMnY5fj6AQoFCgEN5RHNHakpiTltWVF1NZEllQ2ZAaDxrN28zdS6AKYcnjiUAGmVSX1daW1dfUmZObEx1THlLgFCAVoBbgmCEYYRggGF4YnRkcGdra2dwZHVib19rXGlYZlIAGZlSl1eUW5JeimKRZZRomGubcJ1znniffZ6Dn4WkgqmAr4C0gLN1sGutZqhfo1meVJtSABprmGueaqRoqGWtZq5rsHWzgLSHs46ylLCarZqsl6iVpJSelJiPm4qehZ6An3qedZ5xnGyZ'
    'Nanashi' = 'AEeAAIUAiQCMBJAJlA+bHZ4mojWqOLY9w0XKS9NT2VreYeRr6HPtgPCM85n1pPat9bT0t+3F6sfnx+DJ0Mi/x6/Dp8qe0JLXi9qC3Hrec+Bq4WPhXOFR4EneO9so1B3PFckNvA22D7EQrRSmGp4kki2ILH0rdStkLF0uUjNDODg8MUEsSSFYEWQHbANxAHYAAF1xLmsvZjFhNFc4UDxLQUNIQks9UDlXN1wzZTFrL3UuhC6GN4BBd1JuW2tkZ2tlcWRpa191VYBOiUmSRZ1CqEGvQbRDuEi9TsFXx2HMa8910YPRidCUzpvLpMetw569lLiKsoKseqVznm+acJp7noaikKSbpqOmsaW9osWfzJzNms+V0YzRg9F90XTPastgxlfBUL1MtEKsPKM3ojelQ6ZMpl+lZqNyoHyegJ10mWaVWpBQikWCPHk0cy8AH4Brg2uHbIxvjnGQdJN5lHyUgJSDkomQjI2PipKHk4OUgJR8lHiTdZFyjm+LbIdrg2uAa3xseHBzc3B3bXtr'
    'Madara Eternal' = 'AE6AC4cMig6SEZ8WqRqyIbckvSrHMtsm3CXmMOo28D/3Tvxc4mvkeOWC5Zfnn+mo6LDmtOW44r3bxNbHzNDC1rPdqeGf5J79lf+O/4D/cf9q/2H9YN5Q2UXTOMsvySjHI8IdvRq2GLEXrBeoFJsTkROIFH0XchpqA1wITg8/FTYaMCMlJCY8ND40RS5LKlQkYRxiG2YXbBFzDnUNegwAIH4aehp1G3MdbyFtJGsoayxrL2szbThwO3I9dUB6Qn1CgkKFQopAjD2POpI4lDOUMJQrlCiSJI8gjB2KHIUagRoAWFovVzBSNEk7P0U4UDJbMGMvay9xMXU0fDiDPIdCiEeKS4tQkFSUVpdZnlqkW6har1i0V7hUvU/CTMVMx03JUMtZz2HRbdR41YDVhtWN05bQm8ygxqS/qLamsaWrpaeloaibqpWtkrGPtIu7ib+Hx4fPiNaK14nYhdh913XUatFhzVnHUL9Iu0W2QrJBrUCoQKJBm0KXRpNKjE2KToJPfU94T3JMbEpqSGVDYT5gOV0vAB+AZoVniWiNapJtlHGXdZh6mYCYhZeKlI6Rk46UipeFmICZeph2l3OVbpJrjmiKZ4VmgGd4aXRrb29rdGl6ZwAfN5QylS6WLJkpnCaeJKMkpySqJK0lsSi0K7guujK8Nr07vT69QrtFuUm1TLFMrU2oTKRMoEmdRplDlz6UOpQAHsWUwZS8l7ebtJ+zorKmsquyr7Syt7a6uL27wb3Evcm9zL3Ru9S417TZstut26vbp9qg15zUmdGXzpXKlA=='
    'Sasuke Eternal' = 'AECAAIsAmAGkBLEIvQ7JFdQd3CXmMOw58UL3Tvtb/mf/dP+A/4v+mPuk+K/xvezG5s/d2dTiyeq98bH3pPuY/ov/gP90/2f+W/tO90LxNuor4iPaGs8Txg69CLEEpAGYAIsAgAB0AWcEWwdQDkITORowIiYrHTYVQg5OCFsEZwF0AAARgAB+AXUPax5kLl8/YUBwRIBLkESfQKA/nC+UH4oNggKBAQAYIz4TPxJAEUEZUSJhLW82ejh8QHVHbT1lM1kqTixOOVBHVFNXVFdWTlhDV0JIQDc+ABfKPrdAqEKnQ6lMq1esV7pTxlDTTtVOzVrCZbhtwHXHfNNv3WHmU+9C7kDrP9w+AAleRFtNWFhZWV9ba1R4TWxIX0QACqFElEiHTZRUn1uhW6dZqFijSKJFAAmAUHFXZV6AaY1jml6ZXY5XgVEAGX9ufG53cHRzcXVue26AboNwh3GKdI12j3yRgJKEkYmPi42PiZGEkoCRe492jXSJcINuAAhLcUR2O4BGilCTUJJQhFB1AAm0cbB1sISvka+TuorEgLx2tXEACFZ6VYlXl2Kgb6hvp2uKYIIACap6oIGUipKakKeQqJ2gqZeqigAQOIMtkCKeGa4RvRK/EsAXwCbCOMFJv1i8WLtVrFGaRZAAEMeEu5Cumqurp7y4wMfB2sLqwO7A7r/uveev3p7TkMiEAAlXn1qtXbtfu2e4crRxrmKmV54ACaifnKePro20mLiiu6atqJ+ongAcjLqKx4bUgeCA4oDjetZ50XbIc7pyumq9YL9fwGTRbOJ08H79f/6A/oH+g/uL8JPim9GgwKC/lb0='
}
# END CLASSIC SHAPES

# Loaded on first use and cached; $null when the file is missing or unreadable.
function Get-EyeArt([string]$style) {
    if ($script:EyeArtCache.ContainsKey($style)) { return $script:EyeArtCache[$style] }
    $art = $null
    $file = $global:EyeFiles[$style]
    if ($file) {
        $path = Join-Path $global:EyesDir $file
        try {
            if (Test-Path $path) {
                if ($path -like '*.png') { $art = Import-RasterEye $path } else { $art = Import-SvgEye $path }
            }
        }
        catch { $art = $null }
    }
    $script:EyeArtCache[$style] = $art
    return $art
}

# A Classic eye: its traced outlines as one black path, drawn over the flat iris.
function Get-ClassicArt([string]$name) {
    $key = "Classic:$name"
    if ($script:EyeArtCache.ContainsKey($key)) { return $script:EyeArtCache[$key] }
    $art = $null
    $data = $global:ClassicShapes[$name]
    if ($data) {
        $b = [Convert]::FromBase64String($data)
        $gp = New-Object System.Drawing.Drawing2D.GraphicsPath([System.Drawing.Drawing2D.FillMode]::Alternate)
        $i = 0
        while ($i -lt $b.Length) {
            $n = $b[$i] * 256 + $b[$i + 1]; $i += 2
            $pts = New-Object 'System.Drawing.PointF[]' $n
            for ($j = 0; $j -lt $n; $j++) {
                $pts[$j] = New-Object System.Drawing.PointF((10.0 + $b[$i] * 280.0 / 255.0), (10.0 + $b[$i + 1] * 280.0 / 255.0))
                $i += 2
            }
            $gp.AddPolygon($pts)
        }
        $art = @{ Flat = $true; Pattern = @(@{ Path = $gp; Fill = [System.Drawing.Color]::Black }) }
    }
    $script:EyeArtCache[$key] = $art
    return $art
}

# Tomoe tail, traced from the reference artwork (a Sharingan with three tomoe).
# Angle (radians) around the head centre, measured from the outward direction
# (eye centre -> head), and the tail's inner/outer edge in head radii. The head
# itself is a circle. Traced shape matches the reference at 96.5% pixel overlap.
$global:TomoeA = [double[]]@(-1.3875, -1.3352, -1.2828, -1.2305, -1.1781, -1.1257, -1.0734, -1.0210, -0.9687, -0.9163, -0.8639, -0.8116, -0.7592, -0.7069, -0.6545, -0.6021, -0.5498, -0.4974, -0.4451, -0.3927, -0.3403, -0.2880, -0.2356, -0.1833, -0.1309, -0.0785, -0.0262, 0.0262, 0.0785, 0.1309, 0.1833, 0.2356, 0.2880, 0.3403, 0.3927, 0.4451, 0.4974, 0.5498, 0.6021, 0.6545, 0.7069, 0.7592, 0.8116, 0.8639, 0.9163, 0.9687, 1.0210, 1.0734, 1.1257)
$global:TomoeI = [double[]]@(1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.000, 1.066, 1.147, 1.241, 1.334, 1.416, 1.493, 1.575, 1.661, 1.747, 1.838, 1.927, 2.055)
$global:TomoeO = [double[]]@(1.038, 1.048, 1.053, 1.055, 1.064, 1.079, 1.092, 1.104, 1.117, 1.130, 1.145, 1.160, 1.174, 1.189, 1.204, 1.219, 1.242, 1.272, 1.299, 1.319, 1.340, 1.370, 1.403, 1.429, 1.452, 1.474, 1.498, 1.529, 1.562, 1.586, 1.604, 1.623, 1.649, 1.679, 1.709, 1.736, 1.758, 1.778, 1.802, 1.828, 1.849, 1.867, 1.892, 1.927, 1.960, 1.986, 2.013, 2.052, 2.055)

# Heartbeat envelope for the glow, 0..1. Hard attack, quick decay: "lub" then a
# softer "dub". The heart rate follows the load (55 bpm idle, 120 bpm flat out)
# times the Pulse speed setting.
# The phase advances by real time, so a tempo change never makes it jump.
$script:PulseClock = [System.Diagnostics.Stopwatch]::StartNew()
$script:PulseLast = 0.0
$script:PulsePhase = 0.0
function Get-HeartBeat {
    if (-not $global:glowPulse) { return 0.65 }          # pulse off: a steady glow
    $now = $script:PulseClock.Elapsed.TotalSeconds
    $dt = [Math]::Min(0.25, $now - $script:PulseLast)
    $script:PulseLast = $now
    $load = [Math]::Max(0.0, [Math]::Min(100.0, [double]$global:currentLoadPercent))
    $bpm = (55.0 + 0.65 * $load) * (Get-PulseMult $global:pulseLevel)
    $script:PulsePhase = ($script:PulsePhase + $dt * $bpm / 60.0) % 1.0
    $p = $script:PulsePhase
    $lub = [Math]::Exp(-$p / 0.11)
    $dub = 0.0
    if ($p -ge 0.27) { $dub = 0.6 * [Math]::Exp(-($p - 0.27) / 0.11) }
    return [Math]::Min(1.0, [Math]::Max($lub, $dub))
}

# 5. Sharingan Drawing Routine (128x128 High Resolution)
# E: Current morph stage (0.0 to 4.0)
# Angle: Rotation angle in radians
function Get-SharinganIcon($E, $Angle, $Style) {
    # Keys are "Set:Name". V1 eyes are drawn from their artwork in .\eyes\; Classic
    # eyes from the outlines traced from it (flat iris). A V1 eye whose file is
    # missing or broken falls back to its Classic version.
    $set = "V1"
    if ($Style -match '^(Classic|V1):(.+)$') { $set = $Matches[1]; $Style = $Matches[2] }
    $art = $null
    if ($set -eq "V1") { $art = Get-EyeArt $Style }
    if ($null -eq $art -and $global:ArtFallback.ContainsKey($Style)) { $Style = $global:ArtFallback[$Style] }
    if ($null -eq $art) { $art = Get-ClassicArt $Style }

    # Merge phase (E 3 -> 4): the three tomoe keep their orbit, swirl in the
    # rotation direction and stretch their tails into long arms; those arms
    # become the blades as the Mangekyou fades in underneath and the tomoe heads
    # dissolve into it.
    #   $conv  how far the tomoe have swirled / stretched    (0..1, eased)
    #   $fade  1 -> 0 as the tomoe dissolve into the pattern (late in the merge)
    #   $bloom how far the pattern has formed                (0..1, eased)
    $mu = [Math]::Max(0.0, [Math]::Min(1.0, $E - 3.0))
    $conv = $mu * $mu * (3.0 - 2.0 * $mu)
    $fu = [Math]::Max(0.0, [Math]::Min(1.0, ($mu - 0.65) / 0.35))
    $fade = 1.0 - ($fu * $fu * (3.0 - 2.0 * $fu))
    $bu = [Math]::Max(0.0, [Math]::Min(1.0, ($mu - 0.15) / 0.85))
    $bloom = $bu * $bu * (3.0 - 2.0 * $bu)
    $spinDir = 1.0
    if ($global:rotationDir -lt 0) { $spinDir = -1.0 }

    # 128x128 pixel double-resolution canvas
    $bmp = New-Object System.Drawing.Bitmap(128, 128)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    
    # Configure ultra-high-quality GDI+ options
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    $redBrush = New-Object System.Drawing.SolidBrush($global:eyeColor)
    $blackBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::Black)
    $borderPen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 4.5)

    # A0. Glow: a heartbeat. Each beat ("lub", then a softer "dub") hits hard and
    # decays: the eye colour flashes saturated and bright and a halo pushes out
    # from the rim. Between beats the eye is its normal self. Size never changes.
    $eyeDraw = $global:eyeColor
    if ($global:glowOn) {
        $beat = Get-HeartBeat
        if ($beat -gt 0.004) {
            $peak = [Math]::Max($eyeDraw.R, [Math]::Max($eyeDraw.G, $eyeDraw.B))
            if ($peak -lt 1) { $peak = 1 }
            $k = 255.0 / $peak
            $hr = [Math]::Min(255.0, ($eyeDraw.R * $k) + ((255 - ($eyeDraw.R * $k)) * 0.18))
            $hg = [Math]::Min(255.0, ($eyeDraw.G * $k) + ((255 - ($eyeDraw.G * $k)) * 0.18))
            $hb = [Math]::Min(255.0, ($eyeDraw.B * $k) + ((255 - ($eyeDraw.B * $k)) * 0.18))
            $eyeDraw = [System.Drawing.Color]::FromArgb(
                [int]($global:eyeColor.R + ($hr - $global:eyeColor.R) * $beat),
                [int]($global:eyeColor.G + ($hg - $global:eyeColor.G) * $beat),
                [int]($global:eyeColor.B + ($hb - $global:eyeColor.B) * $beat))
            $redBrush.Dispose()
            $redBrush = New-Object System.Drawing.SolidBrush($eyeDraw)

            # halo in the canvas margin, outside the eye (the eye keeps its size)
            $haloBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb([int](70 * $beat), [int]$hr, [int]$hg, [int]$hb))
            for ($gi = 0; $gi -lt 4; $gi++) {
                $gr = 64.0 - ($gi * 1.2)
                $g.FillEllipse($haloBrush, [float](64.0 - $gr), [float](64.0 - $gr), [float]($gr * 2), [float]($gr * 2))
            }
            $haloBrush.Dispose()
        }
    }

    # A. Draw Sclera (Base Eye Background)
    if ($art -and -not $art.Flat) {
        $artState = $g.Save()
        $g.TranslateTransform(64.0, 64.0)
        $g.ScaleTransform(0.401, 0.401)              # 300-unit artwork -> 128px canvas
        $g.TranslateTransform(-150.0, -150.0)
        Write-StdIris $g $eyeDraw
        $g.Restore($artState)
    }
    else {
        $g.FillEllipse($redBrush, 6, 6, 116, 116)
        $g.DrawEllipse($borderPen, 6, 6, 116, 116)
    }

    # B. Draw Inner Ring (Fades in for tomoes, fades out for Mangekyou)
    $ringAlpha = 0
    if ($E -lt 1.0) {
        $ringAlpha = [int]($E * 255)
    }
    elseif ($E -ge 1.0 -and $E -lt 3.0) {
        $ringAlpha = 255
    }
    elseif ($E -ge 3.0 -and $E -le 4.0) {
        $ringAlpha = [int]((4.0 - $E) * 255)
    }
    
    if ($ringAlpha -gt 0) {
        $ringColor = [System.Drawing.Color]::FromArgb($ringAlpha, 0, 0, 0)
        $ringPen = New-Object System.Drawing.Pen($ringColor, 3.2)
        $g.DrawEllipse($ringPen, 29, 29, 70, 70)
        $ringPen.Dispose()
    }

    # C. Draw Center Pupil. The design supplies its own centre, so the base pupil
    # hands over to it as the pattern forms.
    $pupilRadius = 14.0 * (1.0 - $bloom)
    $g.FillEllipse($blackBrush, [float](64.0 - $pupilRadius), [float](64.0 - $pupilRadius), [float]($pupilRadius * 2), [float]($pupilRadius * 2))

    # D. Mangekyou pattern
    if ($art -and $bloom -gt 0.0) {
        $artState = $g.Save()
        $g.TranslateTransform(64.0, 64.0)
        # starts 120 degrees behind and catches up in the spin direction as it forms
        $unwind = -$spinDir * (1.0 - $bloom) * 120.0
        $g.RotateTransform([float]($Angle * 180.0 / [Math]::PI + $unwind))
        $s = 0.401 * (0.55 + 0.45 * $bloom)
        $g.ScaleTransform([float]$s, [float]$s)
        $g.TranslateTransform(-150.0, -150.0)
        Write-ArtPattern $g $art $eyeDraw $bloom
        $g.Restore($artState)
    }

    # E. Draw Standard Tomoes (Stages 1, 2, 3)
    $t1_angle = 0.0
    $t1_scale = 0.0
    if ($E -le 1.0) {
        $t1_scale = $E
    }
    elseif ($E -gt 1.0 -and $E -lt 3.0) {
        $t1_scale = 1.0
    }
    else {
        $t1_scale = $fade
    }

    $t2_angle = [Math]::PI
    $t2_scale = 0.0
    if ($E -gt 1.0 -and $E -le 2.0) {
        $t2_scale = $E - 1.0
    }
    elseif ($E -gt 2.0 -and $E -lt 3.0) {
        $t2_scale = 1.0
        $interp = $E - 2.0
        $t2_angle = [Math]::PI - $interp * ([Math]::PI - (2 * [Math]::PI / 3))
    }
    elseif ($E -ge 3.0) {
        $t2_scale = $fade
        $t2_angle = 2 * [Math]::PI / 3
    }

    $t3_angle = 4 * [Math]::PI / 3
    $t3_scale = 0.0
    if ($E -gt 2.0 -and $E -le 3.0) {
        $t3_scale = $E - 2.0
    }
    elseif ($E -gt 3.0) {
        $t3_scale = $fade
    }

    $tomoes = @(
        @{ Angle = $t1_angle; Scale = $t1_scale },
        @{ Angle = $t2_angle; Scale = $t2_scale },
        @{ Angle = $t3_angle; Scale = $t3_scale }
    )

    foreach ($tomoe in $tomoes) {
        $scale = $tomoe.Scale
        if ($scale -le 0.01) { continue }

        # during the merge they swirl a half turn in the spin direction
        $tomoeAngle = $Angle + $tomoe.Angle + ($spinDir * $conv * [Math]::PI)
        $tomoeRadius = 35.0 * (1.0 + 0.08 * $conv)           # orbit holds, arms reach outward
        $headRadius = 9.14 * $scale * (1.0 + 0.9 * $conv)    # heads fatten into blade tips

        $hx = 64.0 + $tomoeRadius * [Math]::Cos($tomoeAngle)
        $hy = 64.0 + $tomoeRadius * [Math]::Sin($tomoeAngle)
        $g.FillEllipse($blackBrush, [float]($hx - $headRadius), [float]($hy - $headRadius), [float]($headRadius * 2), [float]($headRadius * 2))

        # the comma's tail, traced from the reference tomoe
        $tailPts = [SharinganTomoe]::Tail($global:TomoeA, $global:TomoeI, $global:TomoeO, $hx, $hy, $tomoeAngle, $headRadius)
        $g.FillPolygon($blackBrush, $tailPts)

        # merge: an arm grows out of each tomoe along the orbit and becomes a blade
        if ($conv -gt 0.0) {
            $tailLength = 0.75 + 1.9 * $conv
            $tailSteps = 30
            for ($j = 0; $j -le $tailSteps; $j++) {
                $tTail = $j / $tailSteps
                $phi = $tomoeAngle + ($tTail * $tailLength * $scale)
                $tw = $headRadius * [Math]::Pow(1.0 - $tTail, 1.5) * $conv
                if ($tw -le 0.1) { continue }
                $tx = 64.0 + $tomoeRadius * [Math]::Cos($phi)
                $ty = 64.0 + $tomoeRadius * [Math]::Sin($phi)
                $g.FillEllipse($blackBrush, [float]($tx - $tw), [float]($ty - $tw), [float]($tw * 2), [float]($tw * 2))
            }
        }
    }

    # F. Cover cleanup
    $redBrush.Dispose()
    $blackBrush.Dispose()
    $borderPen.Dispose()
    $g.Dispose()

    # Invert: black becomes the eye colour and the eye colour becomes black.
    # Every pixel is a blend of the two, so new = eyeColour - old, per channel.
    if ($global:invertOn) {
        $cm = New-Object System.Drawing.Imaging.ColorMatrix
        $cm.Matrix00 = -1.0; $cm.Matrix11 = -1.0; $cm.Matrix22 = -1.0; $cm.Matrix33 = 1.0; $cm.Matrix44 = 1.0
        $cm.Matrix40 = $eyeDraw.R / 255.0; $cm.Matrix41 = $eyeDraw.G / 255.0; $cm.Matrix42 = $eyeDraw.B / 255.0
        $ia = New-Object System.Drawing.Imaging.ImageAttributes
        $ia.SetColorMatrix($cm)
        $inv = New-Object System.Drawing.Bitmap(128, 128)
        $ig = [System.Drawing.Graphics]::FromImage($inv)
        $ig.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
        $ig.DrawImage($bmp, (New-Object System.Drawing.Rectangle(0, 0, 128, 128)), 0, 0, 128, 128, [System.Drawing.GraphicsUnit]::Pixel, $ia)
        $ig.Dispose(); $ia.Dispose(); $bmp.Dispose()
        $bmp = $inv
    }

    # Convert Bitmap to Handle
    $hIcon = $bmp.GetHicon()
    $icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $bmp.Dispose()
    
    return [PSCustomObject]@{
        Icon   = $icon
        Handle = $hIcon
    }
}

# 6. Primary Application Animation Loop
# Driven by a WinForms Timer under a real Application::Run message pump rather
# than a while-loop calling DoEvents(). The old shape blocked the UI thread in
# Start-Sleep for most of every tick, so any window opened from the tray menu
# got almost no pump time and could never reliably activate or paint.
$script:metricsTimer = 0
$metricsInterval = 1000 # Query metrics every 1s
$tickInterval = 35      # 35ms frame render rate (~28 FPS)
$script:shuffleTimer = 0

# Let the uninstall batch file find and stop this instance.
try { $PID | Set-Content -Path (Join-Path $PSScriptRoot "sharingan.pid") -Encoding ASCII } catch {}

$RenderFrame = {
    # Update metrics at regular intervals
    $script:metricsTimer += $tickInterval
    if ($script:metricsTimer -ge $metricsInterval) {
        $script:metricsTimer = 0
        if ($global:monitoringModeIsRAM) {
            $global:currentLoadPercent = [Win32]::GetRAMLoad()
        }
        else {
            $global:currentLoadPercent = [Win32]::GetCPULoad()
        }
    }

    # Shuffle: swap to a random eye every N seconds while enabled
    if ($global:shuffleOn) {
        $script:shuffleTimer += $tickInterval
        if ($script:shuffleTimer -ge ($global:shuffleSeconds * 1000)) {
            $script:shuffleTimer = 0
            Set-EyeStyle (Get-ShufflePick)
        }
    }
    else {
        $script:shuffleTimer = 0
    }

    # Map current load percent to target evolution stage using the user thresholds
    $targetStage = 0.0
    for ($s = 0; $s -lt 4; $s++) {
        if ($global:currentLoadPercent -ge $global:thresholds[$s]) { $targetStage = $s + 1.0 }
    }

    # Interpolate current stage towards target stage smoothly
    $stageDiff = $targetStage - $global:currentStage
    if ([Math]::Abs($stageDiff) -gt 0.01) {
        $global:currentStage += $stageDiff * 0.12
    }
    else {
        $global:currentStage = $targetStage
    }

    # Calculate rotation speed (spins faster under high load), scaled by the user multiplier
    $speedFactor = 0.01
    if ($global:currentLoadPercent -ge $global:thresholds[0]) {
        $speedFactor = 0.02 + ($global:currentLoadPercent / 100.0) * 0.26
    }
    $speedFactor *= $global:speedMult * $global:rotationDir

    $global:rotationAngle += $speedFactor
    if ($global:rotationAngle -ge (2 * [Math]::PI)) {
        $global:rotationAngle -= (2 * [Math]::PI)
    }
    elseif ($global:rotationAngle -lt 0) {
        $global:rotationAngle += (2 * [Math]::PI)
    }

    # Create next icon frame
    $iconObj = Get-SharinganIcon $global:currentStage $global:rotationAngle $global:selectedEyeStyle
    $oldIcon = $NotifyIcon.Icon

    # Update system tray
    $modeText = if ($global:monitoringModeIsRAM) { "RAM" } else { "CPU" }
    $NotifyIcon.Icon = $iconObj.Icon
    $eyeParts = $global:selectedEyeStyle -split ':', 2
    $NotifyIcon.Text = "$($eyeParts[1]) - $modeText $([Math]::Round($global:currentLoadPercent))%"

    # Destroy the old icon objects to prevent GDI / system memory leaks
    if ($oldIcon -ne $null) {
        $oldIcon.Dispose()
    }
    [Win32]::DestroyIcon($iconObj.Handle) | Out-Null
}

$AnimTimer = New-Object System.Windows.Forms.Timer
$AnimTimer.Interval = $tickInterval
$AnimTimer.add_Tick($RenderFrame)
$AnimTimer.Start()

[System.Windows.Forms.Application]::Run()

# 7. Exit Cleanup
$AnimTimer.Stop()
$AnimTimer.Dispose()
Save-Settings
try { [IO.File]::Delete((Join-Path $PSScriptRoot "sharingan.pid")) } catch {}
$NotifyIcon.Visible = $false
if ($NotifyIcon.Icon -ne $null) { $NotifyIcon.Icon.Dispose() }
$NotifyIcon.Dispose()

Write-Output "Sharingan Monitor terminated cleanly."
