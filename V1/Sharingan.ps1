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

# 2. Global State Variables
$global:running = $true
$global:monitoringModeIsRAM = $false       # False = CPU, True = RAM
$global:currentLoadPercent = [Win32]::GetCPULoad()
$global:selectedEyeStyle = "Itachi"        # Default set to Itachi

$global:currentStage = 0.0                 # From 0.0 to 4.0
$global:rotationAngle = 0.0

# All selectable Sharingan styles, in menu order. Also the pool the shuffle draws from.
$global:SharinganStyles = @(
    "Itachi", "Kakashi/Obito", "Madara", "Madara Eye 2", "Izuna", "Sasuke", "Sasuke Eternal",
    "Shisui", "Indra", "Shin", "Sarada", "Naka", "Baru", "Rai", "Naori", "Fugaku",
    "Nanashi", "BOoD"
)

# Names used in settings files / profiles saved before the eye set was reworked.
$global:StyleAliases = @{
    "Obito" = "Kakashi/Obito"; "Kakashi" = "Kakashi/Obito"; "Sasuke Eye 2" = "Sasuke Eternal"
}

# BOoD exists only as artwork. Without the eyes\ folder it would be a copy of
# another eye, so it is left out of the list instead.
foreach ($artOnly in @("BOoD")) {
    if (-not (Test-Path (Join-Path $PSScriptRoot "eyes\$artOnly.png"))) {
        $global:SharinganStyles = @($global:SharinganStyles | Where-Object { $_ -ne $artOnly })
    }
}

# Factory defaults. Reset restores exactly these.
$global:Defaults = @{
    Thresholds     = @(15.0, 35.0, 55.0, 75.0)   # load % that unlocks tomoe 1, 2, 3, Mangekyou
    ColorR         = 195      # #c30000, the mid stop of the eyes' red gradient
    ColorG         = 0
    ColorB         = 0
    Glow           = $false
    SpeedLevel     = 50       # 1..100 slider; 50 = 1.0x (the original speed)
    Direction      = 1        # 1 clockwise, -1 counter-clockwise
    Invert         = $false   # swap tomoe/pattern colour with the eye colour
    Shuffle        = $false
    ShuffleSeconds = 10
    Style          = "Itachi"
}

# Live settings (populated by Reset-Defaults, then overwritten by the saved file if present)
$global:thresholds = @(15.0, 35.0, 55.0, 75.0)
$global:eyeColor = [System.Drawing.Color]::FromArgb(195, 0, 0)
$global:glowOn = $false
$global:speedLevel = 50
$global:speedMult = 1.0
$global:rotationDir = 1
$global:invertOn = $false
$global:shuffleOn = $false
$global:shuffleSeconds = 10

$global:SettingsPath = Join-Path $PSScriptRoot "settings.json"

# Slider 1..100 -> rotation multiplier. Exponential so each notch feels the same:
# 1 = 0.17x, 50 = 1.00x (original speed), 100 = 6.00x.
function Get-SpeedMult([int]$level) { return [Math]::Pow(6.0, ($level - 50) / 50.0) }

function Set-SpeedLevel([int]$level) {
    $global:speedLevel = [Math]::Max(1, [Math]::Min(100, $level))
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
        # the old built-in default red now maps to the new default (the SVG red)
        if ($global:eyeColor.R -eq 220 -and $global:eyeColor.G -eq 10 -and $global:eyeColor.B -eq 15) {
            $global:eyeColor = [System.Drawing.Color]::FromArgb(195, 0, 0)
        }
    }
    if (& $has 'Glow') { $global:glowOn = [bool]$s.Glow }
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
        $st = [string]$s.Style
        if ($global:StyleAliases.ContainsKey($st)) { $st = $global:StyleAliases[$st] }
        if ($global:SharinganStyles -contains $st) { $global:selectedEyeStyle = $st }
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
foreach ($styleName in $global:SharinganStyles) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem($styleName)
    $item.Tag = $styleName
    $item.add_Click({ Set-EyeStyle $this.Tag })
    $global:StyleMenuItems[$styleName] = $item
    $StyleItem.DropDownItems.Add($item) | Out-Null
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
    foreach ($mi in $global:StyleMenuItems.Values) { $mi.Checked = $false }
    if ($global:StyleMenuItems.ContainsKey($styleName)) {
        $global:StyleMenuItems[$styleName].Checked = $true
        $global:selectedEyeStyle = $styleName
    }
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
    $global:InvertItem.Checked = $global:invertOn
    $global:ShuffleToggle.Checked = $global:shuffleOn
    if ($global:SpeedTrack -and $global:SpeedTrack.Value -ne $global:speedLevel) {
        $global:SyncingSpeed = $true
        $global:SpeedTrack.Value = $global:speedLevel
        $global:SyncingSpeed = $false
    }
    if ($global:SpeedLabel) { $global:SpeedLabel.Text = ("Speed {0}   ({1:N2}x)" -f $global:speedLevel, $global:speedMult) }
    $global:ColorSwatchItem.Text = "Current: $(Get-ColorName $global:eyeColor)"
}

$global:ColorPresets = @(
    @{ Text = "Sharingan Red"; Value = @(195, 0, 0) }
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
# A real slider (1..100) hosted inside the menu. The label shows the level and
# the resulting multiplier; the value is saved when the mouse/key is released.
$SpeedItem = New-Object System.Windows.Forms.ToolStripMenuItem("Speed")
$CustomItem.DropDownItems.Add($SpeedItem) | Out-Null

$speedPanel = New-Object System.Windows.Forms.Panel
$speedPanel.Size = New-Object System.Drawing.Size(250, 62)
$global:SpeedLabel = New-Object System.Windows.Forms.Label
$global:SpeedLabel.SetBounds(10, 6, 230, 18)
$global:SpeedLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$global:SpeedTrack = New-Object System.Windows.Forms.TrackBar
$global:SpeedTrack.SetBounds(4, 26, 242, 32)
$global:SpeedTrack.Minimum = 1
$global:SpeedTrack.Maximum = 100
$global:SpeedTrack.TickFrequency = 10
$global:SpeedTrack.LargeChange = 10
$global:SpeedTrack.SmallChange = 1
$global:SpeedTrack.Value = $global:speedLevel
$global:SyncingSpeed = $false
$global:SpeedTrack.add_ValueChanged({
        if ($global:SyncingSpeed) { return }
        Set-SpeedLevel $global:SpeedTrack.Value
        $global:SpeedLabel.Text = ("Speed {0}   ({1:N2}x)" -f $global:speedLevel, $global:speedMult)
    })
$global:SpeedTrack.add_MouseUp({ Save-Settings })
$global:SpeedTrack.add_KeyUp({ Save-Settings })
$speedPanel.Controls.Add($global:SpeedLabel)
$speedPanel.Controls.Add($global:SpeedTrack)
$speedHost = New-Object System.Windows.Forms.ToolStripControlHost($speedPanel)
$speedHost.AutoSize = $false
$speedHost.Size = $speedPanel.Size
$SpeedItem.DropDownItems.Add($speedHost) | Out-Null

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
# A single on/off, so it is the menu item itself rather than a submenu holding
# one toggle - one click instead of two.
$global:GlowItem = New-Object System.Windows.Forms.ToolStripMenuItem("Glow")
$global:GlowItem.add_Click({
        $global:glowOn = -not $global:glowOn
        Save-Settings
        Sync-CustomMenu
    })
$CustomItem.DropDownItems.Add($global:GlowItem) | Out-Null

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
$ProfilesItem.add_DropDownOpening({ Build-ProfilesMenu })
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

Sync-CustomMenu

# Warm up CPU counter
Start-Sleep -Milliseconds 200
[Win32]::GetCPULoad() | Out-Null

# 4. Drawing Helper
# Draws a path of overlapping circles to form smooth, anti-aliased curves
function Fill-CurvedBlade($g, $brush, $baseAngle, $startRadius, $length, $scale, $curveFactor, $maxWidth) {
    if ($scale -le 0.01) { return }
    $steps = 30
    for ($k = 0; $k -le $steps; $k++) {
        $t = $k / $steps
        $r = $startRadius + ($t * $length * $scale)
        $currAngle = $baseAngle + ($curveFactor * [Math]::Pow($t, 1.3))
        $w = ($maxWidth * (1.0 - $t) * $scale) + 0.5
        $bx = 64.0 + $r * [Math]::Cos($currAngle)
        $by = 64.0 + $r * [Math]::Sin($currAngle)
        $g.FillEllipse($brush, [float]($bx - $w), [float]($by - $w), [float]($w * 2), [float]($w * 2))
    }
}

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

# 4c. Eye artwork: .\eyes\ holds the original SVG/PNG for each eye.
$global:EyesDir = Join-Path $PSScriptRoot "eyes"
$global:EyeFiles = @{
    "Itachi" = "Itachi.svg"; "Kakashi/Obito" = "Kakashi-Obito.svg"; "Madara" = "Madara.svg"
    "Madara Eye 2" = "Madara-Eternal.svg"; "Izuna" = "Izuna.svg"; "Sasuke" = "Sasuke.svg"
    "Sasuke Eternal" = "Sasuke-Eternal.png"; "Shisui" = "Shisui.svg"; "Indra" = "Indra.svg"
    "Shin" = "Shin.svg"; "Sarada" = "Sarada.svg"; "Naka" = "Naka.svg"; "Baru" = "Baru.svg"
    "Rai" = "Rai.svg"; "Naori" = "Naori.svg"; "Fugaku" = "Fugaku.svg"; "Nanashi" = "Nanashi.svg"
    "BOoD" = "BOoD.png"
}
# Without the eyes\ folder these fall back to the built-in drawings below.
$global:ArtFallback = @{ "Kakashi/Obito" = "Kakashi"; "Sasuke Eternal" = "Sasuke Eye 2"; "BOoD" = "Itachi" }
$script:EyeArtCache = @{}

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

# 5. Sharingan Drawing Routine (128x128 High Resolution)
# E: Current morph stage (0.0 to 4.0)
# Angle: Rotation angle in radians
function Get-SharinganIcon($E, $Angle, $Style) {
    # Eyes with artwork in .\eyes\ are drawn from it; without it, fall back to the
    # older built-in drawing for that eye.
    $art = Get-EyeArt $Style
    if ($null -eq $art -and $global:ArtFallback.ContainsKey($Style)) { $Style = $global:ArtFallback[$Style] }

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

    # A0. Optional glow: purely a colour change - the eye keeps exactly the same
    # size and geometry either way. Push the colour to full saturation, then lift
    # it toward white so it reads as lit-from-within rather than just lighter.
    $eyeDraw = $global:eyeColor
    if ($global:glowOn) {
        $peak = [Math]::Max($eyeDraw.R, [Math]::Max($eyeDraw.G, $eyeDraw.B))
        if ($peak -lt 1) { $peak = 1 }
        $k = 255.0 / $peak
        $lift = 0.28
        $eyeDraw = [System.Drawing.Color]::FromArgb(
            [int][Math]::Min(255, ($eyeDraw.R * $k) + ((255 - ($eyeDraw.R * $k)) * $lift)),
            [int][Math]::Min(255, ($eyeDraw.G * $k) + ((255 - ($eyeDraw.G * $k)) * $lift)),
            [int][Math]::Min(255, ($eyeDraw.B * $k) + ((255 - ($eyeDraw.B * $k)) * $lift)))
        $redBrush.Dispose()
        $redBrush = New-Object System.Drawing.SolidBrush($eyeDraw)

        # Faint bloom into the 6px canvas margin. Costs no eye size because the
        # sclera below still draws at its normal 6,6,116,116.
        $bloom = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(30, $eyeDraw.R, $eyeDraw.G, $eyeDraw.B))
        for ($gi = 0; $gi -lt 4; $gi++) {
            $gr = 64.0 - ($gi * 1.2)
            $g.FillEllipse($bloom, [float](64.0 - $gr), [float](64.0 - $gr), [float]($gr * 2), [float]($gr * 2))
        }
        $bloom.Dispose()
    }

    # A. Draw Sclera (Base Eye Background)
    if ($art) {
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
    
    if ($Style -eq "Madara" -and $E -ge 3.0) {
        $ringAlpha = 255
    }

    if ($ringAlpha -gt 0) {
        $ringColor = [System.Drawing.Color]::FromArgb($ringAlpha, 0, 0, 0)
        $ringPen = New-Object System.Drawing.Pen($ringColor, 3.2)
        $g.DrawEllipse($ringPen, 29, 29, 70, 70)
        $ringPen.Dispose()
    }

    # C. Draw Center Pupil
    $pupilRadius = 14.0
    
    if ($E -ge 3.0) {
        $mScale = $E - 3.0
        if ($Style -eq "Sasuke") {
            $pupilRadius = 14.0 - (7.0 * $mScale)
        }
        elseif ($Style -eq "Sasuke Eye 2") {
            $pupilRadius = 14.0 - (5.5 * $mScale)
        }
        elseif ($Style -eq "Madara") {
            $pupilRadius = 14.0 + (3.0 * $mScale)
        }
        elseif ($Style -eq "Madara Eye 2") {
            $pupilRadius = 14.0 + (2.2 * $mScale)
        }
        elseif ($Style -eq "Obito") {
            $pupilRadius = 13.0 + (2.0 * $mScale)
        }
        elseif ($Style -eq "Nanashi") {
            $pupilRadius = 12.0 + (1.0 * $mScale)
        }
        elseif ($Style -eq "Itachi") {
            $pupilRadius = 13.0 + (1.0 * $mScale)
        }
    }
    # With artwork the design supplies its own centre, so the base pupil hands over to it.
    if ($art) { $pupilRadius = 14.0 * (1.0 - $bloom) }
    $g.FillEllipse($blackBrush, [float](64.0 - $pupilRadius), [float](64.0 - $pupilRadius), [float]($pupilRadius * 2), [float]($pupilRadius * 2))

    # D. Draw Style-specific Evolution Effects (Stage >= 3.0)
    $mScale = 0.0
    if ($E -ge 3.0) {
        $mScale = $E - 3.0
    }
    
    if ($art) {
        if ($bloom -gt 0.0) {
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
    }
    elseif ($mScale -gt 0.0) {
        if ($Style -eq "Itachi") {
            for ($i = 0; $i -lt 3; $i++) {
                $baseAngle = $Angle + ($i * 2 * [Math]::PI / 3)
                Fill-CurvedBlade $g $blackBrush $baseAngle 13.0 40.0 $mScale 1.4 12.0
            }
        }
        elseif ($Style -eq "Obito") {
            for ($i = 0; $i -lt 4; $i++) {
                $baseAngle = $Angle + ($i * [Math]::PI / 2)
                Fill-CurvedBlade $g $blackBrush $baseAngle 12.0 36.0 $mScale 1.6 10.0
            }
        }
        elseif ($Style -eq "Madara") {
            $originalState = $g.Save()
            $g.TranslateTransform(64.0, 64.0)
            $rotDeg = ($Angle * 180.0 / [Math]::PI)
            $g.RotateTransform($rotDeg)
            $outerR = 35.0
            $wedgeWidth = 34.0
            for ($i = 0; $i -lt 3; $i++) {
                $startDeg = ($i * 120.0) - ($wedgeWidth / 2.0)
                $scaledR = $outerR * $mScale
                if ($scaledR -gt 2) {
                    $g.FillPie($blackBrush, [float](-$scaledR), [float](-$scaledR), [float]($scaledR * 2), [float]($scaledR * 2), [float]$startDeg, [float]$wedgeWidth)
                }
            }
            $g.Restore($originalState)
            # No centre dot here: section C already enlarges Madara's pupil to
            # 14 + 3*mScale, which completely covers a 3.5-radius dot.
        }
        elseif ($Style -eq "Izuna") {
            for ($i = 0; $i -lt 3; $i++) {
                $baseAngle = $Angle + ($i * 2 * [Math]::PI / 3)
                Fill-CurvedBlade $g $blackBrush $baseAngle 14.0 30.0 $mScale 1.0 9.0
            }
        }
        elseif ($Style -eq "Sasuke") {
            # Six-pointed star: three long ellipses at 60-degree spacing, each with
            # an eye-coloured cutout so only the outline reads as black.
            $originalState = $g.Save()
            $g.TranslateTransform(64.0, 64.0)

            $semiMajor = 50.0 * $mScale
            $semiMinor = 13.0 * $mScale

            for ($i = 0; $i -lt 3; $i++) {
                $rotState = $g.Save()
                $deg = ($Angle * 180.0 / [Math]::PI) + ($i * 60.0)
                $g.RotateTransform($deg)

                # Outer black ellipse
                $g.FillEllipse($blackBrush, [float](-$semiMinor), [float](-$semiMajor), [float]($semiMinor * 2), [float]($semiMajor * 2))

                # Inner cutout, fading in with the morph so it never pops
                $starCutColor = [System.Drawing.Color]::FromArgb([int]($mScale * 255), $eyeDraw.R, $eyeDraw.G, $eyeDraw.B)
                $starCutBrush = New-Object System.Drawing.SolidBrush($starCutColor)
                $innerMajor = $semiMajor - 4.5
                $innerMinor = $semiMinor - 3.5
                if ($innerMinor -gt 0) {
                    $g.FillEllipse($starCutBrush, [float](-$innerMinor), [float](-$innerMajor), [float]($innerMinor * 2), [float]($innerMajor * 2))
                }
                $starCutBrush.Dispose()

                $g.Restore($rotState)
            }
            $g.Restore($originalState)

            # Center black pupil
            $centerRad = 9.0 * $mScale
            $g.FillEllipse($blackBrush, [float](64.0 - $centerRad), [float](64.0 - $centerRad), [float]($centerRad * 2), [float]($centerRad * 2))
        }
        elseif ($Style -eq "Kakashi") {
            # Three broad pinwheel blades. Wider and less coiled than Itachi's so
            # the two read differently at 16px.
            for ($i = 0; $i -lt 3; $i++) {
                $baseAngle = $Angle + ($i * 2 * [Math]::PI / 3)
                Fill-CurvedBlade $g $blackBrush $baseAngle 9.0 38.0 $mScale 1.15 13.0
            }
            $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int]($mScale * 210), 0, 0, 0), 2.2)
            $ringR = 30.0 * $mScale
            if ($ringR -gt 1.0) {
                $g.DrawEllipse($ringPen, [float](64.0 - $ringR), [float](64.0 - $ringR), [float]($ringR * 2), [float]($ringR * 2))
            }
            $ringPen.Dispose()
        }
        elseif ($Style -eq "Shisui") {
            # Four-bladed pinwheel.
            for ($i = 0; $i -lt 4; $i++) {
                $baseAngle = $Angle + ($i * [Math]::PI / 2)
                Fill-CurvedBlade $g $blackBrush $baseAngle 10.0 33.0 $mScale 1.05 10.0
            }
        }
        elseif ($Style -eq "Indra") {
            for ($i = 0; $i -lt 3; $i++) {
                $baseAngle = $Angle + ($i * 2 * [Math]::PI / 3)
                Fill-CurvedBlade $g $blackBrush $baseAngle 14.0 30.0 $mScale 1.0 9.0
            }
            for ($i = 0; $i -lt 3; $i++) {
                $tipAngle = $Angle + ($i * 2 * [Math]::PI / 3) + 0.9
                $tipRadius = 14.0 + (30.0 * $mScale)
                $tx = 64.0 + ($tipRadius * [Math]::Cos($tipAngle))
                $ty = 64.0 + ($tipRadius * [Math]::Sin($tipAngle))
                $tipRadiusSmall = 5.0 * $mScale
                $g.FillEllipse($blackBrush, [float]($tx - $tipRadiusSmall), [float]($ty - $tipRadiusSmall), [float]($tipRadiusSmall * 2), [float]($tipRadiusSmall * 2))
            }
        }
        elseif ($Style -eq "Shin") {
            $dotPositions = @(
                @(-20.0, -25.0), @(18.0, -30.0), @(35.0, -10.0), @(-35.0, -8.0), @(25.0, 20.0),
                @(-22.0, 28.0), @(5.0, -40.0), @(-5.0, 38.0), @(38.0, 12.0), @(-38.0, 15.0),
                @(15.0, 35.0), @(-18.0, -18.0), @(22.0, -18.0), @(0.0, -35.0), @(30.0, -30.0)
            )
            # Spin the whole scatter about the centre - the dots used to sit at
            # fixed coordinates, so this was the one pattern that never moved.
            $cosA = [Math]::Cos($Angle)
            $sinA = [Math]::Sin($Angle)
            foreach ($pos in $dotPositions) {
                $dotRadius = ([Math]::Abs($pos[0]) + [Math]::Abs($pos[1])) % 4.0 + 1.5
                $dotRadius *= $mScale
                if ($dotRadius -le 0.1) { continue }
                $rx = ($pos[0] * $cosA) - ($pos[1] * $sinA)
                $ry = ($pos[0] * $sinA) + ($pos[1] * $cosA)
                $dx = 64.0 + ($rx * $mScale)
                $dy = 64.0 + ($ry * $mScale)
                $g.FillEllipse($blackBrush, [float]($dx - $dotRadius), [float]($dy - $dotRadius), [float]($dotRadius * 2), [float]($dotRadius * 2))
            }
        }
        elseif ($Style -eq "Sarada") {
            # Ring grows with the morph - it used to be hardcoded at 38,38,52,52
            # and so appeared at full size while the blades were still specks.
            $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int]($mScale * 230), 0, 0, 0), 3.0)
            $ringR = 26.0 * $mScale
            if ($ringR -gt 1.0) {
                $g.DrawEllipse($ringPen, [float](64.0 - $ringR), [float](64.0 - $ringR), [float]($ringR * 2), [float]($ringR * 2))
            }
            $ringPen.Dispose()
            for ($i = 0; $i -lt 3; $i++) {
                $baseAngle = $Angle + ($i * 2 * [Math]::PI / 3) + 0.35
                Fill-CurvedBlade $g $blackBrush $baseAngle 15.0 32.0 $mScale 1.1 9.5
            }
        }
        elseif ($Style -eq "Naka") {
            # Three orbiting dots on a ring. Previously the dots sat at fixed
            # coordinates so the whole pattern was frozen, and it used the only
            # white brush in the renderer, which read as a cartoon eye-glint.
            $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int]($mScale * 200), 0, 0, 0), 2.4)
            $orbitR = 30.0 * $mScale
            if ($orbitR -gt 1.0) {
                $g.DrawEllipse($ringPen, [float](64.0 - $orbitR), [float](64.0 - $orbitR), [float]($orbitR * 2), [float]($orbitR * 2))
            }
            $ringPen.Dispose()

            $dotR = 8.0 * $mScale
            for ($i = 0; $i -lt 3; $i++) {
                $dotAngle = $Angle + ($i * 2 * [Math]::PI / 3)
                $dx = 64.0 + ($orbitR * [Math]::Cos($dotAngle))
                $dy = 64.0 + ($orbitR * [Math]::Sin($dotAngle))
                $g.FillEllipse($blackBrush, [float]($dx - $dotR), [float]($dy - $dotR), [float]($dotR * 2), [float]($dotR * 2))
            }
        }
        elseif ($Style -eq "Baru") {
            # Two opposed crescents that spin. Previously fixed arcs at 36,34 -
            # frozen, popped in at full size, and barely visible at full morph.
            $originalState = $g.Save()
            $g.TranslateTransform(64.0, 64.0)
            $g.RotateTransform(($Angle * 180.0 / [Math]::PI))

            $outerR = 34.0 * $mScale
            $innerR = 20.0 * $mScale
            if ($outerR -gt 3.0) {
                for ($i = 0; $i -lt 2; $i++) {
                    $startDeg = ($i * 180.0) + 12.0
                    $g.FillPie($blackBrush, [float](-$outerR), [float](-$outerR), [float]($outerR * 2), [float]($outerR * 2), [float]$startDeg, 156.0)
                }
                # Carve the crescents out with an eye-coloured disc.
                $carve = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb([int]($mScale * 255), $eyeDraw.R, $eyeDraw.G, $eyeDraw.B))
                $g.FillEllipse($carve, [float](-$innerR), [float](-$innerR), [float]($innerR * 2), [float]($innerR * 2))
                $carve.Dispose()
            }
            $g.Restore($originalState)
        }
        elseif ($Style -eq "Rai") {
            $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int](160 + ($mScale * 60)), 0, 0, 0), 2.6)
            $g.DrawEllipse($ringPen, 38, 34, 52, 52)
            $ringPen.Dispose()
            for ($i = 0; $i -lt 4; $i++) {
                $baseAngle = $Angle + ($i * [Math]::PI / 2)
                Fill-CurvedBlade $g $blackBrush $baseAngle 14.0 26.0 $mScale 1.25 8.5
            }
        }
        elseif ($Style -eq "Naori") {
            $radii = @(18.0, 28.0, 38.0)
            foreach ($rVal in $radii) {
                $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int](140 + ($mScale * 80)), 0, 0, 0), 2.8)
                $g.DrawEllipse($ringPen, [float](64.0 - ($rVal * $mScale)), [float](64.0 - ($rVal * $mScale)), [float]($rVal * 2.0 * $mScale), [float]($rVal * 2.0 * $mScale))
                $ringPen.Dispose()
            }
            $spokePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int](180 + ($mScale * 55)), 0, 0, 0), 2.5)
            for ($i = 0; $i -lt 3; $i++) {
                $angleOffset = $Angle + ($i * 2.0 * [Math]::PI / 3.0)
                $innerX = 64.0 + ((18.0 * $mScale) * [Math]::Cos($angleOffset))
                $innerY = 64.0 + ((18.0 * $mScale) * [Math]::Sin($angleOffset))
                $outerX = 64.0 + ((38.0 * $mScale) * [Math]::Cos($angleOffset))
                $outerY = 64.0 + ((38.0 * $mScale) * [Math]::Sin($angleOffset))
                $g.DrawLine($spokePen, [float]$innerX, [float]$innerY, [float]$outerX, [float]$outerY)
            }
            $spokePen.Dispose()
        }
        elseif ($Style -eq "Fugaku") {
            $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int](140 + ($mScale * 80)), 0, 0, 0), 3.8)
            $g.DrawEllipse($ringPen, 39, 39, 50, 50)
            $ringPen.Dispose()
            for ($i = 0; $i -lt 3; $i++) {
                $baseAngle = $Angle + ($i * 2 * [Math]::PI / 3)
                Fill-CurvedBlade $g $blackBrush $baseAngle 24.0 27.5 $mScale 1.2 11.5
            }
        }
        elseif ($Style -eq "Nanashi") {
            for ($i = 0; $i -lt 3; $i++) {
                $baseAngle = $Angle + ($i * 2 * [Math]::PI / 3) + 0.6
                Fill-CurvedBlade $g $blackBrush $baseAngle 10.0 24.0 $mScale 0.9 6.8
            }
            $g.FillEllipse($blackBrush, [float](64.0 - (2.5 * $mScale)), [float](64.0 - (2.5 * $mScale)), [float](5.0 * $mScale), [float](5.0 * $mScale))
        }
        elseif ($Style -eq "Madara Eye 2") {
            $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb([int](150 + ($mScale * 70)), 0, 0, 0), 3.0)
            $g.DrawEllipse($ringPen, 28, 28, 72, 72)
            $ringPen.Dispose()
            $originalState = $g.Save()
            $g.TranslateTransform(64.0, 64.0)
            $g.RotateTransform(($Angle * 180.0 / [Math]::PI))
            for ($i = 0; $i -lt 3; $i++) {
                $startDeg = ($i * 120.0) - 18.0
                $scaledR = 30.0 * $mScale
                if ($scaledR -gt 2) {
                    $g.FillPie($blackBrush, [float](-$scaledR), [float](-$scaledR), [float]($scaledR * 2), [float]($scaledR * 2), [float]$startDeg, [float]34.0)
                }
            }
            $g.Restore($originalState)
            $g.DrawEllipse($borderPen, [float](64.0 - (16.0 * $mScale)), [float](64.0 - (16.0 * $mScale)), [float](32.0 * $mScale), [float](32.0 * $mScale))
        }
        elseif ($Style -eq "Sasuke Eye 2") {
            $originalState = $g.Save()
            $g.TranslateTransform(64.0, 64.0)
            $semiMajor = 46.0 * $mScale
            $semiMinor = 17.0 * $mScale
            for ($i = 0; $i -lt 3; $i++) {
                $rotState = $g.Save()
                $deg = ($Angle * 180.0 / [Math]::PI) + ($i * 120.0)
                $g.RotateTransform($deg)
                $g.FillEllipse($blackBrush, [float](-$semiMinor), [float](-$semiMajor), [float]($semiMinor * 2), [float]($semiMajor * 2))
                $g.Restore($rotState)
            }
            $g.Restore($originalState)
            $g.DrawLine($borderPen, [float](64.0), [float](28.0 + (8.0 * $mScale)), [float](64.0), [float](100.0 - (8.0 * $mScale)))
            $g.DrawLine($borderPen, [float](38.0 + (8.0 * $mScale)), [float](64.0), [float](90.0 - (8.0 * $mScale)), [float](64.0))
        }
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
        $headRadius = 7.5 * $scale * (1.0 + 0.9 * $conv)     # heads fatten into blade tips

        $hx = 64.0 + $tomoeRadius * [Math]::Cos($tomoeAngle)
        $hy = 64.0 + $tomoeRadius * [Math]::Sin($tomoeAngle)
        $g.FillEllipse($blackBrush, [float]($hx - $headRadius), [float]($hy - $headRadius), [float]($headRadius * 2), [float]($headRadius * 2))

        $tailLength = 0.75 + 1.9 * $conv     # tails stretch into arms during the merge
        $tailSteps = 30
        for ($j = 0; $j -le $tailSteps; $j++) {
            $tTail = $j / $tailSteps
            $phi = $tomoeAngle + ($tTail * $tailLength * $scale)
            
            $tw = $headRadius * [Math]::Pow(1.0 - $tTail, 1.5)
            if ($tw -le 0.1) { continue }

            $tx = 64.0 + $tomoeRadius * [Math]::Cos($phi)
            $ty = 64.0 + $tomoeRadius * [Math]::Sin($phi)
            $g.FillEllipse($blackBrush, [float]($tx - $tw), [float]($ty - $tw), [float]($tw * 2), [float]($tw * 2))
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
            $pool = @($global:SharinganStyles | Where-Object { $_ -ne $global:selectedEyeStyle })
            Set-EyeStyle ($pool | Get-Random)
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
    $NotifyIcon.Text = "Sharingan ($global:selectedEyeStyle $modeText): $([Math]::Round($global:currentLoadPercent, 1))%"

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
