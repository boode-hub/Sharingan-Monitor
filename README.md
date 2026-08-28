# Sharingan Tray Monitor

An animated Sharingan that lives in your Windows system tray and reacts to real
system load. The eye awakens as your machine works harder — one tomoe, then two,
then three, then Mangekyou — and spins faster the heavier the load.

Pure PowerShell. No installer, no dependencies, no compiled binaries, nothing to
trust. One script you can read top to bottom.

<p align="center">
  <img src="docs/evolve.gif" width="450" alt="The Sharingan awakening in the system tray as CPU load rises">
  <br>
  <em>Real capture from the tray — dormant, then awakening as the machine works.</em>
</p>

## How it reacts

| CPU / RAM load | Eye |
| --- | --- |
| below 15% | dormant — no tomoe |
| 15% | 1 tomoe |
| 35% | 2 tomoe |
| 55% | 3 tomoe |
| 75% | Mangekyou |

Every threshold is adjustable. Stages blend smoothly rather than snapping — the
morph is a floating-point value and every element scales off it, so the eye grows
into each stage instead of popping.

## Install

No installer. Download or clone, then:

```
powershell -ExecutionPolicy Bypass -File p2.ps1
```

That is the whole thing. It appears in your system tray immediately.

To start it automatically at login:

```
install-startup.bat
```

Undo that at any time with `remove-startup.bat`, which also stops the running
instance. Both use the per-user registry key, so neither needs administrator
rights.

## Using it

Right-click the tray icon:

```
Swap to RAM Tracking       toggle between CPU and RAM
Eyes                    >  18 Sharingan styles
Customize               >  Thresholds  >  1st / 2nd / 3rd Tomoe, Mangekyou
                        |  Color       >  10 presets + full colour picker
                        |  Speed       >  0.20x .. 3.00x rotation
                        |  Shuffle     >  cycle eyes randomly, on a timer
                        |  Glow           makes the colour glow
                        |  Reset to Defaults
Exit
```

Everything applies live. Settings persist to `settings.json` next to the script.

<p align="center">
  <img src="docs/customize.gif" width="420" alt="Walking through the Customize menu: thresholds, colour, speed, shuffle and glow">
  <br>
  <em>Every setting lives in the tray menu — no separate settings window.</em>
</p>

## The eyes

Itachi · Obito · Kakashi · Madara · Izuna · Sasuke · Shisui · Indra · Shin ·
Sarada · Naka · Baru · Rai · Naori · Fugaku · Nanashi · Madara Eye 2 ·
Sasuke Eye 2

All eighteen are drawn from scratch with GDI+ at 128×128 and scaled down by
Windows, which is what keeps them sharp at tray size. Every one rotates, and
every pattern grows out of nothing as the stage builds.

## Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (ships with Windows — nothing to install)

## How it works

The interesting parts, if you want to read the source:

- **Load sampling** — `PerformanceCounter("Processor", "% Processor Time", "_Total")`
  for CPU, so the numbers match Task Manager, and `GlobalMemoryStatusEx` for RAM.
- **The morph** — load maps to a target stage, and the current stage eases toward
  it each frame. That easing is why the eye flows between stages.
- **Rendering** — every frame draws a fresh 128×128 bitmap. Tomoe tails and
  Mangekyou blades are runs of overlapping circles, which is crude but
  anti-aliases beautifully.
- **The tray pipeline** — a WinForms `Timer` under a real message pump at ~28fps,
  disposing the previous icon and calling `DestroyIcon` on every frame. Skipping
  that leaks GDI handles until the process dies.

`PROJECT_PROMPT.txt` documents the full architecture, including the pitfalls
found the hard way.

## Support

This is free and always will be — every feature, no paywalls, no nags. If it
made your taskbar better and you'd like to say thanks, there's a Sponsor button
at the top of the repo. Entirely optional, and it changes nothing about the
software.

## Disclaimer

Unofficial fan software. Not affiliated with, endorsed by, or sponsored by
Masashi Kishimoto, Shueisha, TV Tokyo, or Viz Media.

"Sharingan", "Mangekyou Sharingan" and the character names are the intellectual
property of their respective owners. This project ships **no** artwork, audio or
other assets from any Naruto work — every graphic is generated at runtime by the
drawing code in this repository. The code is MIT licensed; see `LICENSE`.

## Recording a demo

The tray icon is only 16x16, so recording the taskbar directly gives you
something too small to read. What worked here:

1. [ScreenToGif](https://www.screentogif.com) — free, open source, Windows.
2. Load the machine so the eye actually evolves on camera:
   `powershell -Command "1..8 | ForEach-Object { Start-Job { while($true){} } }"`
   and `powershell -Command "Get-Job | Remove-Job -Force"` to stop.
3. Record a tight region around the icon, then scale it up in ScreenToGif's
   editor — or record with Windows Magnifier docked at 4x.
4. Keep it short. Dormant, awakening, then spinning at Mangekyou is the whole
   story and it fits in five seconds.
5. Export under about 5MB so it plays inline on GitHub and Reddit.
