# Sharingan Tray Monitor

[![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D6?style=flat-square&logo=windows&logoColor=white)](#requirements)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1-5391FE?style=flat-square&logo=powershell&logoColor=white)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![Buy me a coffee](https://img.shields.io/badge/Buy%20me%20a%20coffee-FFDD00?style=flat-square&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/boode)

An animated Sharingan that lives in your Windows system tray and reacts to real
system load. The eye awakens as your machine works harder — one tomoe, then two,
then three, then Mangekyou — and spins faster the heavier the load.

Pure PowerShell. No installer, no dependencies, no compiled binaries, nothing to
trust. One script you can read top to bottom.

## Download and install

Nothing to compile and no installer. Never used GitHub before? Just follow along:

<p align="center">
  <img src="docs/download-install.gif" width="800" alt="Downloading the ZIP from GitHub and running the script">
</p>

1. Click the green **Code** button near the top of this page, then **Download ZIP**.
2. Right-click the downloaded ZIP, choose **Extract All**, and pick any folder.
3. Open that folder, right-click **Sharingan.ps1**, and choose **Run with PowerShell**.

The eye appears in your system tray straight away. Right-click it for the menu.

> **If Windows blocks it:** right-click the ZIP *before* extracting, choose
> **Properties**, tick **Unblock**, then extract. Windows flags files downloaded
> from the internet, and this clears that flag.

**Prefer the command line?**

```
powershell -ExecutionPolicy Bypass -File Sharingan.ps1
```

**Want it to start automatically when you log in?**

Double-click `install-startup.bat`. Undo it any time with `remove-startup.bat`,
which also stops the running instance. Neither needs administrator rights.

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

## Using it

Right-click the tray icon:

```
Swap to RAM Tracking       toggle between CPU and RAM
Eyes                    >  Classic  >  the hand-drawn eyes
                        |  V1       >  the artwork eyes (when eyes\ is present)
Customize               >  Thresholds  >  1st / 2nd / 3rd Tomoe, Mangekyou
                        |  Color       >  10 presets + full colour picker
                        |  Speed       >  slider, 0 (paused) to 100
                        |  Direction   >  clockwise / counter-clockwise
                        |  Invert Colors  swap tomoe and eye colour
                        |  Shuffle     >  cycle eyes randomly, on a timer
                        |  Glow        >  on/off, heartbeat pulse, pulse speed
                        |  Profiles    >  save / load a whole set of settings
                        |  Reset to Defaults
Buy me a coffee            opens the support page in your browser
Exit
```

Everything applies live. Settings persist to `settings.json` next to the script.
A profile is the same settings in one small JSON file under `profiles\`.

When load climbs past the last threshold the three tomoe swirl in the direction
the eye is spinning, their tails stretch into long arms, and those arms become
the Mangekyou.

<p align="center">
  <img src="docs/customize.gif" width="420" alt="Walking through the Customize menu: thresholds, colour, speed, shuffle and glow">
  <br>
  <em>Every setting lives in the tray menu, no separate settings window.</em>
</p>

## The eyes

**Classic** - drawn in code: Itachi · Obito · Kakashi · Madara · Izuna · Sasuke ·
Shisui · Indra · Shin · Sarada · Naka · Baru · Rai · Naori · Fugaku · Nanashi ·
Madara Eye 2 · Sasuke Eye 2

**V1** - drawn from artwork you supply in an `eyes\` folder next to the script
(the expected file names are in `$global:EyeFiles` in the script). V1 shows up
in the menu only for the eyes whose file is present; with no `eyes\` folder the
menu simply lists the Classic eyes.

Every eye rotates and grows out of nothing as the stage builds, and shuffle stays
within the set you are on.

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

## Support

This is free and always will be — every feature, no paywalls, no nags.

If it made your taskbar better and you'd like to say thanks:

<a href="https://buymeacoffee.com/boode"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black" alt="Buy me a coffee"></a>

Entirely optional, and it changes nothing about the software.

## Disclaimer

Unofficial fan software. Not affiliated with, endorsed by, or sponsored by
Masashi Kishimoto, Shueisha, TV Tokyo, or Viz Media.

"Sharingan", "Mangekyou Sharingan" and the character names are the intellectual
property of their respective owners. This project ships **no** artwork, audio or
other assets from any Naruto work — every graphic is generated at runtime by the
drawing code in this repository. The code is MIT licensed; see `LICENSE`.
